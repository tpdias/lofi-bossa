"""Copy the GigaMIDI files named in the manifest out of the downloaded zips.

    python training/data/gigamidi_extract.py --zips data/Final_GigaMIDI_V1.1_Final

Writes datasets/gigamidi/<md5>.mid. Only manifest files are extracted (a few thousand out of
2.1 million). The training zip holds three inner zips; those are unpacked next to it once.
"""

import argparse
import json
import zipfile
from pathlib import Path


def inner_zips(zips_dir):
    """Yield every zip that directly contains MIDI files, unpacking nested zips on first use."""
    for outer in sorted(zips_dir.glob("*.zip")):
        with zipfile.ZipFile(outer) as z:
            nested = [n for n in z.namelist() if n.endswith(".zip") and not n.startswith("__MACOSX")]
            if not nested:
                yield outer
                continue
            for name in nested:
                target = zips_dir / "unpacked" / outer.stem / Path(name).name
                if not target.exists():
                    print(f"  unpacking {name} from {outer.name}")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(name) as src, open(target, "wb") as dst:
                        while chunk := src.read(1 << 22):
                            dst.write(chunk)
                yield target


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zips", default="data/Final_GigaMIDI_V1.1_Final", type=Path)
    ap.add_argument("--manifest", default="processed/manifest.jsonl", type=Path)
    ap.add_argument("--out", default="datasets/gigamidi", type=Path)
    args = ap.parse_args()

    wanted = {json.loads(line)["path"] for line in open(args.manifest)
              if json.loads(line)["source"] == "gigamidi"}
    args.out.mkdir(parents=True, exist_ok=True)
    wanted -= {p.name for p in args.out.glob("*.mid")}
    print(f"{len(wanted)} files to extract")

    found = 0
    for archive in inner_zips(args.zips):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                name = Path(info.filename).name
                if name in wanted and not info.filename.startswith("__MACOSX"):
                    (args.out / name).write_bytes(z.read(info))
                    wanted.discard(name)
                    found += 1
        print(f"  {archive.name}: {found} extracted so far")
    print(f"extracted {found}; {len(wanted)} not found in the zips")


if __name__ == "__main__":
    main()
