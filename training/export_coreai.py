"""Core AI export spike: can the Anticipatory Music Transformer run on-device?

transformers' GPT-2 forward pass takes a `Cache` object for key/value caching, which
isn't torch.export-compatible. This reimplements the same eager-attention math (the
same path `model.load_model` forces, see model.py) against plain tensors, with the
KV cache authored as buffers per coreai-torch's stateful-model convention: one fixed-
size buffer per cache tensor, named via `state_names` at conversion time so the Swift
runtime can bind them.

The cache is sized to the full 1024-token context and masked by position, rather than
grown dynamically, because coreai-torch state buffers are fixed-shape; the app's own
window (sampler.py's WINDOW/KEEP) already caps the context well under that.

Usage:
    python training/export_coreai.py [--source checkpoints/bossa] [--n-sequences 100]
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, str(Path(__file__).parent))
from model import load_model

MAX_SEQ_LEN = 1024
PREFILL_LEN = 512  # static shape coreai-torch 0.4.4 requires for the prefill entrypoint


class StatefulGPT2(nn.Module):
    """Exportable GPT-2 decoder with a fixed-size, buffer-backed KV cache.

    `forward(input_ids, position_ids)` both prefills (any number of positions at
    once) and decodes (one position at a time); the cache buffers persist between
    calls exactly like sampler.py's `_Context`, except as Core AI state instead of
    an in-process Python object.
    """

    def __init__(self, hf_model, max_seq_len=MAX_SEQ_LEN):
        super().__init__()
        cfg = hf_model.config
        self.n_embd = cfg.n_embd
        self.n_head = cfg.n_head
        self.head_dim = cfg.n_embd // cfg.n_head
        self.max_seq_len = max_seq_len

        self.wte = hf_model.transformer.wte
        self.wpe = hf_model.transformer.wpe
        self.ln_f = hf_model.transformer.ln_f
        self.lm_head = hf_model.lm_head
        self.blocks = nn.ModuleList(hf_model.transformer.h)
        # Constant per layer (1/sqrt(head_dim), further divided by layer_idx+1 for
        # this checkpoint's scale_attn_by_inverse_layer_idx) — read once, baked in.
        self.scalings = [float(b.attn.scaling) for b in self.blocks]

        shape = (len(self.blocks), 1, self.n_head, max_seq_len, self.head_dim)
        self.register_buffer("k_cache", torch.zeros(shape))
        self.register_buffer("v_cache", torch.zeros(shape))

    def forward(self, input_ids, position_ids):
        hidden = self.wte(input_ids) + self.wpe(position_ids)

        key_pos = torch.arange(self.max_seq_len, device=input_ids.device)
        query_pos = position_ids[0]
        allowed = key_pos[None, :] <= query_pos[:, None]
        neg_inf = torch.finfo(hidden.dtype).min
        mask = torch.where(allowed, torch.zeros((), dtype=hidden.dtype),
                            torch.full((), neg_inf, dtype=hidden.dtype))[None, None]

        new_k, new_v = [], []
        for i, block in enumerate(self.blocks):
            residual = hidden
            x = block.ln_1(hidden)
            q, k, v = block.attn.c_attn(x).split(self.n_embd, dim=-1)
            shape = (*q.shape[:-1], self.n_head, self.head_dim)
            q = q.view(shape).transpose(1, 2)
            k = k.view(shape).transpose(1, 2)
            v = v.view(shape).transpose(1, 2)
            new_k.append(k)
            new_v.append(v)

            full_k = self.k_cache[i].index_copy(2, position_ids[0], k)
            full_v = self.v_cache[i].index_copy(2, position_ids[0], v)

            attn_weights = torch.matmul(q, full_k.transpose(-1, -2)) * self.scalings[i]
            attn_weights = torch.softmax(attn_weights + mask, dim=-1)
            attn_out = torch.matmul(attn_weights, full_v)
            attn_out = attn_out.transpose(1, 2).reshape(attn_out.shape[0], -1, self.n_embd)
            hidden = residual + block.attn.c_proj(attn_out)

            residual = hidden
            x = block.ln_2(hidden)
            x = block.mlp.c_proj(block.mlp.act(block.mlp.c_fc(x)))
            hidden = residual + x

        hidden = self.ln_f(hidden)
        logits = self.lm_head(hidden)

        all_new_k = torch.stack(new_k, dim=0)
        all_new_v = torch.stack(new_v, dim=0)
        self.k_cache.index_copy_(3, position_ids[0], all_new_k)
        self.v_cache.index_copy_(3, position_ids[0], all_new_v)
        return logits

    def reset_cache(self):
        self.k_cache.zero_()
        self.v_cache.zero_()


def reference_logits(hf_model, ids):
    """HF model's own (uncached) eager forward — ground truth for the numerics check."""
    with torch.no_grad():
        return hf_model(ids, use_cache=False).logits


