"""Golden fixtures for the Swift engine's event helpers (app/Sources/LofiBossa/Engine/Events.swift).

    .venv/bin/python training/export_engine_fixtures.py

Runs the `anticipation` library's own ops on small fixed inputs and writes inputs and outputs to
app/LofiBossaTests/Fixtures/engine_ops.json, which EngineEventsTests compares exactly.
"""

import json
from pathlib import Path

from anticipation import ops
from anticipation.vocab import CONTROL_OFFSET, DUR_OFFSET, NOTE_OFFSET, TIME_OFFSET

import tracks


def ev(tick, dur, instr, pitch):
    return [TIME_OFFSET + tick, DUR_OFFSET + dur, NOTE_OFFSET + instr * 128 + pitch]


def main():
    events = ev(5, 40, 0, 60) + ev(5, 40, 0, 64) + ev(180, 25, 32, 36) + ev(420, 10, 128, 42) + ev(990, 300, 24, 55)
    other = ev(50, 30, 32, 40) + ev(700, 20, 128, 38) + ev(1500, 50, 0, 67)
    controls = [t + CONTROL_OFFSET for t in other]
    cases = {
        "events": events,
        "controls": controls,
        "pad": ops.pad(events),
        "pad_to_2000": ops.pad(events, 2000),
        "clip_0_400": ops.clip(events, 0, 400, clip_duration=True, seconds=False),
        "clip_0_400_keep": ops.clip(events, 0, 400, clip_duration=False, seconds=False),
        "anticipate": list(ops.anticipate(ops.pad(events, 2000), controls)[0]),
        "anticipate_pending": list(ops.anticipate(ops.pad(events), controls)[1]),
        "min_time": ops.min_time(events + controls, seconds=False),
        "max_time": ops.max_time(events + controls, seconds=False),
        "unpad": ops.unpad(ops.pad(events, 2000)),
        "out_program": {t: (128 if t == "drums" else tracks.OUT_PROGRAM[t]) for t in tracks.ALL_TRACKS},
        "family": {t: list(tracks.ALL_FAMILY[t]) for t in tracks.ALL_TRACKS},
        "velocity": tracks.VELOCITY,
    }
    out = Path(__file__).resolve().parent.parent / "app/LofiBossaTests/Fixtures/engine_ops.json"
    out.write_text(json.dumps(cases))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
