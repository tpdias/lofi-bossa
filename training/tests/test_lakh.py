"""Tests for the Lakh selection scorer (training/sources/lakh.py) on small synthetic songs."""

import sys
import unittest
from pathlib import Path

import pretty_midi

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "sources"))
import lakh  # noqa: E402

MAJ7_9 = (0, 4, 7, 11, 14)      # Cmaj9 voicing, as intervals
TRIAD = (0, 4, 7)


def song(bpm, guitar, bass, kit, chord, swing=0.5, hats=True, side_stick=False, bars=24, roots=(48, 53)):
    """A 4/4 band: a chord every half bar, bass on the beats, hats on every eighth (the off-beat
    eighth at `swing` of the beat: 0.5 straight, 0.67 swung), kick/snare or side stick."""
    pm = pretty_midi.PrettyMIDI(initial_tempo=bpm)
    pm.time_signature_changes.append(pretty_midi.TimeSignature(4, 4, 0))
    beat = 60.0 / bpm
    keys = pretty_midi.Instrument(program=guitar)
    bassline = pretty_midi.Instrument(program=bass)
    drums = pretty_midi.Instrument(program=kit, is_drum=True)
    for b in range(bars * 4):
        t = b * beat
        root = roots[(b // 2) % len(roots)]
        if b % 2 == 0:
            for iv in chord:
                keys.notes.append(pretty_midi.Note(70, root + iv, t, t + 2 * beat - 0.01))
        # a sixteenth anticipation before every other beat, the bossa / lo-fi push
        if b % 2 == 1:
            keys.notes.append(pretty_midi.Note(60, root + 12, t + 0.75 * beat, t + beat))
        bassline.notes.append(pretty_midi.Note(80, root - 12, t, t + beat * 0.9))
        if hats:
            for pos in (0, swing):
                drums.notes.append(pretty_midi.Note(60, 42, t + pos * beat, t + pos * beat + 0.05))
        hit = 37 if side_stick else (36 if b % 2 == 0 else 38)
        drums.notes.append(pretty_midi.Note(90, hit, t, t + 0.05))
    pm.instruments += [keys, bassline, drums]
    return pm


class ScorerTests(unittest.TestCase):
    def test_bossa_band_is_picked_as_core_bossa(self):
        pm = song(130, guitar=lakh.NYLON_GUITAR, bass=lakh.UPRIGHT_BASS, kit=lakh.BRUSH_KIT,
                  chord=MAJ7_9, swing=0.5, side_stick=True)
        f = lakh.features(pm)
        self.assertAlmostEqual(f["tempo"], 130, delta=3)
        self.assertGreater(f["sevenths"], 0.9)
        self.assertLess(f["swing"], 0.2)
        self.assertEqual(lakh.classify(f)[:2], ("bossa", "core"))

    def test_slow_swung_electric_piano_is_picked_as_lofi(self):
        pm = song(80, guitar=lakh.ELECTRIC_PIANOS[0], bass=lakh.FINGERED_BASS, kit=0,
                  chord=MAJ7_9, swing=0.67)
        f = lakh.features(pm)
        self.assertGreater(f["swing"], 0.8)
        style, tier, _ = lakh.classify(f)
        self.assertEqual(style, "lofi")
        self.assertEqual(tier, "core")

    def test_bossa_without_a_signature_instrument_is_only_wide(self):
        pm = song(130, guitar=lakh.STEEL_GUITAR, bass=lakh.UPRIGHT_BASS, kit=lakh.JAZZ_KIT, chord=MAJ7_9)
        f = lakh.features(pm)
        style, tier, score = lakh.classify(f)
        self.assertEqual((style, tier), ("bossa", "wide"))
        self.assertGreaterEqual(score, lakh.CORE_SCORE)

    def test_fast_distorted_triads_are_not_picked(self):
        pm = song(135, guitar=lakh.DIST_GUITARS[1], bass=lakh.PICKED_BASS, kit=0, chord=TRIAD)
        f = lakh.features(pm)
        self.assertEqual(f["sevenths"], 0.0)
        self.assertIsNone(lakh.classify(f))

    def test_waltz_and_short_files_fail_the_gate(self):
        pm = song(130, guitar=lakh.NYLON_GUITAR, bass=lakh.UPRIGHT_BASS, kit=lakh.BRUSH_KIT,
                  chord=MAJ7_9, side_stick=True)
        f = lakh.features(pm)
        self.assertTrue(lakh.eligible(f))
        self.assertFalse(lakh.eligible({**f, "time_signatures": ["3/4"]}))
        self.assertFalse(lakh.eligible({**f, "duration": 12.0}))
        self.assertFalse(lakh.eligible({**f, "core_tracks": 2}))

    def test_swing_ratio_and_syncopation(self):
        self.assertIsNone(lakh.swing_ratio([0.5] * 5))
        self.assertEqual(lakh.swing_ratio([0.5] * 20), 0.0)
        self.assertEqual(lakh.swing_ratio([0.66] * 20), 1.0)
        self.assertEqual(lakh.syncopation([0.0, 0.25, 0.5, 0.75]), 0.5)

    def test_chord_extensions_count_sevenths_and_ninths(self):
        notes = [pretty_midi.Note(80, 60 + iv, 0, 2.0) for iv in MAJ7_9]          # beats 1-2
        notes += [pretty_midi.Note(80, 65 + iv, 2.0, 4.0) for iv in TRIAD]        # beats 3-4: F
        notes.append(pretty_midi.Note(80, 72, 1.8, 2.1))   # a short pickup doesn't count
        sev, nin = lakh.chord_extensions(notes, 60, 0.0, 4.0)
        self.assertAlmostEqual(sev, 0.5)
        self.assertAlmostEqual(nin, 1.0)

    def test_select_keeps_one_copy_of_duplicates_and_writes_lakh_rows(self):
        pm = song(130, guitar=lakh.NYLON_GUITAR, bass=lakh.UPRIGHT_BASS, kit=lakh.BRUSH_KIT,
                  chord=MAJ7_9, side_stick=True)
        f = lakh.features(pm)
        copy = {**f, "tracks": {**f["tracks"], "lead": 60}, "notes": f["notes"] + 60}   # same song + a melody
        rows = lakh.select({"lmd_full/a/a1.mid": f, "lmd_full/b/b1.mid": copy,
                            "lmd_full/c/c1.mid": {"error": "OSError"}})
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r["source"], r["style"], r["tier"], r["multitrack"]), ("lakh", "bossa", "core", True))
        self.assertTrue(r["id"].startswith("lakh-"))


if __name__ == "__main__":
    unittest.main()
