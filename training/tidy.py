"""Clean-up of the model's notes before they reach the app ("Busyness").

The model, especially the pretrained one, tends to write long unbroken strings of short repeated
notes and to stack four or more notes on almost every onset. This module thins that out per
track, after generation and only for model output: notes the user draws or pastes in the app
never come through here, so they have no limits.

Every function works on the song JSON's note dicts ({"start", "duration", "pitch", "velocity"},
seconds). `busyness` goes from 0 (sparse) through 0.5 (default) to 1 (the model's notes,
untouched). Results are deterministic for a given seed.

    python training/tidy.py --report song.json [--busyness 0.5]
"""

import argparse
import json
import math
import random

GROUP = 0.03          # notes starting this close together are one onset (a chord)
PHRASE_GAP = 0.25     # a silence at least this long ends a phrase
REPEAT_GAP = 0.35     # repeats closer than this count as one run
MIN_LENGTH = 0.05     # shortest a note may be cut to

# Per track: most notes in one onset, default min time between onsets, default most onsets per
# second, default longest phrase (None: drums play on without breathing).
RULES = {
    "piano":  dict(voices=4, gap=0.10, per_sec=8, phrase=6.0),
    "keys":   dict(voices=4, gap=0.25, per_sec=4, phrase=8.0),
    "guitar": dict(voices=4, gap=0.10, per_sec=8, phrase=6.0),
    "bass":   dict(voices=1, gap=0.15, per_sec=5, phrase=10.0),
    "lead":   dict(voices=1, gap=0.12, per_sec=6, phrase=5.0),
    "vibes":  dict(voices=3, gap=0.12, per_sec=6, phrase=5.0),
    "drums":  dict(voices=3, gap=0.05, per_sec=12, phrase=None),
}


def knob(busyness, sparse, default, busy):
    """Piecewise-linear: busyness 0 -> sparse, 0.5 -> default, 1 -> busy."""
    b = min(max(busyness, 0.0), 1.0)
    if b <= 0.5:
        return sparse + (default - sparse) * b / 0.5
    return default + (busy - default) * (b - 0.5) / 0.5


def settings(track, busyness):
    """The thresholds for one track at a busyness."""
    r = RULES.get(track, RULES["piano"])
    return {
        "voices": r["voices"],
        "chord_share": knob(busyness, 0.3, 0.6, 1.0),
        "min_gap": knob(busyness, r["gap"] * 2, r["gap"], 0.0),
        "per_sec": knob(busyness, r["per_sec"] * 0.6, r["per_sec"], 1000.0),
        "repeats": knob(busyness, 2, 4, 1000),
        "phrase": None if r["phrase"] is None else knob(busyness, r["phrase"] / 2, r["phrase"], 1e9),
        "rest": knob(busyness, 1.0, 0.5, 0.0),
    }


def groups_of(notes):
    """Notes sorted and grouped by onset."""
    out = []
    for n in sorted(notes, key=lambda n: (n["start"], n["pitch"])):
        if out and n["start"] - out[-1][0]["start"] < GROUP:
            out[-1].append(n)
        else:
            out.append([n])
    return out


def _cap_group(group, voices, bass_like):
    if len(group) <= voices:
        return group
    by_pitch = sorted(group, key=lambda n: n["pitch"])
    if voices == 1:
        return [by_pitch[0] if bass_like else by_pitch[-1]]
    keep = [by_pitch[0], by_pitch[-1]]
    middle = sorted(by_pitch[1:-1], key=lambda n: -n["velocity"])
    keep += middle[:voices - 2]
    return sorted(keep, key=lambda n: n["pitch"])


def _end(n):
    return n["start"] + n["duration"]


def _cut(n, at):
    n["duration"] = max(at - n["start"], MIN_LENGTH)


