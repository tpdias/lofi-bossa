"""Tests for the key-detection and drum-category helpers in training/tracks.py."""

import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tracks  # noqa: E402


class KeyTests(unittest.TestCase):
    def test_c_major_scale_is_detected_as_c_major(self):
        notes = [{"pitch": p, "duration": 0.5} for p in (60, 62, 64, 65, 67, 69, 71, 72)]
        self.assertEqual(tracks.detect_key(notes), "C major")

    def test_a_minor_scale_is_detected_as_a_minor(self):
        notes = [{"pitch": p, "duration": 0.5} for p in (57, 59, 60, 62, 64, 65, 67, 69)]
        self.assertEqual(tracks.detect_key(notes), "A minor")

    def test_no_notes_defaults_to_c_major(self):
        self.assertEqual(tracks.detect_key([]), "C major")

    def test_every_key_has_seven_pitch_classes(self):
        self.assertEqual(len(tracks.KEYS), 24)
        self.assertTrue(all(len(pcs) == 7 for pcs in tracks.KEYS.values()))

    def test_relative_major_and_minor_share_the_same_pitch_classes(self):
        self.assertEqual(tracks.KEYS["C major"], tracks.KEYS["A minor"])


class TempoTests(unittest.TestCase):
    def clicks(self, bpm, offset, n=64, jitter=0.008, seed=0):
        rng = random.Random(seed)
        beat = 60 / bpm
        return [{"start": offset + i * beat / 2 + rng.uniform(-jitter, jitter)} for i in range(n)
                if rng.random() > 0.15]

    def test_estimates_the_tempo_of_eighth_note_clicks(self):
        for bpm in (72, 90, 110, 130):
            got = tracks.estimate_tempo(self.clicks(bpm, 0.2, seed=bpm))
            self.assertIsNotNone(got)
            self.assertAlmostEqual(got[0], bpm, delta=1.5, msg=f"{bpm} BPM")

    def test_phase_lines_up_with_the_clicks(self):
        bpm, offset = 96, 0.3
        got = tracks.estimate_tempo(self.clicks(bpm, offset, jitter=0.002))
        half_beat = 60 / bpm / 2
        miss = ((got[1] - offset) / half_beat) % 1
        self.assertLess(min(miss, 1 - miss), 0.1)

    def test_too_few_notes_gives_none(self):
        self.assertIsNone(tracks.estimate_tempo([{"start": 0.0}, {"start": 1.0}]))

    def test_beat_phase_at_a_given_tempo(self):
        notes = [{"start": 0.25 + i * 0.5} for i in range(16)]     # 120 BPM, on 0.25
        self.assertAlmostEqual(tracks.beat_phase(notes, 120), 0.25, delta=0.02)


class DrumCategoryTests(unittest.TestCase):
    def test_known_gm_pitches_map_to_their_category(self):
        self.assertEqual(tracks.drum_category(36), "kick")
        self.assertEqual(tracks.drum_category(38), "snare")
        self.assertEqual(tracks.drum_category(42), "hihat")

    def test_unknown_pitch_falls_back_to_perc(self):
        self.assertEqual(tracks.drum_category(70), "perc")


if __name__ == "__main__":
    unittest.main()
