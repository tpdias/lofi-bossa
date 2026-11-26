"""Pick lo-fi-like and bossa-like files out of the Lakh MIDI Dataset (LMD-full, CC BY 4.0) by
their own musical content.

    # once: download LMD-full (lmd_full.tar.gz, 1.77 GB, 176,581 files) into datasets/lakh/
    python training/sources/lakh.py --download
    # measure every file (slow the first time, cached in processed/lakh_features.jsonl),
    # score it and write the manifest rows
    python training/sources/lakh.py --root datasets --out processed/lakh_manifest.jsonl
    # list the top picks per style with the MIDI files' own track names, to eyeball the selection
    python training/sources/lakh.py --show 20

Selection uses only what is in each MIDI file: which instruments play (nylon guitar, brush or
jazz kits, electric piano, upright or fingered bass, pads...), the tempo (tracks.estimate_tempo),
swing and syncopation of the onsets, and how often the harmony has 7ths and 9ths. Neither the
Million Song Dataset nor Last.fm tags are used (LMD's matched metadata is not CC BY and the tags
would add genre labels we can't ship); at most they can be used by hand to spot-check a few picks.

Each manifest row is the same shape build_manifest.py writes, with `source: "lakh"`, a style,
a tier (core: score >= CORE_SCORE, wide: score >= WIDE_SCORE) and the score.
"""

import argparse
import collections
import json
import multiprocessing
import subprocess
import sys
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))           # training/
sys.path.insert(0, str(HERE.parent / "data"))  # training/data/

LMD_URL = "http://hog.ee.columbia.edu/craffel/lmd/lmd_full.tar.gz"
LMD_BYTES = 1_768_163_879

CORE_SCORE = 7.0
WIDE_SCORE = 5.0

# --- General MIDI programs ----------------------------------------------------------------
NYLON_GUITAR, STEEL_GUITAR, JAZZ_GUITAR, CLEAN_GUITAR = 24, 25, 26, 27
DIST_GUITARS = (29, 30)                       # overdriven, distortion
ELECTRIC_PIANOS = (4, 5)
ACOUSTIC_PIANOS = (0, 1)
UPRIGHT_BASS, FINGERED_BASS, PICKED_BASS, FRETLESS_BASS = 32, 33, 34, 35
SYNTH_BASSES = (38, 39)
PADS = tuple(range(88, 96))
STRINGS = (48, 49, 50, 51)
VIBES = 11
FLUTE, SAX = 73, (64, 65, 66, 67)
# GS/GM2 drum-kit program numbers, set by a program change on the drum channel
JAZZ_KIT, BRUSH_KIT = 32, 40
# GM percussion keys
SIDE_STICK = 37
LATIN_PERC = (69, 70, 75, 76, 77)             # cabasa, maracas/shaker, claves, wood blocks
CLOSED_HAT, PEDAL_HAT, OPEN_HAT = 42, 44, 46
RIDE = (51, 59)

TIME_SIGNATURES = {(4, 4), (2, 4), (2, 2)}


# --- Features --------------------------------------------------------------------------------

def _onsets(notes):
    return [{"start": n.start} for n in notes]


def beat_positions(starts, bpm, offset):
    """Position of each onset inside its beat, 0..1."""
    beat = 60.0 / bpm
    return [((s - offset) / beat) % 1.0 for s in starts]


def swing_ratio(positions):
    """Share of off-beat eighths that land late (around 2/3 of the beat, swung) rather than
    halfway (straight). 0 = straight, 1 = fully swung, None = too few off-beats to tell."""
    straight = sum(0.44 <= p <= 0.56 for p in positions)
    swung = sum(0.6 <= p <= 0.73 for p in positions)
    if straight + swung < 16:
        return None
    return swung / (straight + swung)


def syncopation(positions):
    """Share of onsets on the sixteenth off-beats (1/4 and 3/4 of the beat), where bossa
    anticipations and lo-fi ghost notes sit."""
    if not positions:
        return 0.0
    near = lambda p, x: abs(p - x) <= 0.07  # noqa: E731
    return sum(near(p, 0.25) or near(p, 0.75) for p in positions) / len(positions)


