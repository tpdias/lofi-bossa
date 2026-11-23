"""Clean-up of the model's notes before they reach the app ("Busyness").

The model, especially the pretrained one, tends to write long unbroken strings of short repeated
notes and to stack four or more notes on almost every onset. This module thins that out per
track, after generation and only for model output: notes the user draws or pastes in the app
never come through here, so they have no limits.

Every function works on the song JSON's note dicts ({"start", "duration", "pitch", "velocity"},
seconds). `busyness` goes from 0 (sparse) through 0.5 (default) to 1 (the model's notes,
untouched). Results are deterministic for a given seed.

Two more, independent knobs, applied whenever the caller passes them (unlike busyness, they are
never skipped at the model's raw output): `note_length` (0 short .. 0.5 default .. 1 long)
stretches staccato notes with `legato()` and clamps drum hits, and `key` (e.g. "A minor", from
`tracks.KEYS`) optionally snaps stray out-of-key notes back in when `key_strict`.

    python training/tidy.py --report song.json [--busyness 0.5] [--note-length 0.5] [--key "A minor"]
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


# ---- Note length: a separate knob from busyness, so it still applies at busyness == 1 ----

# Seconds: the "normal" (note_length 0.5) minimum new note length, per melodic track.
NOTE_LENGTH = {"piano": 0.20, "keys": 0.35, "guitar": 0.18, "bass": 0.30, "lead": 0.30, "vibes": 0.18}
DRUM_MAX_DURATION = 0.12   # seconds; a drum hit, not a held chord

# Within PITCH_COOLDOWN seconds, the same pitch may restart at most this many times, even with
# other notes in between (the busyness repeat-spam step above only catches back-to-back repeats
# of the very same chord). Keys is the track this shows up on most.
PITCH_COOLDOWN = 1.5
PITCH_COOLDOWN_MAX = {"keys": 2, "lead": 2, "vibes": 2, "piano": 3, "guitar": 3, "bass": 2}


def min_duration(track, note_length):
    """Seconds: the shortest a new note on this (non-drum) track should be."""
    base = NOTE_LENGTH.get(track, NOTE_LENGTH["piano"])
    return knob(note_length, base * 0.3, base, base * 3)


def legato(track, notes, min_length):
    """Notes shorter than `min_length` are stretched up to the next onset of this track (any
    pitch), capped at `min_length`, instead of ending early and leaving a silent gap. A note
    past every other one is simply given the full length."""
    if not notes:
        return notes
    notes = sorted((dict(n) for n in notes), key=lambda n: (n["start"], n["pitch"]))
    for i, n in enumerate(notes):
        if n["duration"] >= min_length:
            continue
        j = i + 1
        while j < len(notes) and notes[j]["start"] <= n["start"]:
            j += 1
        ceiling = notes[j]["start"] if j < len(notes) else n["start"] + min_length
        n["duration"] = max(n["duration"], min(min_length, max(ceiling - n["start"], MIN_LENGTH)))
    return notes


def clamp_drums(notes):
    """A drum "note" is a hit, not a held chord; anything longer than DRUM_MAX_DURATION is cut."""
    return [{**n, "duration": min(n["duration"], DRUM_MAX_DURATION)} for n in notes]


def pitch_cooldown(track, notes):
    """Drop the extra onsets once the same pitch has restarted PITCH_COOLDOWN_MAX[track] times
    within any PITCH_COOLDOWN-second span (deterministic: the earliest onsets win)."""
    limit = PITCH_COOLDOWN_MAX.get(track)
    if not limit or not notes:
        return notes
    by_pitch = {}
    for n in sorted(notes, key=lambda n: n["start"]):
        by_pitch.setdefault(n["pitch"], []).append(n)
    drop = set()
    for group in by_pitch.values():
        window = []
        for n in group:
            window = [t for t in window if n["start"] - t < PITCH_COOLDOWN]
            if len(window) >= limit:
                drop.add(id(n))
            else:
                window.append(n["start"])
    return [n for n in notes if id(n) not in drop]


def snap_to_key(notes, key):
    """Move any note outside `key` (a set of pitch classes, e.g. tracks.KEYS["A minor"]) to the
    nearest in-key pitch. A backstop for `key_strict`, since the sampler already keeps new notes
    in key; this only matters for notes that came from elsewhere."""
    out = []
    for n in notes:
        n = dict(n)
        pc = n["pitch"] % 12
        if pc not in key:
            for d in range(1, 7):
                if (pc - d) % 12 in key:
                    n["pitch"] -= d
                    break
                if (pc + d) % 12 in key:
                    n["pitch"] += d
                    break
        out.append(n)
    return out


# ---- Tempo and dynamics: the model writes neither; both are applied to its notes here ----

STEPS_PER_BEAT = 4          # the grid is sixteenth notes


def grid_step(tempo):
    """Seconds between sixteenth notes for (bpm, beat offset)."""
    return 60.0 / tempo[0] / STEPS_PER_BEAT


def quantize(notes, tempo, strength):
    """Pull every onset toward the nearest sixteenth of `tempo` = (bpm, beat offset seconds) by
    `strength` (0 untouched, 1 exactly on the grid); each note keeps its length."""
    if not notes or strength <= 0:
        return [dict(n) for n in notes]
    step, offset = grid_step(tempo), tempo[1]
    out = []
    for n in notes:
        n = dict(n)
        target = offset + round((n["start"] - offset) / step) * step
        n["start"] = max(round(n["start"] + (target - n["start"]) * min(strength, 1.0), 4), 0.0)
        out.append(n)
    return out


# Loudness range around each track's base velocity (tracks.VELOCITY) at dynamics 1: steady
# parts (bass, pads) move less.
DYNAMIC_RANGE = {"piano": 26, "guitar": 24, "bass": 14, "drums": 30, "keys": 14, "lead": 24, "vibes": 22}


def apply_dynamics(track, notes, dynamics, rng, tempo=None, base=None):
    """Write velocities instead of the model's flat default. `dynamics` 0 keeps every note at the
    track's base; up to 1 adds beat accents (with a tempo: downbeats and, for drums, backbeats
    louder, off-beat sixteenths softer), a rise and fall over each phrase, the top note of a
    chord a little louder, drum roles (kick and snare up, hi-hats down), and a little jitter."""
    if not notes or dynamics is None:
        return [dict(n) for n in notes]
    import tracks as track_info
    base = base if base is not None else track_info.VELOCITY.get(track, 72)
    spread = DYNAMIC_RANGE.get(track, 20) * min(max(dynamics, 0.0), 1.0)
    notes = sorted((dict(n) for n in notes), key=lambda n: (n["start"], n["pitch"]))
    if spread <= 0:
        for n in notes:
            n["velocity"] = base
        return notes

    # phrases: split where the track goes quiet for PHRASE_GAP
    phrase_of, phrases, last_end = [], [[]], None
    for i, n in enumerate(notes):
        if last_end is not None and n["start"] - last_end >= PHRASE_GAP:
            phrases.append([])
        phrases[-1].append(i)
        last_end = max(last_end or 0.0, _end(n))
    position = [0.0] * len(notes)
    for ph in phrases:
        a, b = notes[ph[0]]["start"], notes[ph[-1]]["start"]
        for i in ph:
            position[i] = (notes[i]["start"] - a) / (b - a) if b > a else 0.5
    tops = {id(g[-1]) for g in groups_of(notes) if len(g) > 1}

    for i, n in enumerate(notes):
        v = 0.35 * spread * math.sin(math.pi * position[i]) - 0.1 * spread   # phrase arc
        if tempo is not None:
            beats = (n["start"] - tempo[1]) * tempo[0] / 60.0
            sixteenth = round(beats * STEPS_PER_BEAT) % (4 * STEPS_PER_BEAT)   # position in a 4/4 bar
            if sixteenth == 0:
                v += 0.45 * spread                       # downbeat
            elif sixteenth % STEPS_PER_BEAT == 0:
                v += 0.2 * spread                        # other beats
                if track == "drums" and sixteenth in (4, 12):
                    v += 0.2 * spread                    # backbeat
            elif sixteenth % 2 == 1:
                v -= 0.3 * spread                        # off-beat sixteenths
        if track == "drums":
            role = track_info.drum_category(n["pitch"])
            v += {"kick": 0.3, "snare": 0.25, "hihat": -0.3, "cymbal": 0.1, "tom": 0.0}.get(role, -0.2) * spread
        elif id(n) in tops:
            v += 0.2 * spread                            # melody on top of a chord
        v += rng.gauss(0, 0.12 * spread)
        n["velocity"] = int(min(max(round(base + v), 20), 120))
    return notes


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


def tidy_track(track, notes, busyness, rng, note_length=None, key=None, key_strict=False,
               tempo=None, groove=0.0, dynamics=None):
    """Cleaned copy of one track's notes.

    busyness >= 1 skips the busyness-driven thinning below (steps 1-6: the model's raw notes).
    note_length and key are independent of busyness and of each other, and still apply even
    then: note_length (0 short .. 1 long, None = off) runs legato/clamp_drums/pitch_cooldown;
    key (a set of pitch classes, None = off) runs snap_to_key when key_strict.
    tempo = (bpm, beat offset seconds) with groove > 0 pulls onsets toward its sixteenths;
    dynamics (0 flat .. 1 expressive, None = off) writes the velocities, last.
    """
    notes = [dict(n) for n in notes]
    if not notes:
        return notes
    if busyness < 1:
        notes = _thin(track, notes, busyness, rng)
    if note_length is not None:
        if track == "drums":
            notes = clamp_drums(notes)
        else:
            notes = pitch_cooldown(track, legato(track, notes, min_duration(track, note_length)))
    if key is not None and key_strict and track != "drums":
        notes = snap_to_key(notes, key)
    if tempo is not None and groove > 0:
        notes = quantize(notes, tempo, groove)
    if dynamics is not None:
        notes = apply_dynamics(track, notes, dynamics, rng, tempo)
    return sorted(notes, key=lambda n: (n["start"], n["pitch"]))


def _thin(track, notes, busyness, rng):
    """Steps 1-6 of tidy_track: the busyness-driven thinning, unchanged from before note_length
    and key existed."""
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

    return [n for g in groups for n in g]


def _per_track(value, track, default):
    if value is None:
        return None
    return value.get(track, default) if isinstance(value, dict) else value


def tidy_song(tracks, busyness, seed=0, only=None, note_length=None, key=None, key_strict=False,
              tempo=None, groove=0.0, dynamics=None):
    """Cleaned copy of {track: notes}. `busyness` and `note_length` are each one value or
    {track: value} (missing tracks use 0.5 for busyness, are skipped for note_length). `key`
    is one set of pitch classes for the whole song, or None. `only` limits the clean-up to
    those tracks; the rest are copied as-is."""
    out = {}
    for track, notes in tracks.items():
        if only is not None and track not in only:
            out[track] = [dict(n) for n in notes]
            continue
        b = _per_track(busyness, track, 0.5)
        nl = _per_track(note_length, track, None)
        rng = random.Random(f"{seed}-{track}")
        out[track] = tidy_track(track, notes, b, rng, note_length=nl, key=key, key_strict=key_strict,
                                tempo=tempo, groove=groove, dynamics=dynamics)
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
    ap.add_argument("--note-length", type=float, help="0 short .. 0.5 default .. 1 long; omit to skip")
    ap.add_argument("--key", help='e.g. "A minor"; omit to skip, or "auto" to detect it')
    ap.add_argument("--strict-key", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    song = json.load(open(args.report))
    seconds = float(song.get("seconds") or 1)

    key_pcs, key_name = None, None
    if args.key:
        import tracks
        key_name = tracks.detect_key([n for notes in song["tracks"].values() for n in notes]) \
            if args.key == "auto" else args.key
        key_pcs = tracks.KEYS[key_name]

    tidied = tidy_song(song["tracks"], args.busyness, args.seed, note_length=args.note_length,
                       key=key_pcs, key_strict=args.strict_key)
    print(f"busyness {args.busyness}" + (f"  note_length {args.note_length}" if args.note_length is not None else "")
          + (f"  key {key_name}" if key_name else ""))
    for track, notes in song["tracks"].items():
        if not notes:
            continue
        before, after = stats(notes, seconds), stats(tidied[track], seconds)
        print(f"{track:7} " + "  ".join(f"{k} {before[k]} -> {after[k]}" for k in before))


if __name__ == "__main__":
    main()
