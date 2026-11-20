"""Tests for the pure helpers in finetune.py and blend.py (no model needed)."""

import sys
import unittest
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import blend  # noqa: E402
import finetune  # noqa: E402
from anticipation.vocab import ANOTE_OFFSET, NOTE_OFFSET, REST  # noqa: E402
from tracks import ALL_TRACKS  # noqa: E402


class FinetuneHelperTests(unittest.TestCase):
    def test_target_tracks_follow_the_note_of_each_triple(self):
        # [mode, (time, dur, note) x 3]: a piano note, a vibes control, a drum hit
        ids = torch.tensor([[0, 5, 6, NOTE_OFFSET + 0 * 128 + 60,
                             7, 8, ANOTE_OFFSET + 11 * 128 + 70,
                             9, 10, NOTE_OFFSET + 128 * 128 + 36]])
        got = finetune.target_tracks(ids, finetune._track_table("cpu"))[0].tolist()
        piano, vibes, drums = (ALL_TRACKS.index(t) for t in ("piano", "vibes", "drums"))
        self.assertEqual(got, [-1, piano, piano, piano, vibes, vibes, vibes, drums, drums, drums])

    def test_rests_and_unknown_instruments_belong_to_no_track(self):
        ids = torch.tensor([[0, 1, 2, REST, 3, 4, NOTE_OFFSET + 100 * 128 + 60]])   # program 100: not ours
        self.assertEqual(finetune.target_tracks(ids, finetune._track_table("cpu"))[0].tolist(), [-1] * 7)

    def test_blend_interpolates_floats_and_keeps_the_rest(self):
        base = {"w": torch.zeros(2), "n": torch.tensor([1, 2])}
        tuned = {"w": torch.ones(2), "n": torch.tensor([9, 9])}
        out = blend.mix(base, tuned, 0.25)
        self.assertTrue(torch.allclose(out["w"], torch.full((2,), 0.25)))
        self.assertEqual(out["n"].tolist(), [1, 2])


if __name__ == "__main__":
    unittest.main()
