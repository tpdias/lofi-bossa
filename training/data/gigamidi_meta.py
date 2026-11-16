"""Reduce GigaMIDI's 1.2 GB metadata CSV to the columns the style filter needs.

    python training/data/gigamidi_meta.py --out data/gigamidi_styles.jsonl

Streams the CSV from Hugging Face (needs `hf auth login` on an account with access to
Metacreation/GigaMIDI) and keeps only files that carry a style label, a title or an artist.
Pass --csv to read a local copy instead.
"""

import argparse
import ast
import csv
import io
import json
import re
import sys
from pathlib import Path

REMOTE = "datasets/Metacreation/GigaMIDI/Final-Metadata-Extended-GigaMIDI-Dataset-updated.csv"
STYLE_COLUMNS = {
    "curated": "music_styles_curated",
    "scraped": "music_style_scraped",
    "discogs": "music_style_audio_text_Discogs",
    "lastfm": "music_style_audio_text_Lastfm",
    "tagtraum": "music_style_audio_text_Tagtraum",
}


def labels(value):
    """A style cell is empty, a single label, or a Python-style list of labels."""
    value = (value or "").strip()
    if not value or value in ("[]", "nan"):
        return []
    if value[0] in "[(":
        try:
            parsed = ast.literal_eval(value)
            return [str(v).strip().lower() for v in parsed if str(v).strip()]
        except (ValueError, SyntaxError):
            pass
    return [value.lower()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", help="local copy of the metadata CSV (default: stream from Hugging Face)")
    ap.add_argument("--out", default="data/gigamidi_styles.jsonl", type=Path)
    args = ap.parse_args()

    csv.field_size_limit(sys.maxsize)
    if args.csv:
        stream = open(args.csv, newline="", encoding="utf-8", errors="replace")
    else:
        from huggingface_hub import HfFileSystem
        raw = HfFileSystem().open(REMOTE, "rb", block_size=16 << 20)
        stream = io.TextIOWrapper(raw, encoding="utf-8", errors="replace", newline="")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    total = kept = 0
    with stream, open(args.out, "w") as out:
        for row in csv.DictReader(stream):
            total += 1
            styles = {name: labels(row.get(col)) for name, col in STYLE_COLUMNS.items()}
            styles = {k: v for k, v in styles.items() if v}
            if not styles and not row.get("title") and not row.get("artist"):
                continue
            qpm = re.search(r"qpm=([\d.]+)", row.get("tempo") or "")
            out.write(json.dumps({
                "md5": row["md5"],
                "path": row["file_path"],
                "type": row["Type"],
                "tempo": round(float(qpm.group(1)), 1) if qpm else None,
                "title": row.get("title") or None,
                "artist": row.get("artist") or None,
                "styles": styles,
            }) + "\n")
            kept += 1
            if total % 200_000 == 0:
                print(f"  {total} rows read, {kept} kept", flush=True)
    print(f"{kept} of {total} files have a style label, title or artist -> {args.out}")


if __name__ == "__main__":
    main()