def load_val_sequences(n, max_len=MAX_SEQ_LEN):
    paths = sorted(Path("processed/sequences").glob("*.npz"))
    if not paths:
        raise FileNotFoundError("no processed/sequences/*.npz found")
    out = []
    for path in paths:
        val = np.load(path)["val"]
        for row in val:
            row = row[row != -1]
            if len(row) < 4:
                continue
            out.append(torch.from_numpy(row[:max_len].astype(np.int64)).unsqueeze(0))
            if len(out) >= n:
                return out
    return out


@torch.no_grad()
def check_numerics(hf_model, stateful, sequences):
    """Compares the stateful wrapper (prefill, and prefill+1-token decode) against
    the HF model's own uncached forward, over `sequences`."""
    hf_model.eval()
    stateful.eval()
    prefill_diffs, decode_diffs = [], []
    for ids in sequences:
        seq_len = ids.shape[1]
        ref = reference_logits(hf_model, ids)

        stateful.reset_cache()
        prefill_len = seq_len - 1
        pos = torch.arange(prefill_len).unsqueeze(0)
        out = stateful(ids[:, :prefill_len], pos)
        diff = (out - ref[:, :prefill_len]).abs()
        prefill_diffs.append((diff.max().item(), diff.mean().item()))

        last_pos = torch.tensor([[prefill_len]])
        out = stateful(ids[:, prefill_len:prefill_len + 1], last_pos)
        diff = (out - ref[:, prefill_len:prefill_len + 1]).abs()
        decode_diffs.append((diff.max().item(), diff.mean().item()))

    def summarize(diffs):
        maxes, means = zip(*diffs)
        return max(maxes), sum(means) / len(means)

    return {"prefill": summarize(prefill_diffs), "decode": summarize(decode_diffs)}


@torch.no_grad()
def benchmark(stateful, prefill_len=512, decode_steps=32, repeats=3):
    ids = torch.randint(0, 55000, (1, prefill_len))
    pos = torch.arange(prefill_len).unsqueeze(0)

    stateful.reset_cache()
    stateful(ids, pos)  # warm up (first call pays for lazy init / allocation)

    prefill_times = []
    for _ in range(repeats):
        stateful.reset_cache()
        t0 = time.perf_counter()
        stateful(ids, pos)
        prefill_times.append(time.perf_counter() - t0)

    decode_times = []
    for step in range(decode_steps):
        tok = torch.randint(0, 55000, (1, 1))
        t0 = time.perf_counter()
        stateful(tok, torch.tensor([[prefill_len + step]]))
        decode_times.append(time.perf_counter() - t0)

    return {
        "prefill_tokens_per_sec": prefill_len / (sum(prefill_times) / len(prefill_times)),
        "prefill_seconds": sum(prefill_times) / len(prefill_times),
        "decode_tokens_per_sec": 1.0 / (sum(decode_times) / len(decode_times)),
        "decode_seconds_per_token": sum(decode_times) / len(decode_times),
    }


def export_aimodel(stateful, out_path):
    """Converts to .aimodel with two static-shape entrypoints, "prefill" (PREFILL_LEN
    tokens at once) and "decode" (1 token), sharing the same k_cache/v_cache state.

    coreai-torch 0.4.4's index_put lowering only supports a dynamic *batch* dimension;
    the KV-cache write here indexes a non-batch (sequence) dimension by `position_ids`,
    so a single entrypoint with a dynamic sequence length fails conversion (see
    COREAI_SPIKE.md). Two fixed-length entrypoints is the workaround: the app would
    pad/chunk prefill to PREFILL_LEN and decode one token at a time, same as today's
    sampler.py window, just with a fixed rather than elastic prefill size.
    """
    import coreai_torch
    from pathlib import Path

    converter = coreai_torch.TorchConverter()
    stateful.eval()

    stateful.reset_cache()
    ids = torch.randint(0, 55000, (1, PREFILL_LEN))
    pos = torch.arange(PREFILL_LEN).unsqueeze(0)
    exported = torch.export.export(stateful, args=(ids, pos))
    exported = exported.run_decompositions(coreai_torch.get_decomp_table())
    converter.add_exported_program(
        exported, input_names=["input_ids", "position_ids"],
        state_names=["k_cache", "v_cache"], output_names=["logits"],
        entrypoint_name="prefill",
    )

    stateful.reset_cache()
    ids1 = torch.randint(0, 55000, (1, 1))
    pos1 = torch.tensor([[0]])
    exported1 = torch.export.export(stateful, args=(ids1, pos1))
    exported1 = exported1.run_decompositions(coreai_torch.get_decomp_table())
    converter.add_exported_program(
        exported1, input_names=["input_ids", "position_ids"],
        state_names=["k_cache", "v_cache"], output_names=["logits"],
        entrypoint_name="decode",
    )

    ai_program = converter.to_coreai()
    asset = ai_program.save_asset(Path(out_path))
    return asset