def chord_extensions(notes, bpm, offset, end):
    """Share of one-beat harmony windows (with at least three pitch classes) that form a
    seventh chord, and the share of those that also carry a ninth. Pitched notes only. A pitch
    class counts in a window when it sounds for at least half of it, so a chord change between
    beats doesn't merge two chords into a false seventh."""
    if not notes or not bpm:
        return 0.0, 0.0
    span = 60.0 / bpm
    n_windows = int(max(end - offset, 0) / span) + 1
    if n_windows > 4000:
        return 0.0, 0.0
    windows = [set() for _ in range(n_windows)]
    for n in notes:
        first = max(int((n.start - offset) / span), 0)
        last = min(int((n.end - offset) / span), n_windows - 1)
        for w in range(first, last + 1):
            lo = offset + w * span
            if min(n.end, lo + span) - max(n.start, lo) >= 0.5 * span:
                windows[w].add(n.pitch % 12)
    harmonic = sevenths = ninths = 0
    for pcs in windows:
        if len(pcs) < 3:
            continue
        harmonic += 1
        seventh = ninth = False
        for r in pcs:
            third = (r + 3) % 12 in pcs or (r + 4) % 12 in pcs
            sev = (r + 10) % 12 in pcs or (r + 11) % 12 in pcs
            if third and sev:
                seventh = True
                ninth = ninth or (r + 2) % 12 in pcs
        sevenths += seventh
        ninths += ninth
    if not harmonic:
        return 0.0, 0.0
    return sevenths / harmonic, (ninths / sevenths if sevenths else 0.0)


def features(pm):
    """Everything the scorer looks at, as a plain JSON-able dict."""
    from preprocess import collapse
    from tracks import TRACKS, estimate_tempo

    programs = collections.Counter()
    drum_kits = set()
    drum_hits = collections.Counter()
    pitched, drums = [], []
    for inst in pm.instruments:
        if inst.is_drum:
            drum_kits.add(int(inst.program))
            drums.extend(inst.notes)
            drum_hits.update(n.pitch for n in inst.notes)
        else:
            programs[inst.program] += len(inst.notes)
            pitched.extend(inst.notes)

    all_notes = pitched + drums
    est = estimate_tempo(_onsets(all_notes)) if len(all_notes) >= 8 else None
    bpm, offset = est if est else (None, 0.0)
    end = pm.get_end_time()

    _, counts, dropped = collapse(pm, bpm)
    pos = beat_positions([n.start for n in all_notes], bpm, offset) if bpm else []
    # swing is best read off the hi-hats/ride when there are any
    hats = [n.start for n in drums if n.pitch in (CLOSED_HAT, PEDAL_HAT, OPEN_HAT) + RIDE]
    hat_pos = beat_positions(hats, bpm, offset) if bpm and len(hats) >= 32 else pos
    sevenths, ninths = chord_extensions(pitched, bpm, offset, end)
    ts = {(t.numerator, t.denominator) for t in pm.time_signature_changes}

    n_drums = sum(drum_hits.values())
    return {
        "duration": round(end, 1),
        "time_signatures": sorted(f"{a}/{b}" for a, b in ts),
        "programs": {str(int(p)): int(c) for p, c in programs.items()},
        "drum_kits": sorted(drum_kits),
        "tracks": {t: counts[t] for t in counts},
        "core_tracks": sum(counts[t] >= 8 for t in TRACKS),
        "dropped_share": round(dropped, 3),
        "tempo": bpm,
        "swing": None if (s := swing_ratio(hat_pos)) is None else round(s, 3),
        "syncopation": round(syncopation(pos), 3),
        "sevenths": round(sevenths, 3),
        "ninths": round(ninths, 3),
        "side_stick": round(drum_hits[SIDE_STICK] / n_drums, 3) if n_drums else 0.0,
        "latin_perc": round(sum(drum_hits[p] for p in LATIN_PERC) / n_drums, 3) if n_drums else 0.0,
        "notes": len(all_notes),
    }


# --- Scoring ---------------------------------------------------------------------------------

def _share(f, programs):
    """Share of pitched notes played by the given programs."""
    progs = f["programs"]
    total = sum(progs.values())
    return sum(progs.get(str(p), 0) for p in programs) / total if total else 0.0


def _has(f, programs, min_share=0.05):
    return _share(f, programs) >= min_share


def eligible(f):
    """Gates every pick must pass, whatever the style: duple metre, long enough, a band."""
    ts = {tuple(map(int, s.split("/"))) for s in f["time_signatures"]}
    return (
        (not ts or ts <= TIME_SIGNATURES)
        and f["duration"] >= 30
        and f["core_tracks"] >= 3
        and f["tracks"].get("drums", 0) >= 8
        and f["tempo"] is not None
        and f["dropped_share"] <= 0.35
    )


