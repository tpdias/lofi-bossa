"""Golden fixtures for the Swift port of the note clean-up (app/Sources/LofiBossa/Engine/Cleanup).

Runs the deterministic parts of tidy.py and tracks.py on fixed inputs and writes inputs and
outputs to app/LofiBossaTests/Fixtures/cleanup_golden.json, which CleanupGoldenTests.swift checks
the Swift functions against. The random parts (chord share, dynamics jitter) use a different
generator in Swift, so they are covered by property tests instead; a thinning case is only kept
here when it never touches the generator.

    .venv/bin/python training/export_fixtures.py

Notes are written as [start, duration, pitch, velocity].
"""

import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tidy  # noqa: E402
import tracks  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "app" / "LofiBossaTests" / "Fixtures" / "cleanup_golden.json"
TRACK_NAMES = ("piano", "guitar", "bass", "drums", "keys", "lead", "vibes")


def pack(notes):
    return [[n["start"], n["duration"], n["pitch"], n["velocity"]] for n in notes]


def note(start, duration, pitch, velocity=80):
    return {"start": start, "duration": duration, "pitch": pitch, "velocity": velocity}


def random_notes(rng, count, span=8.0, pitches=(40, 84), chords=0.3, drums=False):
    """Loose, model-like notes: some chords, some repeats, a few long and very short notes."""
    out, t = [], rng.uniform(0, 0.3)
    while len(out) < count:
        size = rng.choice((2, 3, 4, 5, 6)) if rng.random() < chords else 1
        root = rng.choice((35, 36, 38, 42, 46, 49, 51, 70)) if drums else rng.randint(*pitches)
        for k in range(size):
            pitch = rng.choice((36, 38, 42, 46, 51)) if drums and k else root + (0, 4, 7, 10, 14, 17)[k] % 40
            dur = rng.choice((0.02, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.0))
            out.append(note(round(t + rng.uniform(0, 0.02), 3), dur, min(pitch, 108), rng.randint(40, 110)))
        t += rng.choice((0.05, 0.1, 0.125, 0.15, 0.25, 0.3, 0.5, 0.6, 1.0))
        if t > span:
            t = rng.uniform(0, span)
    return out


class NoRandom:
    """A stand-in generator that refuses to be used: marks a thinning case as deterministic."""
    used = False

    def sample(self, *_):
        self.used = True
        raise LookupError

    def gauss(self, *_):
        self.used = True
        raise LookupError


