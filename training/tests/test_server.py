"""The server's choice of model when a checkpoint folder is incomplete."""

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402


def make(folder, *files):
    folder.mkdir(parents=True)
    (folder / "config.json").write_text(json.dumps({}))
    for f in files:
        (folder / f).write_bytes(b"x")


class MissingWeightsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        patch = mock.patch.object(server, "CHECKPOINTS", self.tmp)
        patch.start()
        self.addCleanup(patch.stop)
        make(self.tmp / "lofi")                         # config only: the weights were moved away
        make(self.tmp / "bossa", "model.safetensors")

    def test_a_checkpoint_without_weights_is_not_used(self):
        self.assertFalse(server.has_finetuned("lofi"))
        self.assertTrue(server.has_finetuned("bossa"))
        self.assertEqual(server.model_source("lofi"), server.BASE_MODEL, "auto falls back to pretrained")
        self.assertEqual(server.model_source("bossa"), str(self.tmp / "bossa"))

    def test_choosing_a_missing_finetuned_model_says_why(self):
        with self.assertRaises(server.HTTPException) as ctx:
            server.get_model("lofi", "finetuned")
        self.assertEqual(ctx.exception.status_code, 422)
        self.assertIn("no model weights", ctx.exception.detail)


if __name__ == "__main__":
    unittest.main()