def score_bossa(f):
    s = 0.0
    # instruments
    if _has(f, (NYLON_GUITAR,)):
        s += 3.0
    elif _has(f, (STEEL_GUITAR, JAZZ_GUITAR)):
        s += 1.0
    if _has(f, (UPRIGHT_BASS,)):
        s += 1.5
    elif _has(f, (FINGERED_BASS, FRETLESS_BASS)):
        s += 0.75
    if BRUSH_KIT in f["drum_kits"]:
        s += 1.5
    elif JAZZ_KIT in f["drum_kits"]:
        s += 1.0
    if f["side_stick"] >= 0.08:          # the cross-stick clave pattern
        s += 1.5
    if f["latin_perc"] >= 0.05:
        s += 0.5
    if _has(f, (FLUTE,) + SAX) or _has(f, STRINGS):
        s += 0.5
    if _has(f, DIST_GUITARS):
        s -= 3.0
    # feel
    t = f["tempo"]
    if 110 <= t <= 145 or 55 <= t <= 75:  # written in 2 or felt in a slow 4
        s += 1.0
    elif t < 90:
        s -= 1.0
    if f["swing"] is not None:
        if f["swing"] <= 0.3:            # bossa is straight eighths
            s += 0.5
        elif f["swing"] >= 0.5:
            s -= 1.5
    if f["syncopation"] >= 0.15:
        s += 1.0
    # harmony
    if f["sevenths"] >= 0.35:
        s += 1.5
    if f["ninths"] >= 0.25:
        s += 0.5
    return s


def score_lofi(f):
    s = 0.0
    if _has(f, ELECTRIC_PIANOS):
        s += 2.5
    elif _has(f, ACOUSTIC_PIANOS):
        s += 0.5
    if _has(f, PADS) or _has(f, STRINGS):
        s += 1.0
    if _has(f, (VIBES,)):
        s += 0.5
    if _has(f, (UPRIGHT_BASS, FINGERED_BASS, FRETLESS_BASS)):
        s += 1.0
    elif _has(f, SYNTH_BASSES):
        s += 0.5
    if _has(f, (JAZZ_GUITAR, CLEAN_GUITAR, NYLON_GUITAR)):
        s += 0.5
    if BRUSH_KIT in f["drum_kits"] or JAZZ_KIT in f["drum_kits"]:
        s += 1.0
    if _has(f, DIST_GUITARS):
        s -= 3.0
    t = f["tempo"]
    if 65 <= t <= 95:
        s += 2.0
    elif 95 < t <= 105:
        s += 0.5
    elif t > 115:
        s -= 2.0
    if f["swing"] is not None and f["swing"] >= 0.4:   # lazy swung hats
        s += 1.5
    if f["syncopation"] >= 0.12:
        s += 0.5
    if f["sevenths"] >= 0.35:
        s += 1.5
    if f["ninths"] >= 0.25:
        s += 0.5
    return s


SCORERS = {"bossa": score_bossa, "lofi": score_lofi}


def bossa_signature(f):
    """A core bossa pick needs at least one thing only bossa-ish arrangements tend to have."""
    return (_has(f, (NYLON_GUITAR,)) or f["side_stick"] >= 0.08 or BRUSH_KIT in f["drum_kits"]) \
        and f["sevenths"] >= 0.2


def lofi_signature(f):
    """A core lo-fi pick must be slow and jazz-voiced."""
    return f["tempo"] <= 100 and f["sevenths"] >= 0.25


SIGNATURES = {"bossa": bossa_signature, "lofi": lofi_signature}


def classify(f, core=CORE_SCORE, wide=WIDE_SCORE):
    """(style, tier, score) for the style a file fits best, or None. A file goes to one style
    only, so the two fine-tunes learn different things."""
    if not eligible(f):
        return None
    scores = {style: fn(f) for style, fn in SCORERS.items()}
    style = max(scores, key=scores.get)
    best = scores[style]
    if best >= core and SIGNATURES[style](f):
        return style, "core", best
    if best >= wide:
        return style, "wide", best
    return None