def dir_size(path):
    path = Path(path)
    if path.is_file():
        return path.stat().st_size
    return sum(f.stat().st_size for f in path.glob("**/*") if f.is_file())


async def run_aimodel_benchmark(aimodel_path, n_layer, n_head, head_dim, decode_steps=32, repeats=3):
    """Loads the converted asset and times both entrypoints through coreai.runtime —
    note this is the pip-installed "local Core AI Framework" dev interpreter (it says so
    on import), not the OS-level, hardware-accelerated runtime a real macOS 27 app would
    get; see COREAI_SPIKE.md for what that means for these numbers."""
    from coreai.runtime import AIModel, NDArray

    model = await AIModel.load(str(aimodel_path))
    prefill_fn = model.load_function("prefill")
    decode_fn = model.load_function("decode")

    cache_shape = (n_layer, 1, n_head, MAX_SEQ_LEN, head_dim)
    state = {
        "k_cache": NDArray(data=np.zeros(cache_shape, dtype=np.float32)),
        "v_cache": NDArray(data=np.zeros(cache_shape, dtype=np.float32)),
    }
    ids = np.random.randint(0, 55000, (1, PREFILL_LEN)).astype(np.int32)
    pos = np.arange(PREFILL_LEN, dtype=np.int32).reshape(1, -1)

    prefill_times = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        await prefill_fn({"input_ids": NDArray(data=ids), "position_ids": NDArray(data=pos)}, state=state)
        prefill_times.append(time.perf_counter() - t0)

    decode_times = []
    for step in range(decode_steps):
        tok = np.random.randint(0, 55000, (1, 1)).astype(np.int32)
        p = np.array([[PREFILL_LEN + step]], dtype=np.int32)
        t0 = time.perf_counter()
        await decode_fn({"input_ids": NDArray(data=tok), "position_ids": NDArray(data=p)}, state=state)
        decode_times.append(time.perf_counter() - t0)

    return {
        "prefill_tokens_per_sec": PREFILL_LEN / (sum(prefill_times) / len(prefill_times)),
        "prefill_seconds": sum(prefill_times) / len(prefill_times),
        "decode_tokens_per_sec": 1.0 / (sum(decode_times) / len(decode_times)),
        "decode_seconds_per_token": sum(decode_times) / len(decode_times),
    }


def weight_bytes(model, dtype_bits):
    """Rough on-disk weight size at `dtype_bits`, ignoring tied embeddings twice."""
    seen = set()
    total_params = 0
    for p in model.parameters():
        key = p.data_ptr()
        if key in seen:
            continue
        seen.add(key)
        total_params += p.numel()
    return total_params * dtype_bits / 8


def fake_quantize_weight_only(model, bits):
    """Simulates weight-only quantization (per-output-channel symmetric, round-trip
    through int{bits}) by overwriting each Linear/Conv1D weight in a copy of the model
    with its dequantized approximation — the accuracy hit a real coreai-opt Quantizer
    weight-only config would produce, without needing calibration data to wire one up."""
    import copy

    model = copy.deepcopy(model)
    qmax = 2 ** (bits - 1) - 1
    with torch.no_grad():
        for module in model.modules():
            if not hasattr(module, "weight") or module.weight is None:
                continue
            w = module.weight.data
            if w.dim() != 2:
                continue
            scale = w.abs().amax(dim=0, keepdim=True).clamp_min(1e-8) / qmax
            q = torch.clamp(torch.round(w / scale), -qmax - 1, qmax)
            module.weight.data = q * scale
    return model


