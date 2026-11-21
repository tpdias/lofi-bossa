"""The tracks the project works with (four core ones, three optional extras), and conversion between model events and MIDI.

Model events are flat lists of (time, duration, note) token triples as defined by the
anticipation library: time and duration in 10 ms ticks, note = instrument * 128 + pitch,
instrument 128 = drums. The model has no velocity and no tempo; time is absolute.
"""

import pretty_midi

TRACKS = ("piano", "guitar", "bass", "drums")
# General MIDI program written for each output track
OUT_PROGRAM = {"piano": 0, "guitar": 24, "bass": 32, "drums": 0,
               "keys": 48, "lead": 73, "vibes": 11}
# General MIDI programs that count as each track (128 = the model's drum instrument)
FAMILY = {
    "piano": tuple(range(0, 8)),
    "guitar": tuple(range(24, 32)),
    "bass": tuple(range(32, 40)),
    "drums": (128,),
}
# Optional tracks a project can add. They are not part of training (preprocess.py only uses
# TRACKS), so the model writes them zero-shot from what it learned in pretraining.
EXTRA_TRACKS = ("keys", "lead", "vibes")
ALL_TRACKS = TRACKS + EXTRA_TRACKS
EXTRA_FAMILY = {
    "keys": tuple(range(48, 56)) + tuple(range(88, 96)),   # strings, choir, pads
    "lead": tuple(range(56, 80)),                          # brass, reeds, pipes
    "vibes": tuple(range(8, 16)),                          # chromatic percussion
}
ALL_FAMILY = {**FAMILY, **EXTRA_FAMILY}
_TRACK_OF = {instr: track for track, instrs in FAMILY.items() for instr in instrs}
_ALL_TRACK_OF = {instr: track for track, instrs in ALL_FAMILY.items() for instr in instrs}
VELOCITY = {"piano": 72, "guitar": 70, "bass": 84, "drums": 88, "keys": 64, "lead": 76, "vibes": 70}


def track_of(program, is_drum=False):
    """Track name for a MIDI program, or None if it is outside the four families."""
    return "drums" if is_drum else _TRACK_OF.get(program)


def all_track_of(program, is_drum=False):
    """Like track_of, but also knows the optional tracks."""
    return "drums" if is_drum else _ALL_TRACK_OF.get(program)


def instruments_for(tracks):
    """Model instrument ids covered by the given track names."""
    return [i for t in tracks for i in ALL_FAMILY[t]]


def split_events(events):
    """Group event triples by track. Events outside the four families are dropped."""
    from anticipation.vocab import NOTE_OFFSET

    out = {t: [] for t in ALL_TRACKS}
    for i in range(0, len(events), 3):
        track = _ALL_TRACK_OF.get((events[i + 2] - NOTE_OFFSET) // 128)
        if track:
            out[track].extend(events[i:i + 3])
    return out


def events_to_midi(events):
    """PrettyMIDI with every track (ALL_TRACKS order, empty tracks included)."""
    from anticipation.vocab import DUR_OFFSET, NOTE_OFFSET, TIME_OFFSET

    by_track = split_events(events)
    pm = pretty_midi.PrettyMIDI()
    for t in ALL_TRACKS:
        inst = pretty_midi.Instrument(program=OUT_PROGRAM[t], is_drum=(t == "drums"), name=t)
        ev = by_track[t]
        for i in range(0, len(ev), 3):
            start = (ev[i] - TIME_OFFSET) / 100
            dur = max(ev[i + 1] - DUR_OFFSET, 5) / 100
            pitch = (ev[i + 2] - NOTE_OFFSET) % 128
            inst.notes.append(pretty_midi.Note(VELOCITY[t], pitch, start, start + dur))
        pm.instruments.append(inst)
    return pm


# ---- Key: detection and the pitch-class set for each of the 24 major/minor keys ----

_NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
_MAJOR_STEPS = (0, 2, 4, 5, 7, 9, 11)
_MINOR_STEPS = (0, 2, 3, 5, 7, 8, 10)   # natural minor

# name ("C major", "A minor", ...) -> the pitch classes (0 = C) that belong to it
KEYS = {
    f"{name} {mode}": frozenset((root + step) % 12 for step in steps)
    for root, name in enumerate(_NOTE_NAMES)
    for mode, steps in (("major", _MAJOR_STEPS), ("minor", _MINOR_STEPS))
}

# Krumhansl-Schmuckler key profiles (how common each scale degree is in a major/minor melody),
# indexed by pitch class relative to the tonic.
_KS_MAJOR = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
_KS_MINOR = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)


def detect_key(notes):
    """Best-fit key ("A minor", ...) for a list of {"pitch", "duration", ...} note dicts,
    by the Krumhansl-Schmuckler profile-correlation method. "C major" if there are no notes."""
    weight = [0.0] * 12
    for n in notes:
        weight[int(n["pitch"]) % 12] += max(float(n["duration"]), 0.01)
    if not any(weight):
        return "C major"
    best, best_score = "C major", float("-inf")
    for root, name in enumerate(_NOTE_NAMES):
        for mode, profile in (("major", _KS_MAJOR), ("minor", _KS_MINOR)):
            score = sum(weight[pc] * profile[(pc - root) % 12] for pc in range(12))
            if score > best_score:
                best_score, best = score, f"{name} {mode}"
    return best


# ---- Drums: which GM percussion pitches play the same "job", and how close they may repeat ----

DRUM_CATEGORY = {}
for _pitches, _cat in (
    ((35, 36), "kick"),
    ((37, 38, 40), "snare"),
    ((42, 44, 46), "hihat"),
    ((49, 51, 52, 55, 57, 59), "cymbal"),
    ((41, 43, 45, 47, 48, 50), "tom"),
):
    for _p in _pitches:
        DRUM_CATEGORY[_p] = _cat

# Default minimum time (seconds) between two hits of the same category; a pitch not listed
# above (shaker, cowbell, claps...) falls back to "perc".
DRUM_MIN_GAP = {"kick": 0.2, "snare": 0.2, "hihat": 0.08, "cymbal": 0.5, "tom": 0.15, "perc": 0.1}


def drum_category(pitch):
    return DRUM_CATEGORY.get(pitch, "perc")