def fingerprint(f):
    """Rough identity of the arrangement: LMD-full holds many near-identical copies of a song
    under different checksums."""
    return (round(f["duration"]), f["notes"] // 20, tuple(sorted(f["programs"])))


# --- Scanning --------------------------------------------------------------------------------

def measure(path):
    import pretty_midi
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            pm = pretty_midi.PrettyMIDI(str(path))
        if pm.get_end_time() > 1200:
            return {"error": "too long"}
        return features(pm)
    except Exception as e:  # LMD-full has a few thousand corrupt files
        return {"error": f"{type(e).__name__}"[:60]}


def _measure_job(job):
    rel, root = job
    return rel, measure(root / rel)


def scan(root, cache, workers):
    """{relative path: features} for every MIDI file under root, measuring only new files."""
    known = {}
    if cache.exists():
        with open(cache) as f:
            for line in f:
                r = json.loads(line)
                known[r["path"]] = r["features"]
    todo = [str(p.relative_to(root)) for p in sorted(root.rglob("*.mid")) if str(p.relative_to(root)) not in known]
    print(f"{len(known)} files cached, {len(todo)} to measure")
    cache.parent.mkdir(parents=True, exist_ok=True)
    with open(cache, "a") as out, multiprocessing.Pool(workers) as pool:
        for n, (rel, feats) in enumerate(pool.imap_unordered(_measure_job, [(r, root) for r in todo], chunksize=32)):
            known[rel] = feats
            out.write(json.dumps({"path": rel, "features": feats}) + "\n")
            if n % 5000 == 0 and n:
                print(f"  measured {n}/{len(todo)}", flush=True)
    return known


def select(feats_by_path, max_per_style=None):
    """Manifest rows for the picked files, best scores first, one copy per fingerprint."""
    from build_manifest import row

    picks = collections.defaultdict(list)
    for path, f in feats_by_path.items():
        if "error" in f:
            continue
        got = classify(f)
        if got:
            style, tier, score = got
            picks[style].append((score, path, tier, f))
    rows = []
    for style, items in sorted(picks.items()):
        items.sort(key=lambda x: (-x[0], x[1]))
        seen = set()
        kept = 0
        for score, path, tier, f in items:
            fp = fingerprint(f)
            if fp in seen:
                continue
            seen.add(fp)
            r = row("lakh", path, style, tier, f["tempo"], True)
            r["score"] = round(score, 2)
            rows.append(r)
            kept += 1
            if max_per_style and kept >= max_per_style:
                break
    return rows


def download(dest):
    """Fetch and unpack LMD-full into dest/ (dest/lmd_full/<0-f>/<md5>.mid)."""
    dest.mkdir(parents=True, exist_ok=True)
    tarball = dest / "lmd_full.tar.gz"
    print(f"downloading {LMD_URL} ({LMD_BYTES / 1e9:.2f} GB) -> {tarball}")
    subprocess.run(["curl", "-SL", "--retry", "3", "-C", "-", "-o", str(tarball), LMD_URL], check=True)
    subprocess.run(["tar", "xzf", tarball.name], cwd=dest, check=True)
    tarball.unlink()


def show(rows, root, n):
    import pretty_midi
    by_style = collections.defaultdict(list)
    for r in rows:
        by_style[r["style"]].append(r)
    for style, rs in sorted(by_style.items()):
        print(f"\n== {style}: top {n} of {len(rs)}")
        for r in rs[:n]:
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    pm = pretty_midi.PrettyMIDI(str(root / r["path"]))
                names = sorted({i.name.strip() for i in pm.instruments if i.name.strip()})[:6]
            except Exception:
                names = []
            print(f"  {r['score']:5.1f} {r['tier']:4} {r['tempo']:6.1f} bpm  {r['path']}  {names}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default="datasets", type=Path, help="datasets folder (LMD-full in <root>/lakh)")
    ap.add_argument("--out", default="processed/lakh_manifest.jsonl", type=Path)
    ap.add_argument("--cache", default="processed/lakh_features.jsonl", type=Path)
    ap.add_argument("--max-per-style", type=int, default=4000)
    ap.add_argument("--workers", type=int, default=multiprocessing.cpu_count())
    ap.add_argument("--download", action="store_true", help=f"download LMD-full ({LMD_BYTES / 1e9:.2f} GB) first")
    ap.add_argument("--show", type=int, default=0, help="print the top N picks per style with their track names")
    args = ap.parse_args()

    lakh = args.root / "lakh"
    if args.download:
        download(lakh)
    feats = scan(lakh, args.cache, args.workers)
    rows = select(feats, args.max_per_style)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    errors = sum("error" in f for f in feats.values())
    counts = collections.Counter((r["style"], r["tier"]) for r in rows)
    print(f"{len(feats)} files measured ({errors} unreadable), {len(rows)} picked -> {args.out}")
    for (style, tier), n in sorted(counts.items()):
        print(f"  {style:6} {tier:5} {n}")
    if args.show:
        show(rows, lakh, args.show)


if __name__ == "__main__":
    main()
