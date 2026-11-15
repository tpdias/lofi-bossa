"""Turn preprocessed 4-track MIDI files into training sequences for the model.

Each file is converted to model events and cut into windows of up to 1024 tokens, the way
the Anticipatory Music Transformer was trained. Every file is used several times:

  - once plain (the model continues music: what /generate does)
  - several times with a random subset of its tracks held fixed as "controls" and the rest
    to be written around them (what /regenerate_track does)

Files with a single track get time-span infilling instead of the track split.
"""

import hashlib
import json
import multiprocessing
import random
import warnings
from pathlib import Path

import numpy as np
from anticipation import ops
from anticipation.config import EVENT_SIZE, M, MAX_TIME
from anticipation.convert import midi_to_events
from anticipation.tokenize import extract_instruments, extract_spans
from anticipation.vocab import ANTICIPATE, AUTOREGRESS

PAD = -1
WINDOW = EVENT_SIZE * M      # 1023 tokens, plus the mode token = 1024
MIN_WINDOW = EVENT_SIZE * 32


def is_validation(file_id):
    """Stable 10% split by file, so a song never appears on both sides."""
    return int(hashlib.sha1(file_id.encode()).hexdigest(), 16) % 10 == 0


def windows(tokens, mode, rng):
    """Cut one interleaved token stream into training rows of length WINDOW + 1."""
    start = EVENT_SIZE * rng.randrange(0, M) if len(tokens) > WINDOW else 0
    for i in range(start, len(tokens), WINDOW):
        seq = tokens[i:i + WINDOW]
        if len(seq) < MIN_WINDOW:
            continue
        offset = ops.min_time(seq, seconds=False)
        seq[::EVENT_SIZE] = [t - offset for t in seq[::EVENT_SIZE]]   # times relative to the window
        if ops.max_time(seq, seconds=False) >= MAX_TIME:
            continue
        row = np.full(WINDOW + 1, PAD, dtype=np.int32)
        row[0] = mode
        row[1:len(seq) + 1] = seq
        yield row


def file_rows(job):
    path, copies, seed = job
    rng = random.Random(seed)
    np.random.seed(seed % 2**32)   # the library's span extraction uses numpy's global RNG
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            all_events = midi_to_events(str(path))
    except Exception:
        return []
    if len(all_events) < MIN_WINDOW:
        return []
    instruments = sorted(ops.get_instruments(all_events))
    end_time = ops.max_time(all_events, seconds=False)

    rows = []
    for copy in range(copies):
        if copy == 0:
            events, controls = list(all_events), []
        elif len(instruments) > 1:
            fixed = rng.sample(instruments, rng.randint(1, len(instruments) - 1))
            events, controls = extract_instruments(all_events, fixed)
        else:
            events, controls = extract_spans(all_events, 0.05)
        tokens, leftover = ops.anticipate(ops.pad(events, end_time), controls)
        tokens += leftover   # controls after the last event still belong to the song
        rows.extend(windows(tokens, ANTICIPATE if controls else AUTOREGRESS, rng))
    return rows


def build(index_path, processed_dir, style, tiers, copies, core_boost, limit=None, workers=None, seed=0):
    """Return (train, validation) int32 arrays of shape [rows, 1024], padded with PAD."""
    entries = [json.loads(line) for line in open(index_path)]
    entries = [e for e in entries if e["style"] == style and e["tier"] in tiers]
    random.Random(seed).shuffle(entries)
    if limit:
        entries = entries[:limit]

    jobs = {"train": [], "val": []}
    for n, e in enumerate(entries):
        val = is_validation(e["id"])
        # validation uses the plain copy plus one track-split copy, never boosted
        n_copies = 2 if val else copies * (core_boost if e["tier"] == "core" else 1)
        jobs["val" if val else "train"].append((Path(processed_dir) / e["file"], n_copies, seed + n))

    out = {}
    with multiprocessing.Pool(workers or multiprocessing.cpu_count()) as pool:
        for split, split_jobs in jobs.items():
            rows = [r for file in pool.imap_unordered(file_rows, split_jobs, chunksize=8) for r in file]
            out[split] = np.stack(rows) if rows else np.empty((0, WINDOW + 1), dtype=np.int32)
    print(f"{style}: {len(jobs['train'])} train files -> {len(out['train'])} sequences, "
          f"{len(jobs['val'])} validation files -> {len(out['val'])} sequences")
    return out["train"], out["val"]
