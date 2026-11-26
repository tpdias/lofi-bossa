"""Fine-tune the pretrained model on one style.

    python training/finetune.py --style bossa
    python training/finetune.py --style lofi --epochs 2 --batch-size 16
    python training/finetune.py --style bossa --licenses cc-by   # what ships: no GigaMIDI

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
import torch.nn.functional as F
import sequences
from model import BASE_MODEL, load_model
from anticipation.vocab import ANOTE_OFFSET, NOTE_OFFSET, REST
from licenses import LICENSE_GROUPS
from tracks import ALL_FAMILY, ALL_TRACKS


def batches(data, batch_size, device, shuffle, rng):
    order = rng.permutation(len(data)) if shuffle else np.arange(len(data))
    for i in range(0, len(order), batch_size):
        rows = torch.from_numpy(data[np.sort(order[i:i + batch_size])]).long().to(device)
        mask = rows != sequences.PAD
        yield rows.masked_fill(~mask, 0), mask, rows.masked_fill(~mask, -100)


AMP = True   # mixed precision on CUDA; turned off by --no-amp


def forward(model, batch, device):
    ids, mask, labels = batch
    with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=AMP and device == "cuda"):
        return model(ids, attention_mask=mask, labels=labels).loss


def _track_table(device):
    """instrument id (0..128) -> index into ALL_TRACKS, or -1 for instruments we don't track."""
    table = torch.full((129,), -1, dtype=torch.long)
    for i, t in enumerate(ALL_TRACKS):
        for instr in ALL_FAMILY[t]:
            table[instr] = i
    return table.to(device)