@torch.no_grad()
def validation_loss(model, sequences):
    """Mean next-token cross-entropy over `sequences`, same convention as finetune.py's
    `evaluate()` (no padding here since each sequence is already trimmed to its real length)."""
    import torch.nn.functional as F

    model.eval()
    total, count = 0.0, 0
    for ids in sequences:
        logits = model(ids, use_cache=False).logits.float()
        ce = F.cross_entropy(logits[0, :-1], ids[0, 1:], reduction="sum")
        total += ce.item()
        count += ids.shape[1] - 1
    return total / count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=None, help="checkpoint dir, or None for the base model")
    parser.add_argument("--n-sequences", type=int, default=100)
    parser.add_argument("--out-dir", default="exports")
    parser.add_argument("--skip-export", action="store_true", help="skip the slow .aimodel conversion")
    parser.add_argument("--runtime-benchmark", action="store_true",
                         help="also load the converted asset with coreai.runtime and time it "
                              "(first-run specialization/compile can take minutes)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(exist_ok=True)
    name = Path(args.source).name if args.source else "base"

    print(f"Loading {args.source or 'base model'}...", flush=True)
    hf_model = load_model(args.source) if args.source else load_model()
    hf_model.eval()
    stateful = StatefulGPT2(hf_model)
    stateful.eval()

    print(f"Loading {args.n_sequences} validation sequences...", flush=True)
    sequences = load_val_sequences(args.n_sequences)
    print(f"  got {len(sequences)}", flush=True)

    print("Checking numerics (stateful wrapper vs HF eager forward)...", flush=True)
    numerics = check_numerics(hf_model, stateful, sequences)
    print(f"  prefill: max={numerics['prefill'][0]:.3e} mean={numerics['prefill'][1]:.3e}", flush=True)
    print(f"  decode:  max={numerics['decode'][0]:.3e} mean={numerics['decode'][1]:.3e}", flush=True)

    print("Benchmarking PyTorch (fp32, this Mac, eager) prefill + decode...", flush=True)
    bench = benchmark(stateful)
    print(f"  prefill: {bench['prefill_tokens_per_sec']:.1f} tok/s", flush=True)
    print(f"  decode:  {bench['decode_tokens_per_sec']:.1f} tok/s "
          f"({bench['decode_seconds_per_token'] * 1000:.1f} ms/token)")

    print("Validation loss at fp32, and estimated at fp16/int8/int4 weights...", flush=True)
    precision_results = {}
    fp32_loss = validation_loss(hf_model, sequences)
    precision_results["fp32"] = {"val_loss": fp32_loss, "weight_bytes": weight_bytes(hf_model, 32)}
    print(f"  fp32: loss={fp32_loss:.4f} size={precision_results['fp32']['weight_bytes'] / 1e6:.1f} MB", flush=True)

    fp16_model = hf_model.half()
    fp16_loss = validation_loss(fp16_model, [ids for ids in sequences])
    hf_model.float()  # restore for later use
    precision_results["fp16"] = {"val_loss": fp16_loss, "weight_bytes": weight_bytes(hf_model, 16)}
    print(f"  fp16: loss={fp16_loss:.4f} size={precision_results['fp16']['weight_bytes'] / 1e6:.1f} MB", flush=True)

    for bits, label in [(8, "int8"), (4, "int4")]:
        qmodel = fake_quantize_weight_only(hf_model, bits)
        qloss = validation_loss(qmodel, sequences)
        precision_results[label] = {"val_loss": qloss, "weight_bytes": weight_bytes(hf_model, bits)}
        print(f"  {label} (weight-only, fake-quantized, no calibration): loss={qloss:.4f} "
              f"size={precision_results[label]['weight_bytes'] / 1e6:.1f} MB")

    asset_path = out_dir / f"{name}.aimodel"
    aimodel_bench = None
    if not args.skip_export:
        print(f"Exporting to {asset_path} via coreai-torch (fp32, static prefill={PREFILL_LEN}/decode=1)...", flush=True)
        export_aimodel(stateful, asset_path)
        file_size = dir_size(asset_path)
        print(f"  wrote {asset_path} ({file_size / 1e6:.1f} MB)", flush=True)

        if args.runtime_benchmark:
            print("Benchmarking the converted .aimodel via coreai.runtime...", flush=True)
            try:
                import asyncio
                aimodel_bench = asyncio.run(run_aimodel_benchmark(
                    asset_path, stateful.blocks.__len__(), stateful.n_head, stateful.head_dim))
                print(f"  prefill: {aimodel_bench['prefill_tokens_per_sec']:.1f} tok/s", flush=True)
                print(f"  decode:  {aimodel_bench['decode_tokens_per_sec']:.1f} tok/s "
                      f"({aimodel_bench['decode_seconds_per_token'] * 1000:.1f} ms/token)", flush=True)
            except Exception as exc:
                print(f"  runtime benchmark failed: {exc!r}", flush=True)
    else:
        file_size = None

    import json
    report = {
        "checkpoint": args.source or "base",
        "n_sequences": len(sequences),
        "numerics": numerics,
        "pytorch_benchmark": bench,
        "aimodel_benchmark": aimodel_bench,
        "precision": precision_results,
        "aimodel_path": str(asset_path) if not args.skip_export else None,
        "aimodel_bytes": file_size,
    }
    report_path = out_dir / f"{name}_report.json"
    report_path.write_text(json.dumps(report, indent=2))
    print(f"Wrote {report_path}", flush=True)


if __name__ == "__main__":
    main()
