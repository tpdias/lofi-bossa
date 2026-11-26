# Core AI on-device spike

Question: can the Anticipatory Music Transformer (GPT-2, 128M params, checkpoints at
`checkpoints/bossa` / `checkpoints/lofi`) run on-device via Apple's Core AI framework
(WWDC26), as a replacement for the local Python server?

**Go, with one open question (real on-device speed) that this spike couldn't answer.**
Conversion works, numerics match, and fp16/int8 weights are free. But the only
throughput numbers available here are from the pip-installed `coreai-core`, which prints
"Dev installation detected. Using local Core AI Framework." on import — a CPU reference
interpreter, not the hardware-accelerated runtime a real macOS 27 app would link against.
Those numbers (63 tok/s prefill, 2.1 tok/s decode) are almost certainly pessimistic and
should not be used to size the Swift work; they only prove the pipeline runs end to end.
The real test needs an actual macOS 27 app target.

## What was tried

`training/export_coreai.py` (new) wraps `model.load_model`'s GPT-2 in `StatefulGPT2`, a
hand-rolled eager-attention forward pass (same math as `scale_attn_by_inverse_layer_idx`
with `attn_implementation="eager"`) against a fixed-size KV cache held in
`register_buffer` tensors, because transformers' own `Cache` object isn't
`torch.export`-compatible. It exports via `torch.export.export` +
`coreai_torch.TorchConverter`, converts to an `AIProgram`, and saves a `.aimodel` under
`exports/` (git-ignored).

Package: `pip install coreai-torch` (pulls in `coreai-core`); `pip install coreai-opt` for
quantization. Both installed cleanly on this Mac (macOS 27.2, arm64) against the
project's torch 2.15 / transformers 5.23, with a "validated up to torch 2.13" warning that
didn't affect correctness here.

## Finding: dynamic sequence length doesn't convert

The natural design — one entrypoint, `dynamic_shapes` over the sequence dimension, KV
written via `cache.index_copy_(dim, position_ids, ...)` — fails conversion:

```
ValueError: index_put currently only supports dynamic batch dimension (dim 0);
all other dimensions must be static
```

coreai-torch 0.4.4's `index_put` lowering only allows a dynamic *batch* dimension; our
cache write indexes the sequence dimension (position-addressed, not append-only), which
isn't batch. **Workaround used here:** export two static-shape entrypoints sharing the
same state buffers, `prefill` (fixed at `PREFILL_LEN = 512` tokens) and `decode` (fixed at
1 token) — both converted into the same `.aimodel`. This matches `sampler.py`'s own
split between a full-window forward and single-token feeds, just with a fixed rather than
elastic prefill size. The Swift side would pad/truncate prefill to exactly 512 tokens (or
export a small set of bucketed prefill lengths if padding waste matters).

## Numerics (bossa checkpoint, 15 sequences from `processed/sequences/*.npz`, `val` array)

`StatefulGPT2` (PyTorch, not yet the exported asset) vs the HF model's own uncached eager
forward, same inputs:

| | max abs diff | mean abs diff |
|---|---|---|
| prefill (511 tokens at once) | 5.76e-3 | 5.38e-5 |
| decode (1 token, cache primed by prefill) | 5.38e-4 | 8.60e-5 |

Both are float32 rounding noise (matmul order differs slightly from HF's fused path, as
expected from a from-scratch reimplementation) — the KV-cache logic is correct.

## Speed

| | prefill (tok/s) | decode (tok/s / ms per token) |
|---|---|---|
| PyTorch eager, fp32, this Mac (CPU) | 2336 | 41.4 / 24.1 ms |
| `.aimodel` via `coreai.runtime` (pip dev interpreter) | 63.2 | 2.1 / 483.7 ms |

The `.aimodel` number is ~35x slower than plain PyTorch on the same machine — expected
for an unaccelerated graph interpreter, and not informative about the shipped runtime's
actual speed (ANE/GPU-backed). Treat it as "it runs, end to end, including the stateful
cache," not as a latency estimate. 483.7 ms/token would be unusable for live generation;
real hardware acceleration needs to look nothing like this to ship.

## Size and validation loss by precision (weights only; same 15 sequences)

| precision | weight bytes | val loss | Δ vs fp32 |
|---|---|---|---|
| fp32 (current checkpoint) | 512.4 MB | 0.8507 | — |
| fp16 (cast, no retraining) | 256.2 MB | 0.8506 | ~0 |
| int8 (weight-only, fake-quantized*) | 128.1 MB | 0.8510 | +0.0003 |
| int4 (weight-only, fake-quantized*) | 64.1 MB | 1.5973 | +0.75 |

