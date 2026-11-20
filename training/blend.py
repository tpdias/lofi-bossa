"""Blend the base model with a fine-tuned checkpoint and keep the mix with the lowest
validation loss. Mixing the weights keeps part of the fine-tune while recovering the base
model's generality, which often beats either end when fine-tuning overfits a small dataset.

    python training/blend.py --style bossa --sequences processed/sequences/<cache>.npz

Reads checkpoints/<style>, writes the best mix to checkpoints/<style>-blend (use it by
renaming it to checkpoints/<style>). alpha 0 = the base model, 1 = the fine-tuned one.
"""

import argparse
import json
import shutil
from pathlib import Path

import numpy as np
import torch
from finetune import evaluate, show
from model import BASE_MODEL, load_model


def mix(base, tuned, alpha):
    out = {}
    for k, v in base.items():
        out[k] = torch.lerp(v.float(), tuned[k].float(), alpha).to(v.dtype) if v.is_floating_point() else v
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--style", required=True, choices=("lofi", "bossa"))
    ap.add_argument("--sequences", required=True, type=Path, help="the cached .npz that finetune.py built")
    ap.add_argument("--checkpoints", default="checkpoints", type=Path)
    ap.add_argument("--base", default=BASE_MODEL)
    ap.add_argument("--alphas", default="0.25,0.5,0.75")
    ap.add_argument("--batch-size", type=int, default=8)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    val = np.load(args.sequences)["val"]
    src = args.checkpoints / args.style
    base = load_model(args.base).to(device).eval()
    tuned_state = {k: v.to(device) for k, v in load_model(str(src)).state_dict().items()}
    base_state = {k: v.clone() for k, v in base.state_dict().items()}

    results = {}
    for alpha in [0.0] + [float(a) for a in args.alphas.split(",")] + [1.0]:
        base.load_state_dict(mix(base_state, tuned_state, alpha))
        results[alpha] = evaluate(base, val, args.batch_size, device, 0)
        print(f"alpha {alpha:.2f}  val {results[alpha]['all']:.4f}   {show(results[alpha])}", flush=True)
    best = min(results, key=lambda a: results[a]["all"])
    print(f"best alpha {best:.2f} (val {results[best]['all']:.4f}; base {results[0.0]['all']:.4f})")
    if best in (0.0, 1.0):
        print("an end of the range won: no blend written" if best == 1.0 else
              "the base model beat every mix: fine-tuning did not help; keep using the pretrained model")
        return
    out = args.checkpoints / f"{args.style}-blend"
    base.load_state_dict(mix(base_state, tuned_state, best))
    base.save_pretrained(out)
    shutil.copy(src / "tracks.json", out / "tracks.json") if (src / "tracks.json").exists() else None
    (out / "blend.json").write_text(json.dumps({"alpha": best, "results": {str(a): r for a, r in results.items()}}, indent=2))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
