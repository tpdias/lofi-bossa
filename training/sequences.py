"""Turn preprocessed MIDI files (up to seven tracks) into training sequences for the model.

Each file is converted to model events and cut into windows of up to 1024 tokens, the way
the Anticipatory Music Transformer was trained. Every file is used several times:

  - once plain (the model continues music: what /generate does)
  - several times with a random subset of its tracks held fixed as "controls" and the rest
    to be written around them (what /regenerate_track does)

Files with a single track get time-span infilling instead of the track split.

Two additions for the optional tracks (keys, lead, vibes), which few files have:
  - rare-track boost: a file that has vibes or lead also gets extra copies where exactly that
    track is written around all the others, so the model sees plenty of "add a vibes part"
  - transposition: with `transpose`, each copy is shifted by a random -5..+6 semitones
    (drums stay put), which multiplies the keys the model sees
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
from anticipation.vocab import ANTICIPATE, AUTOREGRESS, NOTE_OFFSET

from licenses import filter_rows
from tracks import ALL_FAMILY

DRUMS = 128

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


def transposed(events, shift):
    """Events with every non-drum note moved by `shift` semitones (notes that would leave the
    piano range stay where they are)."""
    if not shift:
        return events
    out = list(events)
    for i in range(0, len(out), 3):
        instr, pitch = divmod(out[i + 2] - NOTE_OFFSET, 128)
        if instr != DRUMS and 0 <= pitch + shift < 128:
            out[i + 2] += shift
    return out


def file_rows(job):
    path, copies, seed, targets, transpose = job
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

    # (track written around the rest, or None for the usual random split) per copy
    plan = [None] * copies + [t for t in targets if len(instruments) > 1]
    rows = []
    for copy, target in enumerate(plan):
        source = transposed(all_events, rng.randint(-5, 6) if transpose else 0)
        if copy == 0 and target is None:
            events, controls = list(source), []
        elif target is not None:
            fixed = [i for i in instruments if i not in ALL_FAMILY[target]]
            if not fixed or len(fixed) == len(instruments):
                continue
            events, controls = extract_instruments(source, fixed)
        elif len(instruments) > 1:
            fixed = rng.sample(instruments, rng.randint(1, len(instruments) - 1))
            events, controls = extract_instruments(source, fixed)
        else:
            events, controls = extract_spans(source, 0.05)
        tokens, leftover = ops.anticipate(ops.pad(events, end_time), controls)
        tokens += leftover   # controls after the last event still belong to the song
        rows.extend(windows(tokens, ANTICIPATE if controls else AUTOREGRESS, rng))
    return rows


def build(index_path, processed_dir, style, tiers, copies, core_boost, limit=None, workers=None, seed=0,
          boosts=None, transpose=False, licenses="all"):
    """Return (train, validation) int32 arrays of shape [rows, 1024], padded with PAD.
    Validation is never boosted or transposed, so losses stay comparable between runs.
    `licenses` ("all" or "cc-by") leaves out files whose source that license group excludes."""
    with open(index_path) as f:
        entries = [json.loads(line) for line in f]
    entries = [e for e in filter_rows(entries, licenses) if e["style"] == style and e["tier"] in tiers]
    random.Random(seed).shuffle(entries)
    if limit:
        entries = entries[:limit]

    boosts = boosts or {}      # e.g. {"vibes": 3, "lead": 1}: extra "write this track" copies
    jobs = {"train": [], "val": []}
    for n, e in enumerate(entries):
        val = is_validation(e["id"])
        # validation uses the plain copy plus one track-split copy, never boosted
        n_copies = 2 if val else copies * (core_boost if e["tier"] == "core" else 1)
        targets = [] if val else [t for t, k in boosts.items() if t in e["tracks"] for _ in range(k)]
        jobs["val" if val else "train"].append(
            (Path(processed_dir) / e["file"], n_copies, seed + n, targets, transpose and not val))

    out = {}
    with multiprocessing.Pool(workers or multiprocessing.cpu_count()) as pool:
        for split, split_jobs in jobs.items():
            rows = [r for file in pool.imap_unordered(file_rows, split_jobs, chunksize=8) for r in file]
            out[split] = np.stack(rows) if rows else np.empty((0, WINDOW + 1), dtype=np.int32)
    print(f"{style}: {len(jobs['train'])} train files -> {len(out['train'])} sequences, "
          f"{len(jobs['val'])} validation files -> {len(out['val'])} sequences")
    return out["train"], out["val"]
