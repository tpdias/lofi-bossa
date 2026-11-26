"""Scan the downloaded datasets and list every file that matches a style.

    python training/data/build_manifest.py --root datasets --out processed/manifest.jsonl

Each manifest row: {id, source, style, tier, path, tempo, multitrack}
`path` is relative to datasets/<source>/. Sources that are not downloaded are skipped.
GigaMIDI rows need data/gigamidi_styles.jsonl (see gigamidi_meta.py); their MIDI files are
pulled out of the downloaded zips afterwards by gigamidi_extract.py. Lakh rows are picked by
training/sources/lakh.py and copied in from processed/lakh_manifest.jsonl.

MidiCaps metadata can be streamed instead of downloaded:
    --midicaps-meta https://huggingface.co/datasets/amaai-lab/MidiCaps/resolve/main/train.json
"""

import argparse
import collections
import csv
import hashlib
import io
import json
import urllib.request
from pathlib import Path

from styles import STYLES, classify_gigamidi, classify_prefix, classify_tags

FAMILY_PROGRAMS = {"piano": range(0, 8), "guitar": range(24, 32), "bass": range(32, 40)}


def row(source, path, style, tier, tempo, multitrack):
    digest = hashlib.sha1(f"{source}/{path}".encode()).hexdigest()[:12]
    return {
        "id": f"{source}-{digest}",
        "source": source,
        "style": style,
        "tier": tier,
        "path": str(path),
        "tempo": tempo,
        "multitrack": multitrack,
    }


def families_in(programs):
    """Which of our four instrument families appear in a MidiCaps program list (128 = drums)."""
    found = set()
    for p in programs or ():
        if p == 128:
            found.add("drums")
        for fam, rng in FAMILY_PROGRAMS.items():
            if p in rng:
                found.add(fam)
    return found


def open_lines(location):
    if str(location).startswith("http"):
        req = urllib.request.Request(str(location), headers={"User-Agent": "dataset-downloader"})
        return io.TextIOWrapper(urllib.request.urlopen(req), encoding="utf-8")
    return open(location, encoding="utf-8")


def midicaps(meta, min_families):
    with open_lines(meta) as f:
        for line in f:
            if not line.strip():
                continue
            m = json.loads(line)
            if len(families_in(m.get("instrument_numbers_sorted"))) < min_families:
                continue
            for style, tier in classify_tags(
                m.get("genre"), m.get("caption"), m.get("tempo"), m.get("time_signature")
            ):
                yield row("midicaps", m["location"], style, tier, m.get("tempo"), True)


def groove(root):
    info = next(root.rglob("info.csv"), None)
    if info is None:
        return
    with open(info, newline="") as f:
        for r in csv.DictReader(f):
            if r["time_signature"] != "4-4" or float(r["duration"]) < 8:
                continue
            path = (info.parent / r["midi_filename"]).relative_to(root)
            for s in STYLES.values():
                tier = classify_prefix(r["style"], s.groove_core, s.groove_wide)
                if tier:
                    yield row("groove", path, s.name, tier, float(r["bpm"]), False)


def guitarset(root):
    # e.g. 00_BN1-129-Eb_comp.jams -> style code BN, 129 BPM
    for jams in sorted(root.rglob("*.jams")):
        try:
            code_part, bpm, _ = jams.stem.split("_", 1)[1].split("-")
        except ValueError:
            continue
        code = code_part.rstrip("0123456789")
        for s in STYLES.values():
            tier = classify_prefix(code, s.guitarset_core, s.guitarset_wide)
            if tier:
                yield row("guitarset", jams.relative_to(root), s.name, tier, float(bpm), False)


def kaggle_lofi(root):
    for mid in sorted(list(root.rglob("*.mid")) + list(root.rglob("*.midi"))):
        yield row("kaggle_lofi", mid.relative_to(root), "lofi", "core", None, False)


def gigamidi(meta):
    """Rows come from gigamidi_meta.py; files are extracted later to datasets/gigamidi/<md5>.mid."""
    seen = set()
    with open(meta) as f:
        for line in f:
            m = json.loads(line)
            for style, tier in classify_gigamidi(m):
                if (m["md5"], style) in seen:
                    continue
                seen.add((m["md5"], style))
                # only full-band files must contain several of our tracks; solo piano or guitar
                # arrangements and drum-only files are kept as single-track material
                multitrack = m["type"] == "all-instruments-with-drums"
                yield row("gigamidi", f"{m['md5']}.mid", style, tier, m.get("tempo"), multitrack)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="datasets", type=Path)
    ap.add_argument("--out", default="processed/manifest.jsonl", type=Path)
    ap.add_argument("--midicaps-meta", help="path or URL of MidiCaps train.json")
    ap.add_argument("--gigamidi-meta", default="data/gigamidi_styles.jsonl", type=Path)
    ap.add_argument("--lakh-manifest", default="processed/lakh_manifest.jsonl", type=Path,
                    help="rows picked from the Lakh MIDI Dataset by training/sources/lakh.py")
    ap.add_argument("--min-families", type=int, default=3,
                    help="multitrack files must contain this many of piano/guitar/bass/drums")
    args = ap.parse_args()

    rows = []
    meta = args.midicaps_meta or args.root / "midicaps" / "train.json"
    if str(meta).startswith("http") or Path(meta).exists():
        rows += midicaps(meta, args.min_families)
    if args.gigamidi_meta.exists():
        rows += gigamidi(args.gigamidi_meta)
    if args.lakh_manifest.exists():
        rows += [json.loads(line) for line in open(args.lakh_manifest)]
    for name, scan in (("groove", groove), ("guitarset", guitarset), ("kaggle_lofi", kaggle_lofi)):
        if (args.root / name).exists():
            rows += scan(args.root / name)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    counts = collections.Counter((r["style"], r["tier"], r["source"]) for r in rows)
    print(f"{len(rows)} rows -> {args.out}")
    for (style, tier, source), n in sorted(counts.items()):
        print(f"  {style:6} {tier:5} {source:12} {n}")


if __name__ == "__main__":
    main()
