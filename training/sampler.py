"""Sampler for the Anticipatory Music Transformer.

Same algorithm as anticipation.sample.generate, with two changes the app needs:
  - key/value caching, so each new token costs one small forward pass instead of
    re-running the whole context
  - an instrument whitelist, so the model can only write notes for the tracks we ask for

The context is rebuilt (one full forward pass) only when the 1024-token window fills up;
it then keeps the most recent KEEP tokens. The library instead slides one event at a time,
which is what makes caching impossible there.
"""

import collections
import math

import torch
import torch.nn.functional as F
from anticipation import ops
from anticipation.config import DELTA, MAX_DUR, MAX_INSTR, MAX_NOTE, MAX_PITCH, MAX_TIME, TIME_RESOLUTION
from anticipation.vocab import (ANTICIPATE, ATIME_OFFSET, AUTOREGRESS, CONTROL_OFFSET,
                                DUR_OFFSET, NOTE_OFFSET, TIME_OFFSET)

WINDOW = 1017           # event/control tokens the model sees (plus 1 mode token, room for 1 event)
KEEP = 678              # tokens kept when the window is rebuilt
MAX_SPAN = 6000         # ticks; relative times must stay well under MAX_TIME (100 s)
MAX_SAME_TICK = 12      # notes allowed to start on one 10 ms tick before time is forced forward
MAX_AHEAD = 120         # fixed notes shown ahead of the current time; the rest of the window is history


