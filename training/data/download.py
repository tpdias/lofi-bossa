"""Download datasets into ./datasets/<name>/.

    python training/data/download.py groove guitarset        # small (3 MB, 39 MB)
    python training/data/download.py midicaps-meta           # 428 MB metadata
    python training/data/download.py midicaps-midi           # 1.6 GB, run on the GPU box

Not handled here (need an account):
  - Kaggle "Lo-Fi Hip Hop MIDIs": download from
    https://www.kaggle.com/datasets/zakarii/lofi-hip-hop-midi and unzip into datasets/kaggle_lofi/
  - GigaMIDI: request access at https://huggingface.co/datasets/Metacreation/GigaMIDI
"""

import argparse
import shutil
import tarfile
import urllib.request
import zipfile
from pathlib import Path

SOURCES = {
    "groove": (
        "https://storage.googleapis.com/magentadata/datasets/groove/groove-v1.0.0-midionly.zip",
        "groove.zip",
    ),
    "guitarset": (
        "https://zenodo.org/records/3371780/files/annotation.zip",
        "annotation.zip",
    ),
    "midicaps-meta": (
        "https://huggingface.co/datasets/amaai-lab/MidiCaps/resolve/main/train.json",
        "train.json",
    ),
    "midicaps-midi": (
        "https://huggingface.co/datasets/amaai-lab/MidiCaps/resolve/main/midicaps.tar.gz",
        "midicaps.tar.gz",
    ),
}

# several downloads share one dataset folder
FOLDER = {"midicaps-meta": "midicaps", "midicaps-midi": "midicaps"}


def fetch(url, dest):
    if dest.exists():
        print(f"  already have {dest.name}")
        return
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "dataset-downloader"})
    with urllib.request.urlopen(req) as r, open(tmp, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        print(f"  downloading {dest.name} ({total / 1e6:.0f} MB)")
        shutil.copyfileobj(r, f, length=1 << 20)
    tmp.rename(dest)


def unpack(archive, out_dir):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            for member in z.namelist():
                target = (out_dir / member).resolve()
                if not target.is_relative_to(out_dir.resolve()):
                    raise ValueError(f"unsafe path in archive: {member}")
            z.extractall(out_dir)
    elif archive.name.endswith(".tar.gz"):
        with tarfile.open(archive) as t:
            t.extractall(out_dir, filter="data")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="+", choices=sorted(SOURCES))
    ap.add_argument("--root", default="datasets", type=Path)
    args = ap.parse_args()

    for name in args.names:
        url, filename = SOURCES[name]
        out_dir = args.root / FOLDER.get(name, name)
        out_dir.mkdir(parents=True, exist_ok=True)
        print(name)
        archive = out_dir / filename
        fetch(url, archive)
        if archive.suffix == ".zip" or archive.name.endswith(".tar.gz"):
            marker = out_dir / f".{filename}.unpacked"
            if not marker.exists():
                unpack(archive, out_dir)
                marker.touch()


if __name__ == "__main__":
    main()