\* "fake-quantized" = per-output-channel symmetric round-trip through int{8,4} on a copy
of the model, no calibration data, no QAT — a cheap proxy for what `coreai-opt`'s
`Quantizer` would do with a default weight-only config, not a real `coreai-opt` run (that
needs calibration data and more wiring than this spike's time budget covered). fp16 and
int8 are free; int4 roughly doubles the loss and would need QAT or per-layer sensitivity
analysis before shipping. The converted `.aimodel` itself is fp32 (513.3 MB) — quantizing
the actual asset via `coreai-opt` is follow-up work, not done here.

## What the Swift side needs

- **Inputs:** `input_ids` (int32, not int64 — the runtime rejected int64 with "invalid
  scalar type: int64, expected: int32"), `position_ids` (int32), both shape `(1, seq_len)`.
- **Outputs:** `logits`, shape `(1, seq_len, 55028)`.
- **State:** two buffers, `k_cache` and `v_cache`, shape
  `(n_layer=12, 1, n_head=12, max_seq_len=1024, head_dim=64)`, fp32. Swift allocates them
  once via `InferenceFunction.MutableViews()` / `stateViews.insert(&cache, for: "k_cache")`
  (per the WWDC26 "Meet Core AI" sample) and reuses them across calls — they're mutated
  in place by both entrypoints; nothing to read back and rewrite.
- **Two entrypoints,** `prefill` (seq_len fixed at 512) and `decode` (seq_len fixed at 1).
  App code would adapt `sampler.py`'s `_Context.rebuild`/`feed_one` pattern: call
  `prefill` once per window rebuild (padding to 512 if the window is shorter), `decode`
  once per sampled token.
- **Minimum OS:** `AIProgram.save_asset`'s default `minimum_os` is `OSVersion.v27`
  (macOS/iOS 27) — matches the roadmap's "macOS/iOS 27+" target, nothing to negotiate down.
- **Python-side gotcha to carry over:** the mask inside `StatefulGPT2.forward` uses
  `torch.finfo(dtype).min`, not `-inf`, specifically so this still works under fp16/int8
  casting without producing NaNs; keep that convention if the attention math is
  reimplemented again in Swift/MLX for comparison.

## Recommended next steps (not done here)

1. Build a minimal macOS 27 app target (even a command-line tool linking `CoreAI.framework`
   directly) to get a real prefill/decode latency number — the one number this Python
   spike could not produce.
2. If fp16 is enough (loss is unchanged here), ship fp16 first; it halves the asset for
   free. Revisit int4 only with QAT if size becomes a real constraint.
3. Either accept the fixed 512-token prefill bucket, add 1–2 more bucket sizes, or retest
   whether a newer `coreai-torch` release supports dynamic non-batch `index_put` (this was
   tested against 0.4.4, the latest on PyPI at the time of this spike).

## Speed gate on the real runtime (PR A)

The spike above could only time Core AI's pip dev interpreter. This run uses the OS runtime from
a macOS 27.2 app build (`LofiBossa --engine-bench exports/base-int8.aimodel exports/base-fixture.json`,
`app/Sources/LofiBossa/Engine/MusicModel.swift`), on the user's Mac, with the base model.

**Export.** `export_coreai.py --export-only --quantize int8` uses coreai-opt's `w8` preset
(weight-only int8, per channel). Hugging Face's GPT-2 keeps its 48 projection layers as its own
`Conv1D` type, which the quantizer skips, so the first int8 asset was 384 MB; converting them to
`nn.Linear` first (identical outputs, max difference 0.0) gives **129.9 MB**.

**Correct.** Against PyTorch fp32 on a 60-token prompt (`training/engine_fixture.py`):

| | argmax | top-5 overlap | max \|Δlogit\| over PyTorch's top 20 |
|---|---|---|---|
| prefill | same (14129) | 5/5 | 0.188 |
| decode (1 token) | same (82) | 5/5 | 0.279 |

**Speed** (several runs; the spread between runs is as large as between units):

| preferred unit | prefill 512 tokens | decode | first load | cached load |
|---|---|---|---|---|
| default | 90–111 ms | 26–31 ms/token | 18.9 s | 0.4–2.9 s |
| GPU | 97 ms | 29 ms/token | 19.9 s | |
| Neural Engine | 93 ms | 26 ms/token | 18.8 s | |
| CPU | 166 ms | 31 ms/token | | 1.8 s |

A 1,500-token song (about 30 s of four tracks) takes **~40–47 s** to write. That's above the
20 ms/token target but workable for the challenge's three minutes, especially if notes play as
they're written. **Go.**

The unit barely matters, so decode is probably dominated by per-call overhead rather than math
(85 MB of int8 weights is ~1 ms of memory traffic): most likely the 2 × 37.7 MB fp32 KV cache
passed as state on every call. To try in the engine PR: an fp16 cache, the `encode`/
`ComputeStream` API so state stays on the device between calls, and a shorter window if needed.
The first load (~19 s, specialization) is cached by the system; the app should load the model in
the background at launch. Not measured yet: an iPad (the Simulator isn't representative).