class _Context:
    """The model's cached view of the token sequence."""

    def __init__(self, model, mode_token):
        self.model = model
        self.device = next(model.parameters()).device
        self.mode_token = mode_token
        self.rebuilds = 0

    def rebuild(self, tokens, current_time, keep=WINDOW):
        keep -= keep % 3
        while True:
            window = tokens[-keep:] if keep else []
            # relative times are measured from the oldest token, but never from the future
            self.offset = min(ops.min_time(window, seconds=False), current_time) if window else current_time
            if current_time - self.offset <= MAX_SPAN or keep <= 3:
                break
            keep = (keep // 2) - (keep // 2) % 3
        self.length = len(window)
        self.past = None
        self._run([self.mode_token] + self._relative(window))
        self.rebuilds += 1

    def _relative(self, toks):
        toks = list(toks)
        toks[::3] = [t - self.offset for t in toks[::3]]
        return toks

    def _run(self, toks):
        ids = torch.tensor([toks], device=self.device)
        out = self.model(ids, past_key_values=self.past, use_cache=True)
        self.past = out.past_key_values
        self.logits = out.logits[0, -1].float().cpu()

    def needs_rebuild(self, extra, current_time):
        return self.length + extra > WINDOW or current_time - self.offset > MAX_SPAN

    def feed_triples(self, toks):
        """Append whole (time, dur, note) triples with absolute times."""
        self._run(self._relative(toks))
        self.length += len(toks)

    def feed_one(self, token):
        """Append one already-relative token of the event being sampled."""
        self._run([token])
        self.length += 1


def _sample(logits, top_p, rng):
    if top_p < 1.0:
        sorted_logits, order = torch.sort(logits, descending=True)
        cumulative = torch.cumsum(F.softmax(sorted_logits, dim=-1), dim=-1)
        remove = cumulative > top_p
        remove[1:] = remove[:-1].clone()
        remove[0] = False
        logits = logits.masked_fill(remove.scatter(0, order, remove), -math.inf)
    return int(torch.multinomial(F.softmax(logits, dim=-1), 1, generator=rng))


@torch.no_grad()
def generate(model, start_time, end_time, inputs=None, controls=None, instruments=None,
             top_p=0.98, seed=None, progress=None, rest_penalty=0.0, max_notes_per_second=24):
    """Generate events between start_time and end_time (seconds).

    inputs       events to continue from (those after start_time are kept fixed)
    controls     fixed events (already shifted by CONTROL_OFFSET) to write around
    instruments  model instrument ids the new notes may use (None = any)
    progress     optional callback(fraction between 0 and 1)
    max_notes_per_second  new notes allowed in any one-second span; time is pushed forward
                 beyond that (the pretrained model can otherwise produce absurdly dense parts)
    rest_penalty amount subtracted from the "rest" logit; math.inf forbids rests, so every
                 event is a note. Used when the model would otherwise leave a track silent.
    Returns the new events merged with `inputs`; controls are not included.
    """
    inputs = inputs or []
    controls = controls or []
    delta = DELTA * TIME_RESOLUTION
    start = int(TIME_RESOLUTION * start_time)
    end = int(TIME_RESOLUTION * end_time)
    rng = torch.Generator().manual_seed(seed) if seed is not None else None

    # notes the model may choose: whitelisted instruments, plus the rest token at the end
    allowed = torch.zeros(MAX_NOTE + 1, dtype=torch.bool)
    for instr in range(MAX_INSTR) if instruments is None else instruments:
        allowed[instr * MAX_PITCH:(instr + 1) * MAX_PITCH] = True
    allowed[MAX_NOTE] = True
    note_bias = torch.zeros(MAX_NOTE + 1)
    note_bias[MAX_NOTE] = -rest_penalty

    prompt = ops.pad(ops.clip(inputs, 0, start, clip_duration=False, seconds=False), start)
    future = ops.clip(inputs, start + 1, ops.max_time(inputs, seconds=False),
                      clip_duration=False, seconds=False) if inputs else []
    pending = ops.sort(list(controls) + [CONTROL_OFFSET + tok for tok in future])
    mode = ANTICIPATE if pending else AUTOREGRESS
    tokens, pending = ops.anticipate(prompt, pending)
    current = ops.max_time(prompt, seconds=False) if prompt else 0

    ctx = _Context(model, mode)
    ctx.rebuild(tokens, current)
    same_tick = 0
    recent = collections.deque(maxlen=max_notes_per_second)   # start times of the latest new notes
    ahead = collections.deque()                               # times of revealed fixed notes still to come
    next_fixed = 0                                            # index into `pending`

    while True:
        # Reveal fixed notes up to `delta` ahead of the current time. When they are very dense,
        # show only the nearest MAX_AHEAD so the window keeps room for what was already played.
        while ahead and ahead[0] <= current:
            ahead.popleft()
        due = []
        while next_fixed < len(pending):
            fixed_time = pending[next_fixed] - ATIME_OFFSET
            if fixed_time > current and (fixed_time > current + delta or len(ahead) >= MAX_AHEAD):
                break
            due += pending[next_fixed:next_fixed + 3]
            next_fixed += 3
            if fixed_time > current:
                ahead.append(fixed_time)
        tokens.extend(due)
        if ctx.needs_rebuild(len(due) + 3, current):
            ctx.rebuild(tokens, current, KEEP)
        elif due:
            ctx.feed_triples(due)

        # time: never in the past; forced forward if too many notes pile up on one tick
        earliest = max(start, current) + (1 if same_tick >= MAX_SAME_TICK else 0)
        if len(recent) == recent.maxlen:
            earliest = max(earliest, recent[0] + TIME_RESOLUTION)
        if earliest >= end:
            break
        logits = ctx.logits[TIME_OFFSET:TIME_OFFSET + MAX_TIME].clone()
        logits[:earliest - ctx.offset] = -math.inf
        rel_time = _sample(logits, top_p, rng)
        new_time = rel_time + ctx.offset
        if new_time >= end:
            break
        ctx.feed_one(TIME_OFFSET + rel_time)

        logits = ctx.logits[DUR_OFFSET:DUR_OFFSET + MAX_DUR].clone()
        if rest_penalty > 0:
            logits[0] = -math.inf   # zero duration only makes sense for a rest
        dur = _sample(logits, top_p, rng)
        ctx.feed_one(DUR_OFFSET + dur)

        logits = (ctx.logits[NOTE_OFFSET:NOTE_OFFSET + MAX_NOTE + 1] + note_bias).masked_fill(~allowed, -math.inf)
        note = _sample(logits, top_p, rng)
        ctx.feed_one(NOTE_OFFSET + note)

        tokens.extend([TIME_OFFSET + new_time, DUR_OFFSET + dur, NOTE_OFFSET + note])
        same_tick = same_tick + 1 if new_time == current else 0
        if note != MAX_NOTE:
            recent.append(new_time)
        current = new_time
        if progress:
            progress((current - start) / max(end - start, 1))

    events, _ = ops.split(tokens)
    return ops.sort(ops.unpad(events) + future)


def accompany(model, fixed_events, seconds, instruments, top_p=0.98, seed=None, progress=None,
              min_notes_per_second=0.5):
    """Write new notes for `instruments` around fixed events. Returns only the new events.

    The model sometimes answers with silence (rests only). If the result is sparser than
    min_notes_per_second, it is retried with rests discouraged, then forbidden.
    """
    controls = [tok + CONTROL_OFFSET for tok in fixed_events]
    for rest_penalty in (0.0, 4.0, math.inf):
        new = generate(model, 0, seconds, controls=controls, instruments=instruments,
                       top_p=top_p, seed=seed, progress=progress, rest_penalty=rest_penalty,
                       max_notes_per_second=12)
        if len(new) // 3 >= min_notes_per_second * seconds:
            break
    return new
