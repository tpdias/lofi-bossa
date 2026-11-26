"""Turn every manifest file into a clean MIDI with up to seven tracks: piano, guitar, bass, drums
plus keys & pads, lead and vibes.

    python training/preprocess.py --manifest processed/manifest.jsonl --root datasets --out processed

For anything that ships, add `--licenses cc-by` (drops GigaMIDI; see DATA_LICENSES.md).

Writes processed/midi/<style>/<id>.mid, processed/index.jsonl (one row per kept file)
and processed/report.md (per-style totals).

Instruments outside the seven families are dropped; the share of dropped notes is recorded
so heavily-reduced files can be excluded later. Keeping a file still depends only on the four
core tracks (so the file set is the same as before the extra tracks were added); keys, lead and
vibes just come along when the file has them.
"""

import argparse
import collections
import json
import multiprocessing
import warnings
from pathlib import Path

import pretty_midi

from licenses import LICENSE_GROUPS, filter_rows
from tracks import ALL_TRACKS, OUT_PROGRAM, TRACKS, all_track_of

MIN_NOTES = 8


def load_guitarset(path):
    """GuitarSet JAMS: one note_midi annotation per string, pitches as fractional MIDI."""
    with open(path) as f:
        jam = json.load(f)
    guitar = pretty_midi.Instrument(program=OUT_PROGRAM["guitar"])
    for ann in jam["annotations"]:
        if ann["namespace"] != "note_midi":
            continue
        data = ann["data"]
        if isinstance(data, dict):  # older JAMS: dict of parallel lists
            data = [dict(zip(data, vals)) for vals in zip(*data.values())]
        for obs in data:
            pitch = int(round(obs["value"]))
            if 0 <= pitch <= 127 and obs["duration"] > 0:
                guitar.notes.append(
                    pretty_midi.Note(80, pitch, obs["time"], obs["time"] + obs["duration"])
                )
    pm = pretty_midi.PrettyMIDI()
    pm.instruments.append(guitar)
    return pm


def load(source, path):
    if source == "guitarset":
        return load_guitarset(path)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return pretty_midi.PrettyMIDI(str(path))


def collapse(pm, tempo):
    """Merge instruments by family. Returns (PrettyMIDI, notes per track, dropped share).
    Extra tracks (keys, lead, vibes) are written only when the file has any."""
    notes = {t: [] for t in ALL_TRACKS}
    dropped = 0
    for inst in pm.instruments:
        fam = all_track_of(inst.program, inst.is_drum)
        if fam is None:
            dropped += len(inst.notes)
        else:
            notes[fam].extend(inst.notes)
    total = dropped + sum(len(v) for v in notes.values())

    out = pretty_midi.PrettyMIDI(initial_tempo=tempo or 120.0)
    for t in ALL_TRACKS:
        if t not in TRACKS and len(notes[t]) < MIN_NOTES:
            dropped += len(notes[t])      # a stray handful of notes isn't a part
            notes[t] = []
            continue
        inst = pretty_midi.Instrument(program=OUT_PROGRAM[t], is_drum=(t == "drums"), name=t)
        inst.notes = sorted(notes[t], key=lambda n: (n.start, n.pitch))
        out.instruments.append(inst)
    counts = {t: len(notes[t]) for t in ALL_TRACKS}
    return out, counts, (dropped / total if total else 0.0)


def process(job):
    row, root, out_dir, min_tracks, min_seconds = job
    try:
        pm = load(row["source"], root / row["source"] / row["path"])
        tempo = row.get("tempo") or float(pm.estimate_tempo())
        out, counts, dropped = collapse(pm, tempo)
    except Exception as e:  # corrupt MIDI is common in scraped corpora
        return {"id": row["id"], "error": f"{type(e).__name__}: {e}"[:120]}

    present = [t for t in ALL_TRACKS if counts[t] >= MIN_NOTES]
    core_present = [t for t in present if t in TRACKS]
    duration = out.get_end_time()
    needed = min_tracks if row["multitrack"] else 1
    if len(core_present) < needed or duration < min_seconds:
        return {"id": row["id"], "skipped": "too few tracks" if len(core_present) < needed else "too short"}

    dest = out_dir / "midi" / row["style"] / f"{row['id']}.mid"
    dest.parent.mkdir(parents=True, exist_ok=True)
    out.write(str(dest))
    return {
        **row,
        "file": str(dest.relative_to(out_dir)),
        "duration": round(duration, 2),
        "tempo": round(tempo, 1),
        "tracks": present,
        "notes": counts,
        "dropped_share": round(dropped, 3),
    }


def write_report(kept, problems, path):
    lines = ["# Dataset report", ""]
    by_style = collections.defaultdict(list)
    for r in kept:
        by_style[r["style"]].append(r)
    for style, rows in sorted(by_style.items()):
        hours = sum(r["duration"] for r in rows) / 3600
        lines += [f"## {style}", "", f"{len(rows)} files, {hours:.1f} hours", ""]
        lines += ["| tier | source | files | hours |", "|---|---|---|---|"]
        groups = collections.defaultdict(list)
        for r in rows:
            groups[(r["tier"], r["source"])].append(r)
        for (tier, source), g in sorted(groups.items()):
            lines.append(f"| {tier} | {source} | {len(g)} | {sum(r['duration'] for r in g) / 3600:.1f} |")
        lines += ["", "| track | files containing it |", "|---|---|"]
        for t in ALL_TRACKS:
            lines.append(f"| {t} | {sum(t in r['tracks'] for r in rows)} |")
        full = sum(all(t in r["tracks"] for t in TRACKS) for r in rows)
        lines += ["", f"Files with all four core tracks: {full}", ""]
    reasons = collections.Counter(p.get("skipped") or "unreadable" for p in problems)
    lines += ["## Not kept", ""] + [f"- {k}: {n}" for k, n in sorted(reasons.items())]
    path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="processed/manifest.jsonl", type=Path)
    ap.add_argument("--root", default="datasets", type=Path)
    ap.add_argument("--out", default="processed", type=Path)
    ap.add_argument("--min-tracks", type=int, default=3)
    ap.add_argument("--min-seconds", type=float, default=8.0)
    ap.add_argument("--workers", type=int, default=multiprocessing.cpu_count())
    ap.add_argument("--licenses", default="all", choices=sorted(LICENSE_GROUPS),
                    help="cc-by: only CC BY (or more permissive) sources, i.e. no GigaMIDI. "
                         "Use it for anything that ships; see training/DATA_LICENSES.md")
    args = ap.parse_args()

    rows = [json.loads(line) for line in open(args.manifest)]
    before = len(rows)
    rows = filter_rows(rows, args.licenses)
    if len(rows) < before:
        print(f"--licenses {args.licenses}: left out {before - len(rows)} manifest rows")
    rows = [r for r in rows if (args.root / r["source"] / r["path"]).exists()]
    jobs = [(r, args.root, args.out, args.min_tracks, args.min_seconds) for r in rows]

    with multiprocessing.Pool(args.workers) as pool:
        results = pool.map(process, jobs, chunksize=16)

    kept = [r for r in results if "file" in r]
    problems = [r for r in results if "file" not in r]
    with open(args.out / "index.jsonl", "w") as f:
        for r in kept:
            f.write(json.dumps(r) + "\n")
    write_report(kept, problems, args.out / "report.md")
    print(f"kept {len(kept)} of {len(rows)} files -> {args.out / 'report.md'}")


if __name__ == "__main__":
    main()
