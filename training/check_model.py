"""Smoke test for the pretrained Anticipatory Music Transformer.

    python training/check_model.py processed/midi/bossa/<some guitar file>.mid

Checks three things the project depends on:
  1. the checkpoint loads through Hugging Face transformers and generates music
  2. it can write accompaniment around a fixed track (what "regenerate one track" needs)
  3. a training loss computes and backpropagates (what fine-tuning needs)

Outputs go to processed/check/.
"""

import sys
import time
from pathlib import Path

import torch
from anticipation import ops
from anticipation.config import EVENT_SIZE, M
from anticipation.convert import events_to_midi, midi_to_events
from anticipation.sample import generate
from anticipation.vocab import AUTOREGRESS, CONTROL_OFFSET

from model import BASE_MODEL as MODEL, load_model
SECONDS = 12


def instrument_names(events):
    return {("drums" if i == 128 else f"program {i}"): n for i, n in ops.get_instruments(events).items()}


def main():
    source = Path(sys.argv[1])
    out = Path("processed/check")
    out.mkdir(parents=True, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"

    model = load_model(MODEL).to(device).eval()
    params = sum(p.numel() for p in model.parameters()) / 1e6
    print(f"loaded {MODEL}: {params:.0f}M parameters on {device}")

    # 1. unconditional generation
    t = time.time()
    events = generate(model, start_time=0, end_time=SECONDS, top_p=0.98)
    events_to_midi(events).save(str(out / "unconditional.mid"))
    print(f"1. generated {SECONDS}s, {len(events) // EVENT_SIZE} notes in {time.time() - t:.0f}s: "
          f"{instrument_names(events)}")

    # 2. accompaniment: keep the source track fixed, generate everything else
    fixed = ops.clip(midi_to_events(str(source)), 0, SECONDS)
    controls = [tok + CONTROL_OFFSET for tok in fixed]
    t = time.time()
    new = generate(model, start_time=0, end_time=SECONDS, controls=controls, top_p=0.98)
    combined = ops.combine(new, controls)
    events_to_midi(combined).save(str(out / "accompaniment.mid"))

    def triples(ev):
        return sorted(tuple(ev[i:i + EVENT_SIZE]) for i in range(0, len(ev), EVENT_SIZE))

    kept = triples(ops.clip(fixed, 0.05, SECONDS, clip_duration=False))
    result = triples(combined)
    preserved = all(k in result for k in kept)
    print(f"2. accompaniment in {time.time() - t:.0f}s: fixed track preserved = {preserved}, "
          f"added {len(new) // EVENT_SIZE} notes: {instrument_names(new)}")

    # 3. training loss on real data (one context window, as the fine-tune loop will see it)
    window = [AUTOREGRESS] + ops.clip(midi_to_events(str(source)), 0, 60)[: EVENT_SIZE * M]
    ids = torch.tensor(window, device=device).unsqueeze(0)
    model.train()
    loss = model(ids, labels=ids).loss
    loss.backward()
    grad = sum(p.grad.abs().sum().item() for p in model.parameters() if p.grad is not None)
    print(f"3. loss on {source.name}: {loss.item():.2f} nats/token "
          f"(uniform guess would be {torch.log(torch.tensor(float(model.config.vocab_size))).item():.2f}), "
          f"gradients flow = {grad > 0}")


if __name__ == "__main__":
    main()
