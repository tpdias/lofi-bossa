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
