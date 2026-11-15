"""Fine-tune the pretrained model on one style.

    python training/finetune.py --style bossa
    python training/finetune.py --style lofi --epochs 2 --batch-size 16

Reads processed/index.jsonl (from preprocess.py), builds training sequences, and saves the
checkpoint with the lowest validation loss to checkpoints/<style>/. The inference server
picks that folder up automatically.

Meant for a CUDA GPU. It also runs on Apple Silicon (slowly) for a quick check:
    python training/finetune.py --style bossa --limit-files 40 --max-steps 30 --batch-size 2
"""

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModelForCausalLM

import sequences

BASE_MODEL = "stanford-crfm/music-small-800k"


def batches(data, batch_size, device, shuffle, rng):
    order = rng.permutation(len(data)) if shuffle else np.arange(len(data))
    for i in range(0, len(order), batch_size):
        rows = torch.from_numpy(data[np.sort(order[i:i + batch_size])]).long().to(device)
        mask = rows != sequences.PAD
        yield rows.masked_fill(~mask, 0), mask, rows.masked_fill(~mask, -100)


def forward(model, batch, device):
    ids, mask, labels = batch
    with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=device == "cuda"):
        return model(ids, attention_mask=mask, labels=labels).loss


@torch.no_grad()
def evaluate(model, data, batch_size, device, max_batches):
    model.eval()
    losses = []
    for n, batch in enumerate(batches(data, batch_size, device, False, None)):
        if max_batches and n >= max_batches:
            break
        losses.append(forward(model, batch, device).item())
    model.train()
    return sum(losses) / len(losses) if losses else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", required=True, choices=("lofi", "bossa"))
    ap.add_argument("--processed", default="processed", type=Path)
    ap.add_argument("--out", type=Path, help="default: checkpoints/<style>")
    ap.add_argument("--base", default=BASE_MODEL)
    ap.add_argument("--tiers", default="core,wide")
    ap.add_argument("--copies", type=int, default=4,
                    help="times each file is used: 1 plain + the rest with some tracks held fixed")
    ap.add_argument("--core-boost", type=int, default=3, help="extra weight for core-tier files")
    ap.add_argument("--epochs", type=float, default=3)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--eval-every", type=int, default=500, help="steps between validation runs")
    ap.add_argument("--eval-batches", type=int, default=200, help="0 = whole validation set")
    ap.add_argument("--max-steps", type=int, help="stop early (for quick checks)")
    ap.add_argument("--limit-files", type=int, help="use only this many files (for quick checks)")
    ap.add_argument("--rebuild", action="store_true", help="ignore cached training sequences")
    ap.add_argument("--save-last", action="store_true",
                    help="also save the final weights to <out>-last, whatever the validation loss")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    out = args.out or Path("checkpoints") / args.style
    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    # Building sequences takes a while on the full dataset, so the result is cached.
    key = f"{args.style}-{args.tiers.replace(',', '+')}-c{args.copies}-b{args.core_boost}-s{args.seed}"
    cache = args.processed / "sequences" / f"{key}{f'-n{args.limit_files}' if args.limit_files else ''}.npz"
    if cache.exists() and not args.rebuild:
        saved = np.load(cache)
        train, val = saved["train"], saved["val"]
        print(f"loaded {len(train)} training and {len(val)} validation sequences from {cache}")
    else:
        train, val = sequences.build(
            args.processed / "index.jsonl", args.processed, args.style, set(args.tiers.split(",")),
            args.copies, args.core_boost, limit=args.limit_files, seed=args.seed)
        cache.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(cache, train=train, val=val)
    if len(train) == 0 or len(val) == 0:
        raise SystemExit("not enough data: need at least one training and one validation sequence")

    model = AutoModelForCausalLM.from_pretrained(args.base).to(device).train()
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    steps_per_epoch = math.ceil(len(train) / args.batch_size)
    total = min(int(steps_per_epoch * args.epochs), args.max_steps or 10**12)
    warmup = min(args.warmup, max(total // 10, 1))
    schedule = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: (
        (s + 1) / warmup if s < warmup
        else 0.5 * (1 + math.cos(math.pi * (s - warmup) / max(total - warmup, 1)))))

    baseline = evaluate(model, val, args.batch_size, device, args.eval_batches)
    print(f"{device}: {total} steps, {steps_per_epoch} per epoch; "
          f"validation loss before training {baseline:.4f}")
    log = {"style": args.style, "base": args.base, "args": {k: str(v) for k, v in vars(args).items()},
           "train_sequences": len(train), "val_sequences": len(val),
           "baseline_val_loss": baseline, "evals": []}
    best, step, started, recent = baseline, 0, time.time(), []

    def checkpoint():
        nonlocal best
        loss = evaluate(model, val, args.batch_size, device, args.eval_batches)
        improved = loss < best
        log["evals"].append({"step": step, "val_loss": loss, "train_loss": sum(recent) / len(recent)})
        if improved:
            best = loss
            model.save_pretrained(out)
        log["best_val_loss"] = best
        out.mkdir(parents=True, exist_ok=True)
        (out / "training_log.json").write_text(json.dumps(log, indent=2))
        print(f"step {step}/{total}  train {sum(recent) / len(recent):.4f}  val {loss:.4f}"
              f"{'  (saved)' if improved else ''}  {time.time() - started:.0f}s", flush=True)

    while step < total:
        for batch in batches(train, args.batch_size, device, True, rng):
            loss = forward(model, batch, device)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            schedule.step()
            optimizer.zero_grad(set_to_none=True)
            step += 1
            recent = (recent + [loss.item()])[-50:]
            if step % args.eval_every == 0 or step == total:
                checkpoint()
            if step >= total:
                break

    if args.save_last:
        model.save_pretrained(Path(f"{out}-last"))
    if best < baseline:
        print(f"done: validation loss {baseline:.4f} -> {best:.4f}; checkpoint in {out}/")
    else:
        print(f"done: validation loss did not improve on {baseline:.4f}; no checkpoint saved")


if __name__ == "__main__":
    main()
