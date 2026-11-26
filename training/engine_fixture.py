"""Reference logits for checking an exported .aimodel from Swift (`LofiBossa --engine-bench`).

    .venv/bin/python training/engine_fixture.py [--source checkpoints/bossa] --out exports/base-fixture.json

Takes the first `--prompt` tokens of a validation sequence, runs the PyTorch model (fp32, the
same eager attention the export uses), and records the top logits after the prompt and after
one more decoded token. The Swift side runs the same tokens through the asset's prefill and
decode entrypoints and compares.
"""

import argparse
import json
from pathlib import Path

import torch

import export_coreai as e
from model import load_model


def top(logits, k):
    values, indices = torch.topk(logits, k)
    return {"indices": indices.tolist(), "values": [round(v, 5) for v in values.tolist()]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=None)
    ap.add_argument("--prompt", type=int, default=60)
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--out", default="exports/base-fixture.json")
    args = ap.parse_args()

    model = (load_model(args.source) if args.source else load_model()).eval()
    seq = e.load_val_sequences(1)[0][0].tolist()   # run from the repo root (reads processed/sequences)
    ids = seq[: args.prompt + 1]
    prompt, nxt = ids[: args.prompt], ids[args.prompt]
    with torch.no_grad():
        logits = model(torch.tensor([ids])).logits[0]
    fixture = {
        "source": args.source or "base",
        "prompt": [int(t) for t in prompt],
        "next_token": int(nxt),
        "after_prompt": top(logits[args.prompt - 1], args.top),
        "after_next": top(logits[args.prompt], args.top),
    }
    Path(args.out).write_text(json.dumps(fixture))
    print(f"wrote {args.out}: prompt {len(prompt)} tokens, argmax {fixture['after_prompt']['indices'][0]}")


if __name__ == "__main__":
    main()