def tidy_track(track, notes, busyness, rng):
    """Cleaned copy of one track's notes. busyness >= 1 returns them unchanged."""
    notes = [dict(n) for n in notes]
    if busyness >= 1 or not notes:
        return notes
    s = settings(track, busyness)
    drums = track == "drums"
    groups = groups_of(notes)

    # 1. chord size
    groups = [_cap_group(g, s["voices"], track == "bass") for g in groups]

    # 2. repeat spam: the same notes again and again in quick succession
    if not drums:
        kept, run, prev = [], 0, None
        for g in groups:
            key = tuple(sorted(n["pitch"] for n in g))
            if prev and key == prev[0] and g[0]["start"] - prev[1] < REPEAT_GAP:
                run += 1
            else:
                run = 1
            prev = (key, g[0]["start"])
            if run > s["repeats"] and (run - s["repeats"]) % 2 == 1:
                continue
            kept.append(g)
        groups = kept

    # 3. density: a minimum gap between onsets and a cap per second
    kept, starts = [], []
    for g in groups:
        t = g[0]["start"]
        if starts and t - starts[-1] < s["min_gap"]:
            continue
        if sum(1 for x in starts if x > t - 1.0) >= s["per_sec"]:
            continue
        kept.append(g)
        starts.append(t)
    groups = kept

    # 4. phrase rests: a part that never stops gets a breath
    if s["phrase"] is not None and s["rest"] > 0:
        kept, phrase_start, last_end, rest_until = [], None, None, -1.0
        for g in groups:
            t = g[0]["start"]
            if t < rest_until:
                continue
            if phrase_start is None or (last_end is not None and t - last_end >= PHRASE_GAP):
                phrase_start = t
            if t - phrase_start > s["phrase"]:
                rest_until = t + s["rest"]
                for prev_g in kept:            # nothing rings into the rest
                    for n in prev_g:
                        if _end(n) > t:
                            _cut(n, t)
                phrase_start, last_end = None, None
                continue
            kept.append(g)
            end = max(_end(n) for n in g)
            last_end = end if last_end is None else max(last_end, end)
        groups = kept

    # 5. chord share, over the onsets that are left: too many full chords -> thin the excess
    # to top and bottom (a song with a single chord keeps it)
    if not drums:
        full = [i for i, g in enumerate(groups) if len(g) >= 3]
        allowed = max(math.floor(s["chord_share"] * len(groups)), 1)
        excess = len(full) - allowed
        if excess > 0:
            for i in rng.sample(full, excess):
                g = sorted(groups[i], key=lambda n: n["pitch"])
                groups[i] = [g[-1]] if track == "vibes" else [g[0], g[-1]]

    # 6. sounding notes: shorten older notes so no more than `voices` ring at once
    if not drums:
        active = []
        for g in groups:
            t = g[0]["start"]
            active = [n for n in active if _end(n) > t + 1e-6]
            over = len(active) + len(g) - s["voices"]
            for n in sorted(active, key=lambda n: n["start"])[:max(over, 0)]:
                _cut(n, t)
            active = [n for n in active if _end(n) > t + 1e-6] + g

    return sorted((n for g in groups for n in g), key=lambda n: (n["start"], n["pitch"]))


def tidy_song(tracks, busyness, seed=0, only=None):
    """Cleaned copy of {track: notes}. `busyness` is one value or {track: value} (missing
    tracks use 0.5). `only` limits the clean-up to those tracks; the rest are copied as-is."""
    out = {}
    for track, notes in tracks.items():
        b = busyness.get(track, 0.5) if isinstance(busyness, dict) else busyness
        if only is not None and track not in only:
            out[track] = [dict(n) for n in notes]
            continue
        rng = random.Random(f"{seed}-{track}")
        out[track] = tidy_track(track, notes, b, rng)
    return out


def stats(notes, seconds):
    """Notes per second, share of full chords, longest phrase, most notes sounding at once."""
    groups = groups_of(notes)
    if not groups:
        return {"notes": 0, "per_sec": 0, "chord_share": 0, "longest_phrase": 0, "max_sounding": 0}
    longest, phrase_start, last_end = 0.0, groups[0][0]["start"], None
    for g in groups:
        t = g[0]["start"]
        if last_end is not None and t - last_end >= PHRASE_GAP:
            phrase_start = t
        longest = max(longest, max(_end(n) for n in g) - phrase_start)
        last_end = max(last_end or 0, max(_end(n) for n in g))
    edges = sorted([(n["start"], 1) for n in notes] + [(_end(n), -1) for n in notes], key=lambda e: (e[0], e[1]))
    sounding = peak = 0
    for _, d in edges:
        sounding += d
        peak = max(peak, sounding)
    return {
        "notes": len(notes),
        "per_sec": round(len(notes) / max(seconds, 1e-6), 2),
        "chord_share": round(sum(len(g) >= 3 for g in groups) / len(groups), 2),
        "longest_phrase": round(longest, 1),
        "max_sounding": peak,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", required=True, help="a song JSON as /generate returns it")
    ap.add_argument("--busyness", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    song = json.load(open(args.report))
    seconds = float(song.get("seconds") or 1)
    tidied = tidy_song(song["tracks"], args.busyness, args.seed)
    print(f"busyness {args.busyness}")
    for track, notes in song["tracks"].items():
        if not notes:
            continue
        before, after = stats(notes, seconds), stats(tidied[track], seconds)
        print(f"{track:7} " + "  ".join(f"{k} {before[k]} -> {after[k]}" for k in before))


if __name__ == "__main__":
    main()