def target_tracks(ids, table):
    """For every position, the track index of the note its event triple belongs to (-1: none).
    Rows are [mode, (time, duration, note) x N]; control events use a second note range."""
    length = ids.shape[1]
    pos = torch.arange(length, device=ids.device)
    note_pos = 3 * ((pos - 1).clamp(min=0) // 3) + 3
    note = ids[:, note_pos.clamp(max=length - 1)]
    control = note >= ANOTE_OFFSET
    is_note = (control & (note < ANOTE_OFFSET + 129 * 128)) | ((note >= NOTE_OFFSET) & (note < REST))
    instr = (torch.where(control, note - ANOTE_OFFSET, note - NOTE_OFFSET) // 128).clamp(0, 128)
    valid = is_note & (pos >= 1)[None] & (note_pos < length)[None]
    return torch.where(valid, table[instr], torch.full_like(instr, -1))


@torch.no_grad()
def evaluate(model, data, batch_size, device, max_batches):
    """Mean validation loss per token, overall and per track: {"all": x, "piano": y, ...}."""
    model.eval()
    table = _track_table(device)
    total, count = 0.0, 0
    by_track, by_count = torch.zeros(len(ALL_TRACKS), device=device), torch.zeros(len(ALL_TRACKS), device=device)
    for n, (ids, mask, labels) in enumerate(batches(data, batch_size, device, False, None)):
        if max_batches and n >= max_batches:
            break
        with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=AMP and device == "cuda"):
            logits = model(ids, attention_mask=mask).logits
        ce = F.cross_entropy(logits[:, :-1].float().reshape(-1, logits.shape[-1]),
                             labels[:, 1:].reshape(-1), ignore_index=-100, reduction="none")
        ce = ce.view(ids.shape[0], -1)
        valid = labels[:, 1:] != -100
        total += ce[valid].sum().item()
        count += valid.sum().item()
        tr = target_tracks(ids, table)[:, 1:]
        for i in range(len(ALL_TRACKS)):
            sel = valid & (tr == i)
            by_track[i] += ce[sel].sum()
            by_count[i] += sel.sum()
    model.train()
    out = {"all": total / count if count else float("nan")}
    for i, t in enumerate(ALL_TRACKS):
        if by_count[i] > 0:
            out[t] = (by_track[i] / by_count[i]).item()
    return out


def show(result):
    return "  ".join(f"{k} {v:.3f}" for k, v in result.items() if k != "all")


def freeze(model, layers):
    """Freeze the embeddings (the output layer is tied to them) and the first `layers` blocks."""
    body = model.transformer
    for p in list(body.wte.parameters()) + list(body.wpe.parameters()):
        p.requires_grad = False
    for block in body.h[:layers]:
        for p in block.parameters():
            p.requires_grad = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", required=True, choices=("lofi", "bossa"))
    ap.add_argument("--processed", default="processed", type=Path)
    ap.add_argument("--out", type=Path, help="default: checkpoints/<style>")
    ap.add_argument("--base", default=BASE_MODEL)
    ap.add_argument("--tiers", default="core,wide")
    ap.add_argument("--copies", type=int, default=2,
                    help="times each file is used: 1 plain + the rest with some tracks held fixed")
    ap.add_argument("--core-boost", type=int, default=1, help="extra weight for core-tier files")
    ap.add_argument("--boost-vibes", type=int, default=3,
                    help="extra copies of files with vibes where vibes is the track written (rare in the data)")
    ap.add_argument("--boost-lead", type=int, default=1, help="same for lead")
    ap.add_argument("--transpose", action="store_true",
                    help="shift each training copy by a random -5..+6 semitones (drums stay put)")
    ap.add_argument("--epochs", type=float, default=1)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--lr", type=float, default=5e-6,
                    help="small on purpose: ~2k files per style overfit quickly at 2e-5")
    ap.add_argument("--weight-decay", type=float, default=0.05, help="not applied to biases and layer norms")
    ap.add_argument("--dropout", type=float, help="embedding/residual/attention dropout while training "
                    "(default: the model's own 0.1)")
    ap.add_argument("--freeze-layers", type=int, default=0,
                    help="freeze the embeddings and the first N of the 12 transformer blocks")
    ap.add_argument("--patience", type=int, default=5,
                    help="stop after this many validation runs in a row without a new best (0 = never)")
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--eval-every", type=int, default=200, help="steps between validation runs")
    ap.add_argument("--eval-batches", type=int, default=0, help="0 = whole validation set")
    ap.add_argument("--max-steps", type=int, help="stop early (for quick checks)")
    ap.add_argument("--limit-files", type=int, help="use only this many files (for quick checks)")
    ap.add_argument("--no-amp", action="store_true", help="full precision on CUDA (slower, more memory)")
    ap.add_argument("--eval-only", action="store_true",
                    help="print the validation loss of the base model and exit")
    ap.add_argument("--rebuild", action="store_true", help="ignore cached training sequences")
    ap.add_argument("--save-last", action="store_true",
                    help="also save the final weights to <out>-last, whatever the validation loss")
    ap.add_argument("--licenses", default="all", choices=sorted(LICENSE_GROUPS),
                    help="cc-by: train only on CC BY (or more permissive) sources, i.e. no GigaMIDI. "
                         "Required for checkpoints that ship; see training/DATA_LICENSES.md")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    global AMP
    AMP = not args.no_amp
    import sys
    import transformers
    print(f"python {sys.version.split()[0]}, torch {torch.__version__}, transformers {transformers.__version__}")
    out = args.out or Path("checkpoints") / args.style
    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    # Building sequences takes a while on the full dataset, so the result is cached.
    key = f"{args.style}-{args.tiers.replace(',', '+')}-c{args.copies}-b{args.core_boost}-s{args.seed}-v{args.boost_vibes}l{args.boost_lead}{'t' if args.transpose else ''}{'' if args.licenses == 'all' else '-' + args.licenses}"
    cache = args.processed / "sequences" / f"{key}{f'-n{args.limit_files}' if args.limit_files else ''}.npz"
    if cache.exists() and not args.rebuild:
        saved = np.load(cache)
        train, val = saved["train"], saved["val"]
        print(f"loaded {len(train)} training and {len(val)} validation sequences from {cache}")
    else:
        train, val = sequences.build(
            args.processed / "index.jsonl", args.processed, args.style, set(args.tiers.split(",")),
            args.copies, args.core_boost, limit=args.limit_files, seed=args.seed,
            boosts={"vibes": args.boost_vibes, "lead": args.boost_lead}, transpose=args.transpose,
            licenses=args.licenses)
        cache.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(cache, train=train, val=val)
    if len(train) == 0 or len(val) == 0:
        raise SystemExit("not enough data: need at least one training and one validation sequence")

    model = load_model(args.base, args.dropout).to(device).train()
    if args.freeze_layers:
        freeze(model, args.freeze_layers)
    params = [(n, p) for n, p in model.named_parameters() if p.requires_grad]
    optimizer = torch.optim.AdamW([
        {"params": [p for n, p in params if p.ndim >= 2], "weight_decay": args.weight_decay},
        {"params": [p for n, p in params if p.ndim < 2], "weight_decay": 0.0},
    ], lr=args.lr)
    steps_per_epoch = math.ceil(len(train) / args.batch_size)
    total = min(int(steps_per_epoch * args.epochs), args.max_steps or 10**12)
    warmup = min(args.warmup, max(total // 10, 1))
    schedule = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: (
        (s + 1) / warmup if s < warmup
        else 0.5 * (1 + math.cos(math.pi * (s - warmup) / max(total - warmup, 1)))))

    base_eval = evaluate(model, val, args.batch_size, device, args.eval_batches)
    baseline = base_eval["all"]
    if args.eval_only:
        print(f"{device}{'' if AMP else ' (no amp)'}: validation loss of {args.base} = {baseline:.4f}")
        print("  per track: " + show(base_eval))
        return
    print(f"{device}: {total} steps, {steps_per_epoch} per epoch; "
          f"validation loss before training {baseline:.4f}")
    print("  per track: " + show(base_eval))
    log = {"style": args.style, "base": args.base, "licenses": args.licenses, "args": {k: str(v) for k, v in vars(args).items()},
           "train_sequences": len(train), "val_sequences": len(val),
           "baseline_val_loss": baseline, "baseline_by_track": base_eval, "evals": []}
    best, step, started, recent, stale, stop = baseline, 0, time.time(), [], 0, False

    def checkpoint():
        nonlocal best, stale, stop
        result = evaluate(model, val, args.batch_size, device, args.eval_batches)
        loss = result["all"]
        improved = loss < best
        log["evals"].append({"step": step, "val_loss": loss, "train_loss": sum(recent) / len(recent),
                             "by_track": result})
        stale = 0 if improved else stale + 1
        stop = bool(args.patience) and stale >= args.patience
        if improved:
            best = loss
            model.save_pretrained(out)
            # the server reads this to know which tracks the checkpoint was trained on
            (out / "tracks.json").write_text(json.dumps(list(ALL_TRACKS)))
        log["best_val_loss"] = best
        out.mkdir(parents=True, exist_ok=True)
        (out / "training_log.json").write_text(json.dumps(log, indent=2))
        print(f"step {step}/{total}  train {sum(recent) / len(recent):.4f}  val {loss:.4f}"
              f"{'  (saved)' if improved else ''}  {time.time() - started:.0f}s", flush=True)
        print("  per track: " + show(result), flush=True)
        if stop:
            print(f"no new best in {args.patience} validation runs: stopping early", flush=True)

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
            if step >= total or stop:
                break
        if stop:
            break

    if args.save_last:
        model.save_pretrained(Path(f"{out}-last"))
    if best < baseline:
        print(f"done: validation loss {baseline:.4f} -> {best:.4f}; checkpoint in {out}/")
    else:
        print(f"done: validation loss did not improve on {baseline:.4f}; no checkpoint saved")


if __name__ == "__main__":
    main()