def main():
    rng = random.Random(2027)
    data = {}

    data["knob"] = [[b, s, d, h, tidy.knob(b, s, d, h)]
                    for b in (-0.5, 0, 0.1, 0.25, 0.5, 0.6, 0.9, 1, 1.5)
                    for s, d, h in ((0.3, 0.6, 1.0), (2, 4, 1000), (0.2, 0.1, 0.0))]
    data["settings"] = [{"track": t, "busyness": b, **tidy.settings(t, b)}
                        for t in TRACK_NAMES for b in (0, 0.2, 0.5, 0.7, 1)]
    data["min_duration"] = [[t, nl, tidy.min_duration(t, nl)]
                            for t in TRACK_NAMES if t != "drums" for nl in (0, 0.3, 0.5, 0.8, 1)]

    data["legato"] = []
    for i in range(12):
        notes = random_notes(rng, rng.randint(1, 40))
        min_length = rng.choice((0.06, 0.2, 0.35, 0.9))
        data["legato"].append({"notes": pack(notes), "min_length": min_length,
                               "out": pack(tidy.legato("piano", notes, min_length))})

    notes = random_notes(rng, 30, drums=True)
    data["clamp_drums"] = {"notes": pack(notes), "out": pack(tidy.clamp_drums(notes))}

    data["pitch_cooldown"] = []
    for i in range(14):
        track = TRACK_NAMES[i % len(TRACK_NAMES)]
        notes = random_notes(rng, rng.randint(5, 60), span=4.0, pitches=(58, 64))
        data["pitch_cooldown"].append({"track": track, "notes": pack(notes),
                                       "out": pack(tidy.pitch_cooldown(track, notes))})

    data["keys"] = {name: sorted(pcs) for name, pcs in tracks.KEYS.items()}
    every_pitch = [note(i * 0.1, 0.1, p) for i, p in enumerate(range(128))]
    data["snap_to_key"] = [{"key": name, "out": [n["pitch"] for n in tidy.snap_to_key(every_pitch, tracks.KEYS[name])]}
                           for name in ("C major", "A minor", "F# major", "D# minor", "B major")]

    data["quantize"] = []
    for i in range(10):
        notes = random_notes(rng, 25)
        tempo = (rng.choice((60.0, 72.5, 90.0, 110.0, 128.3, 140.0)), rng.choice((0.0, 0.1, 0.27, 0.5)))
        strength = rng.choice((0.0, 0.25, 0.5, 0.8, 1.0, 1.5))
        data["quantize"].append({"notes": pack(notes), "bpm": tempo[0], "offset": tempo[1], "strength": strength,
                                 "out": pack(tidy.quantize(notes, tempo, strength))})

    data["detect_key"] = []
    scales = [(60, 62, 64, 65, 67, 69, 71, 72), (57, 59, 60, 62, 64, 65, 67, 69), ()]
    for pitches in scales:
        notes = [note(i * 0.5, 0.5, p) for i, p in enumerate(pitches)]
        data["detect_key"].append({"notes": pack(notes), "key": tracks.detect_key(notes)})
    for i in range(20):
        name = rng.choice(sorted(tracks.KEYS))
        pcs = sorted(tracks.KEYS[name])
        notes = [note(j * 0.2, rng.choice((0.0, 0.1, 0.3, 1.0)), 48 + rng.choice(pcs) + 12 * rng.randint(0, 2))
                 for j in range(rng.randint(3, 40))]
        notes += [note(9, 0.05, rng.randint(40, 90)) for _ in range(rng.randint(0, 4))]   # strays
        data["detect_key"].append({"notes": pack(notes), "key": tracks.detect_key(notes)})

    data["estimate_tempo"] = []

    def clicks(bpm, offset, n, jitter, seed):
        r = random.Random(seed)
        beat = 60 / bpm
        return [offset + i * beat / 2 + r.uniform(-jitter, jitter) for i in range(n) if r.random() > 0.15]

    cases = [clicks(bpm, 0.2, 64, 0.008, bpm) for bpm in (72, 90, 110, 130)]
    cases.append(clicks(96, 0.3, 64, 0.002, 0))
    cases += [clicks(rng.uniform(60, 140), rng.uniform(0, 1), rng.randint(20, 80), 0.01, rng.random()) for _ in range(6)]
    cases += [[n["start"] for n in random_notes(rng, 40)] for _ in range(3)]
    cases += [[0.0, 1.0], [0.0, 0.0, 0.004, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], [-0.5, -0.2] + [i * 0.25 for i in range(10)]]
    for onsets in cases:
        got = tracks.estimate_tempo([{"start": s} for s in onsets])
        data["estimate_tempo"].append({"onsets": onsets, "tempo": list(got) if got else None})

    data["beat_phase"] = []
    phase_cases = [([0.25 + i * 0.5 for i in range(16)], 120.0), ([], 90.0)]
    phase_cases += [(clicks(rng.uniform(60, 140), rng.uniform(0, 1), 40, 0.01, rng.random()), rng.choice((70.0, 96.0, 121.7)))
                    for _ in range(6)]
    for onsets, bpm in phase_cases:
        data["beat_phase"].append({"onsets": onsets, "bpm": bpm,
                                   "offset": tracks.beat_phase([{"start": s} for s in onsets], bpm)})

    data["drum_category"] = [tracks.drum_category(p) for p in range(128)]

    # apply_dynamics with dynamics 0 never draws a random number
    notes = random_notes(rng, 20)
    data["flat_dynamics"] = [{"track": t, "notes": pack(notes),
                              "out": pack(tidy.apply_dynamics(t, notes, 0.0, NoRandom(), (100.0, 0.0)))}
                             for t in ("piano", "drums")]

    # Whole tracks that never touch the generator: busyness 1 with note length / key / groove,
    # or thinning where the chord-share step finds no excess (always for drums).
    data["tidy_track"] = []
    attempts = 0
    while len(data["tidy_track"]) < 40 and attempts < 400:
        attempts += 1
        track = TRACK_NAMES[attempts % len(TRACK_NAMES)]
        notes = random_notes(rng, rng.randint(1, 120), span=rng.choice((4.0, 12.0, 24.0)),
                             chords=rng.choice((0.0, 0.1, 0.4)), drums=track == "drums")
        busyness = rng.choice((0.0, 0.2, 0.3, 0.5, 0.5, 0.8, 1.0))
        note_length = rng.choice((None, 0.0, 0.5, 1.0))
        key = rng.choice((None, "C major", "A minor", "E major"))
        strict = rng.random() < 0.7
        tempo = rng.choice((None, (90.0, 0.12), (120.0, 0.0)))
        groove = rng.choice((0.0, 0.5, 1.0))
        stub = NoRandom()
        try:
            out = tidy.tidy_track(track, notes, busyness, stub, note_length=note_length,
                                  key=tracks.KEYS[key] if key else None, key_strict=strict,
                                  tempo=tempo, groove=groove)
        except LookupError:
            continue
        data["tidy_track"].append({"track": track, "notes": pack(notes), "busyness": busyness,
                                   "note_length": note_length, "key": key, "key_strict": strict,
                                   "tempo": list(tempo) if tempo else None, "groove": groove, "out": pack(out)})

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB, {len(data['tidy_track'])} tidy_track cases)")


if __name__ == "__main__":
    main()
