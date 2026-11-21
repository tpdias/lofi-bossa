"""Tests for training/tidy.py. Run with: .venv/bin/python -m unittest discover training/tests"""

import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tidy  # noqa: E402
import tracks  # noqa: E402


def note(start, pitch=60, duration=0.2, velocity=80):
    return {"start": start, "duration": duration, "pitch": pitch, "velocity": velocity}


def chord(start, pitches, duration=0.4):
    return [note(start, p, duration) for p in pitches]


def run(track, notes, busyness=0.5, seed=0):
    return tidy.tidy_track(track, notes, busyness, random.Random(seed))


class TidyTests(unittest.TestCase):
    def test_busyness_one_leaves_notes_untouched(self):
        notes = [n for i in range(40) for n in chord(i * 0.1, [60, 64, 67, 71, 74])]
        self.assertEqual(run("piano", notes, 1.0), notes)

    def test_chords_are_capped_per_track(self):
        notes = chord(0, [48, 55, 60, 64, 67, 72])
        out = run("piano", notes)
        self.assertEqual(len(out), 4)
        self.assertEqual({n["pitch"] for n in out} >= {48, 72}, True, "keeps lowest and highest")
        self.assertEqual(len(run("vibes", notes)), 3)

    def test_bass_and_lead_play_one_note_at_a_time(self):
        notes = chord(0, [36, 43], duration=2) + chord(1, [38], duration=2)
        bass = run("bass", notes)
        self.assertEqual([n["pitch"] for n in bass], [36, 38], "bass keeps the lowest note")
        self.assertLessEqual(bass[0]["start"] + bass[0]["duration"], 1.0 + 1e-9, "no overlap")
        self.assertEqual(run("lead", notes)[0]["pitch"], 43, "lead keeps the top note")

    def test_full_chords_are_at_most_sixty_percent_of_onsets(self):
        notes = [n for i in range(20) for n in chord(i * 0.5, [60, 64, 67, 70], duration=0.3)]
        out = run("guitar", notes)
        groups = tidy.groups_of(out)
        share = sum(len(g) >= 3 for g in groups) / len(groups)
        self.assertLessEqual(share, 0.6)
        self.assertGreaterEqual(share, 0.5, "only the excess is thinned")
        self.assertTrue(all(len(g) in (2, 4) for g in groups), "thinned chords keep top and bottom")

    def test_fast_repeats_are_thinned(self):
        notes = [note(i * 0.15, 60, 0.1) for i in range(30)]
        out = run("guitar", notes)
        self.assertLess(len(out), 20)

    def test_long_unbroken_parts_get_a_rest(self):
        notes = [note(i * 0.25, 60 + i % 7, 0.24) for i in range(80)]   # 20 s, never stops
        out = tidy.stats(run("piano", notes), 20)
        self.assertLessEqual(out["longest_phrase"], tidy.settings("piano", 0.5)["phrase"] + 0.5)

    def test_drums_keep_their_groove(self):
        hats = [note(i * 0.125, 42, 0.05) for i in range(64)]   # straight eighths at 240 per minute
        out = run("drums", hats)
        self.assertEqual(len(out), len(hats), "repeats and phrases don't apply to drums")

    def test_sparse_removes_more_than_busy(self):
        notes = [note(i * 0.12, 60 + i % 5, 0.1) for i in range(100)]
        sparse, default, busy = (len(run("piano", notes, b)) for b in (0.1, 0.5, 0.9))
        self.assertLess(sparse, default)
        self.assertLessEqual(default, busy)

    def test_deterministic_for_a_seed(self):
        notes = [n for i in range(30) for n in chord(i * 0.5, [60, 64, 67])]
        self.assertEqual(run("piano", notes, seed=3), run("piano", notes, seed=3))

    def test_tidy_song_only_touches_the_given_tracks(self):
        crowded = [n for i in range(10) for n in chord(i * 0.5, [48, 55, 60, 64, 67, 72])]
        song = {"piano": crowded, "guitar": crowded}
        out = tidy.tidy_song(song, 0.5, seed=1, only={"guitar"})
        self.assertEqual(out["piano"], crowded, "the user's own notes are never limited")
        self.assertLess(len(out["guitar"]), len(crowded))

    def test_per_track_busyness(self):
        crowded = [n for i in range(10) for n in chord(i * 0.5, [48, 55, 60, 64, 67, 72])]
        out = tidy.tidy_song({"piano": crowded, "guitar": crowded}, {"piano": 1.0, "guitar": 0.5})
        self.assertEqual(len(out["piano"]), len(crowded))
        self.assertLess(len(out["guitar"]), len(crowded))

    def test_input_is_not_modified(self):
        notes = chord(0, [36, 43], duration=2) + chord(1, [38], duration=2)
        copy = [dict(n) for n in notes]
        run("bass", notes)
        self.assertEqual(notes, copy)

    # ---- note_length and key: independent of busyness, and of each other ----

    def test_note_length_applies_even_at_busyness_one(self):
        notes = [note(0, 60, 0.03), note(0.1, 62, 0.03)]
        out = tidy.tidy_track("piano", notes, 1.0, random.Random(0), note_length=0.5)
        self.assertGreater(out[0]["duration"], 0.03, "stretched toward the next onset")
        self.assertEqual(tidy.tidy_track("piano", notes, 1.0, random.Random(0)), notes,
                         "without note_length, busyness 1 is still a no-op")

    def test_legato_stretches_short_notes_to_the_next_onset(self):
        notes = [note(0, 60, 0.02), note(1.0, 62, 0.02)]
        out = tidy.legato("piano", notes, min_length=0.5)
        self.assertAlmostEqual(out[0]["duration"], 0.5)   # capped, doesn't reach the next onset
        self.assertAlmostEqual(out[1]["duration"], 0.5)   # nothing after it: gets the full length

    def test_legato_never_overlaps_the_next_onset(self):
        notes = [note(0, 60, 0.02), note(0.2, 62, 0.02)]
        out = tidy.legato("piano", notes, min_length=0.5)
        self.assertLessEqual(out[0]["start"] + out[0]["duration"], out[1]["start"])

    def test_drums_are_clamped_not_stretched(self):
        notes = [note(0, 36, 20.0)]
        out = tidy.tidy_track("drums", notes, 1.0, random.Random(0), note_length=0.5)
        self.assertEqual(out[0]["duration"], tidy.DRUM_MAX_DURATION)

    def test_pitch_cooldown_drops_distant_repeats_of_one_pitch(self):
        notes = [note(t, 60, 0.05) for t in (0, 0.3, 0.6, 0.9, 1.2)]   # same pitch, 5 times
        out = tidy.pitch_cooldown("keys", notes)
        self.assertLessEqual(len(out), tidy.PITCH_COOLDOWN_MAX["keys"])
        self.assertEqual(out[0]["start"], 0, "the earliest onsets win")

    def test_pitch_cooldown_leaves_other_pitches_alone(self):
        notes = [note(t, p, 0.05) for t, p in ((0, 60), (0.1, 62), (0.2, 64))]
        self.assertEqual(tidy.pitch_cooldown("keys", notes), notes)

    def test_strict_key_snaps_out_of_key_notes(self):
        key = tracks.KEYS["C major"]   # white keys only
        notes = [note(0, 61)]   # C#, not in C major
        out = tidy.tidy_track("piano", notes, 1.0, random.Random(0), key=key, key_strict=True)
        self.assertIn(out[0]["pitch"] % 12, key)

    def test_key_without_strict_leaves_notes_alone(self):
        key = tracks.KEYS["C major"]
        notes = [note(0, 61)]
        out = tidy.tidy_track("piano", notes, 1.0, random.Random(0), key=key, key_strict=False)
        self.assertEqual(out[0]["pitch"], 61)

    def test_tidy_song_passes_note_length_and_key_per_track(self):
        short = [note(0, 60, 0.02), note(0.5, 62, 0.02)]
        out = tidy.tidy_song({"piano": short, "guitar": short}, 1.0,
                             note_length={"piano": 0.5}, key=None)
        self.assertGreater(out["piano"][0]["duration"], 0.02)
        self.assertEqual(out["guitar"], short, "a track missing from the note_length dict is untouched")


if __name__ == "__main__":
    unittest.main()

