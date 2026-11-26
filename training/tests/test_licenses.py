"""Tests for the --licenses filter (training/licenses.py) and its use in preprocess and sequences."""

import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

TRAINING = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TRAINING))
import licenses  # noqa: E402
import sequences  # noqa: E402


def rows():
    return [{"id": f"{s}-1", "source": s, "style": "bossa", "tier": "core"}
            for s in ("lakh", "groove", "guitarset", "gigamidi", "midicaps", "kaggle_lofi", "somethingnew")]


class LicenseFilterTests(unittest.TestCase):
    def test_cc_by_keeps_only_cc_by_sources(self):
        kept = [r["source"] for r in licenses.filter_rows(rows(), "cc-by")]
        self.assertEqual(kept, ["lakh", "groove", "guitarset"])

    def test_all_keeps_everything(self):
        self.assertEqual(len(licenses.filter_rows(rows(), "all")), len(rows()))

    def test_gigamidi_is_never_cc_by(self):
        self.assertFalse(licenses.allowed("gigamidi", "cc-by"))
        self.assertTrue(licenses.allowed("gigamidi", "all"))

    def test_unknown_group_is_an_error(self):
        with self.assertRaises(KeyError):
            licenses.allowed("lakh", "mit")

    def test_sequences_build_leaves_out_gigamidi(self):
        with tempfile.TemporaryDirectory() as d:
            index = Path(d) / "index.jsonl"
            index.write_text("".join(json.dumps({**r, "file": "missing.mid", "tracks": []}) + "\n" for r in rows()))
            seen = []
            with mock.patch.object(sequences.multiprocessing, "Pool", _InlinePool), \
                    mock.patch.object(sequences, "file_rows", lambda job: seen.append(job[0].name) or []):
                sequences.build(index, d, "bossa", {"core"}, 1, 1, licenses="cc-by")
            self.assertEqual(len(seen), 3)

    def test_preprocess_cli_drops_gigamidi_rows(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = Path(d) / "manifest.jsonl"
            manifest.write_text("".join(json.dumps({**r, "path": "x.mid", "multitrack": True}) + "\n" for r in rows()))
            for r in rows():
                (Path(d) / r["source"]).mkdir()
                (Path(d) / r["source"] / "x.mid").write_bytes(b"not midi")
            out = subprocess.run(
                [sys.executable, str(TRAINING / "preprocess.py"), "--manifest", str(manifest), "--root", d,
                 "--out", d, "--licenses", "cc-by", "--workers", "1"],
                capture_output=True, text=True, check=True).stdout
            self.assertIn("left out 4 manifest rows", out)
            self.assertIn("of 3 files", out)


class _InlinePool:
    """Stand-in for multiprocessing.Pool that runs jobs in this process (so a patched
    file_rows is seen)."""
    def __init__(self, *a, **k):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def imap_unordered(self, fn, jobs, chunksize=1):
        return map(fn, jobs)


if __name__ == "__main__":
    unittest.main()
