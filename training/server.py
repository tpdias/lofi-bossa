"""Local inference server the macOS app talks to.

    .venv/bin/python training/server.py            # http://127.0.0.1:8765

    GET  /health
    POST /generate           JSON {style, seconds, model?, seed?, top_p?, format?, tracks?, busyness?}
    POST /regenerate_track   ?track=bass&style=lofi&model=&seed=&top_p=&busyness=, body = a song
                             [&start=&end=] (seconds) rewrites only that stretch
    POST /extend             JSON {song, seconds, style, ...}: continues the song for `seconds` more

/generate can also keep part of the current song: send it as "song" and name the tracks to keep
in "locked"; those come back exactly as sent and the rest are written around them.

busyness (0 sparse ... 0.5 default ... 1 untouched) thins out the model's notes per track (see
tidy.py). /generate takes one value or {track: value}. Only newly generated notes are cleaned;
everything sent in a song body comes back as it was.

note_length (0 short ... 0.5 default ... 1 long) nudges new notes to be longer and keeps drum
hits short, same shape as busyness. key ("auto", "C major", "A minor", ...) keeps new, non-drum
notes in that key; "auto" detects it from the song (or picks nothing for a brand new one).
strict_key forbids out-of-key notes outright instead of just discouraging them. The response
reports the key actually used as "key".

tempo ("auto", "none" or a BPM, 60-140) gives the model a sixteenth-note grid to lean toward and
groove (0 loose ... 1 tight) pulls the new notes' onsets onto it; "auto" estimates the tempo
from the song. dynamics (0 flat ... 0.5 default ... 1 expressive) writes velocities: beat
accents, phrase arcs, drum roles. The response reports "tempo" (BPM or null) and "beat_offset".

"model" is auto (default), pretrained or finetuned. /health lists which styles have a
fine-tuned checkpoint.

A song is 4 tracks (piano, guitar, bass, drums) in one of two formats:
  midi  a standard MIDI file; the seed used comes back in the X-Seed header
  json  {"seed", "seconds", "tracks": {"piano": [{"start", "duration", "pitch", "velocity"}], ...}}
        (times in seconds) - what the macOS app uses
/generate picks the format with its "format" field; /regenerate_track answers in the format
it was sent (Content-Type: application/json means json). A style uses checkpoints/<style>/ if that folder exists, otherwise the pretrained
base model, so the API works before any fine-tuning has been done.
"""

import io
import json
import math
import random
import tempfile
import threading
from pathlib import Path

import pretty_midi
import torch
import uvicorn
from anticipation import ops
from anticipation.config import TIME_RESOLUTION
from anticipation.convert import midi_to_events
from anticipation.vocab import CONTROL_OFFSET, TIME_OFFSET
from fastapi import FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

import sampler
import tidy
import tracks
from model import BASE_MODEL, load_model

CHECKPOINTS = Path(__file__).resolve().parent.parent / "checkpoints"
STYLES = ("lofi", "bossa")
MAX_SECONDS = 180

app = FastAPI(title="Lo-Fi / Bossa generator")
device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
_models = {}
_lock = threading.Lock()  # one generation at a time


MODEL_CHOICES = ("auto", "pretrained", "finetuned")


def has_finetuned(style):
    return (CHECKPOINTS / style / "config.json").is_file()


def trained_tracks(style):
    """Tracks the style's checkpoint was trained on (finetune.py writes tracks.json). A checkpoint
    without that file predates the extra tracks, so it knows the four core ones only."""
    try:
        return tuple(json.loads((CHECKPOINTS / style / "tracks.json").read_text()))
    except (OSError, ValueError):
        return tracks.TRACKS


def model_source(style, choice="auto", wanted=()):
    """auto = the style's fine-tuned checkpoint when there is one, otherwise the pretrained model.
    A checkpoint that wasn't trained on a track being written is skipped for the pretrained model,
    which at least has seen that instrument; choosing "finetuned" explicitly always uses it."""
    if choice == "pretrained" or (choice == "auto" and not has_finetuned(style)):
        return BASE_MODEL
    if choice == "auto" and not set(wanted) <= set(trained_tracks(style)):
        return BASE_MODEL
    return str(CHECKPOINTS / style)


def get_model(style, choice="auto", wanted=()):
    if style not in STYLES:
        raise HTTPException(422, f"style must be one of {STYLES}")
    if choice not in MODEL_CHOICES:
        raise HTTPException(422, f"model must be one of {MODEL_CHOICES}")
    if choice == "finetuned" and not has_finetuned(style):
        raise HTTPException(422, f"there is no fine-tuned model for {style} (checkpoints/{style}/ is missing)")
    source = model_source(style, choice, wanted)
    if source not in _models:
        _models[source] = load_model(source).to(device).eval()
    return _models[source]


def midi_response(pm, seed):
    buf = io.BytesIO()
    pm.write(buf)
    return Response(buf.getvalue(), media_type="audio/midi", headers={"X-Seed": str(seed)})


def song_json(pm, seed):
    notes = {t: [] for t in tracks.ALL_TRACKS}
    for inst in pm.instruments:
        track = tracks.all_track_of(inst.program, inst.is_drum)
        if track:
            notes[track] += [{"start": round(n.start, 3), "duration": round(n.end - n.start, 3),
                              "pitch": n.pitch, "velocity": n.velocity} for n in inst.notes]
    for track_notes in notes.values():
        track_notes.sort(key=lambda n: (n["start"], n["pitch"]))
    return {"seed": seed, "seconds": round(pm.get_end_time(), 3), "tracks": notes}


def json_to_midi(song):
    pm = pretty_midi.PrettyMIDI()
    for t in tracks.ALL_TRACKS:
        inst = pretty_midi.Instrument(program=tracks.OUT_PROGRAM[t], is_drum=(t == "drums"), name=t)
        for n in song.get("tracks", {}).get(t, []):
            inst.notes.append(pretty_midi.Note(int(n["velocity"]), int(n["pitch"]), float(n["start"]),
                                               float(n["start"]) + max(float(n["duration"]), 0.01)))
        pm.instruments.append(inst)
    return pm


def events_of_song(song):
    """Model events for a song JSON (through a MIDI file, which is what the library reads)."""
    with tempfile.NamedTemporaryFile(suffix=".mid") as f:
        json_to_midi(song).write(f.name)
        return midi_to_events(f.name)


def notes_of(song, names):
    return [n for t in names for n in song.get("tracks", {}).get(t, [])]


def respond(pm, seed, fmt):
    return song_json(pm, seed) if fmt == "json" else midi_response(pm, seed)


DRUM_GAP_TICKS = {p: round(tracks.DRUM_MIN_GAP[c] * TIME_RESOLUTION)
                 for p, c in tracks.DRUM_CATEGORY.items()}
# every other GM drum pitch (not in a named category) falls back to "perc"
DRUM_GAP_TICKS_DEFAULT = round(tracks.DRUM_MIN_GAP["perc"] * TIME_RESOLUTION)


def resolve_key(name, notes_for_auto):
    """("A minor", pitch classes) from a key name, "auto" (detected from `notes_for_auto`;
    None if there aren't any yet), or "" / "none" (no key constraint)."""
    if not name or name.lower() == "none":
        return None, None
    if name.lower() == "auto":
        if not notes_for_auto:
            return None, "auto"
        detected = tracks.detect_key(notes_for_auto)
        return tracks.KEYS[detected], detected
    if name not in tracks.KEYS:
        raise HTTPException(422, f"key must be \"auto\", \"none\" or one of {sorted(tracks.KEYS)}")
    return tracks.KEYS[name], name


def drum_gap_ticks(instruments):
    """{GM pitch: min ticks between hits}, only when drums (128) may be written."""
    if 128 not in (instruments or ()):
        return None
    return {p: DRUM_GAP_TICKS.get(p, DRUM_GAP_TICKS_DEFAULT) for p in range(27, 88)}


def resolve_tempo(value, notes):
    """(bpm, beat offset seconds) or None. "auto" estimates it from `notes` (None with too few);
    a BPM keeps that tempo, phased to `notes` when there are any; "none" or "" turns it off."""
    value = str(value or "").strip().lower()
    if value in ("", "none"):
        return None
    if value == "auto":
        return tracks.estimate_tempo(notes) if notes else None
    try:
        bpm = float(value)
    except ValueError:
        raise HTTPException(422, 'tempo must be "auto", "none" or a BPM')
    lo, hi = tracks.TEMPO_RANGE
    if not lo <= bpm <= hi:
        raise HTTPException(422, f"tempo must be between {lo} and {hi} BPM")
    return bpm, tracks.beat_phase(notes, bpm)


def grid_args(tempo, groove):
    """Sampler arguments for a tempo's sixteenth-note grid (nothing without a tempo)."""
    if tempo is None or groove <= 0:
        return {}
    step = TIME_RESOLUTION * tidy.grid_step(tempo)
    return {"grid": (step, tempo[1] * TIME_RESOLUTION), "grid_bonus": tidy.knob(groove, 0.0, 1.5, 3.0)}


def tempo_fields(tempo):
    return {"tempo": tempo[0] if tempo else None, "beat_offset": tempo[1] if tempo else None}


class GenerateRequest(BaseModel):
    style: str = "lofi"
    model: str = "auto"
    seconds: float = Field(30, ge=5, le=MAX_SECONDS)
    seed: int | None = None
    top_p: float = Field(0.98, gt=0, le=1)
    format: str = Field("midi", pattern="^(midi|json)$")
    # which tracks to write; the four core ones unless the project added others
    tracks: list[str] = Field(default_factory=lambda: list(tracks.TRACKS))
    busyness: float | dict[str, float] = 0.5
    note_length: float | dict[str, float] = 0.5
    key: str = "auto"
    strict_key: bool = False
    tempo: str | float = "auto"
    groove: float = Field(0.5, ge=0, le=1)
    dynamics: float = Field(0.5, ge=0, le=1)
    # Keep part of the current song: its JSON (as /generate returns it) and the tracks to keep.
    song: dict | None = None
    locked: list[str] = Field(default_factory=list)


class ExtendRequest(BaseModel):
    song: dict
    seconds: float = Field(30, ge=5, le=MAX_SECONDS)   # how much to add
    style: str = "lofi"
    model: str = "auto"
    seed: int | None = None
    top_p: float = Field(0.98, gt=0, le=1)
    tracks: list[str] = Field(default_factory=lambda: list(tracks.TRACKS))
    busyness: float | dict[str, float] = 0.5
    note_length: float | dict[str, float] = 0.5
    key: str = "auto"
    strict_key: bool = False
    tempo: str | float = "auto"
    groove: float = Field(0.5, ge=0, le=1)
    dynamics: float = Field(0.5, ge=0, le=1)


@app.get("/health")
def health():
    return {"device": device, "tracks": tracks.ALL_TRACKS,
            "styles": {s: model_source(s) for s in STYLES},
            "finetuned": [s for s in STYLES if has_finetuned(s)],
            "finetuned_tracks": {s: list(trained_tracks(s)) for s in STYLES if has_finetuned(s)}}


@app.post("/generate")
def generate(req: GenerateRequest):
    wanted = [t for t in tracks.ALL_TRACKS if t in req.tracks]
    unknown = [t for t in req.tracks if t not in tracks.ALL_TRACKS]
    if unknown or not wanted:
        raise HTTPException(422, f"tracks must be from {tracks.ALL_TRACKS}")
    locked = [t for t in wanted if t in req.locked] if req.song else []
    free = [t for t in wanted if t not in locked]
    if not free:
        raise HTTPException(422, "every track is locked: unlock one to write something new")
    model = get_model(req.style, req.model, free)
    seed = req.seed if req.seed is not None else random.randrange(2**31)
    instruments = tracks.instruments_for(free)
    # Locked tracks are fixed notes the new ones are written around ("controls"), and the key
    # (when Auto) comes from them. A brand new song has nothing to detect a key from yet; a
    # named key still applies from the first note.
    locked_notes = notes_of(req.song, locked) if locked else []
    fixed_events = events_of_song({"tracks": {t: req.song["tracks"].get(t, []) for t in locked}}) \
        if locked_notes else []
    key_pcs, _ = resolve_key(req.key, locked_notes)
    tempo = resolve_tempo(req.tempo, locked_notes)
    grid = grid_args(tempo, req.groove)
    gap_ticks = drum_gap_ticks(instruments)
    with _lock:
        events = sampler.generate(model, 0, req.seconds, top_p=req.top_p, seed=seed,
                                  controls=[tok + CONTROL_OFFSET for tok in fixed_events],
                                  instruments=instruments, key=key_pcs, key_strict=req.strict_key,
                                  drum_min_gap_ticks=gap_ticks, **grid)
        # the model often leaves an instrument out; write a part for any silent track
        by_track = tracks.split_events(events)
        for t in free:
            if len(by_track[t]) // 3 < 0.25 * req.seconds:
                fixed = ops.sort(list(fixed_events) + [tok for o in free if o != t for tok in by_track[o]])
                by_track[t] = sampler.accompany(model, fixed, req.seconds, tracks.instruments_for([t]),
                                                top_p=req.top_p, seed=seed, key=key_pcs,
                                                key_strict=req.strict_key, drum_min_gap_ticks=gap_ticks,
                                                **grid)
        events = ops.sort([tok for t in free for tok in by_track[t]])
    song = song_json(tracks.events_to_midi(events), seed)
    # Re-resolve now there is something to detect "auto" from; a named key is unchanged.
    key_pcs, used_key = resolve_key(req.key, locked_notes + notes_of(song, free))
    tempo = tempo or resolve_tempo(req.tempo, locked_notes + notes_of(song, free))
    song["tracks"] = tidy.tidy_song(song["tracks"], req.busyness, seed, only=set(free),
                                    note_length=req.note_length, key=key_pcs, key_strict=req.strict_key,
                                    tempo=tempo, groove=req.groove, dynamics=req.dynamics)
    for t in locked:   # exactly as they were sent
        song["tracks"][t] = req.song["tracks"].get(t, [])
    song["seconds"] = round(max(song["seconds"], req.seconds,
                                max((n["start"] + n["duration"] for n in locked_notes), default=0)), 3)
    song["key"] = used_key
    song.update(tempo_fields(tempo))
    return song if req.format == "json" else midi_response(json_to_midi(song), seed)


@app.post("/extend")
def extend(req: ExtendRequest):
    """Continue the song for `seconds` more, every listed track at once, from where it ends. The
    song's own notes come back exactly as sent; only the new ones are cleaned up."""
    wanted = [t for t in tracks.ALL_TRACKS if t in req.tracks]
    if not wanted or any(t not in tracks.ALL_TRACKS for t in req.tracks):
        raise HTTPException(422, f"tracks must be from {tracks.ALL_TRACKS}")
    old_notes = notes_of(req.song, tracks.ALL_TRACKS)
    if not old_notes:
        raise HTTPException(422, "the song is empty: generate it first")
    start = max(float(req.song.get("seconds") or 0), max(n["start"] + n["duration"] for n in old_notes))
    end = min(start + req.seconds, MAX_SECONDS)
    if end - start < 1:
        raise HTTPException(422, f"the song is already at the {MAX_SECONDS}-second maximum")
    model = get_model(req.style, req.model, wanted)
    seed = req.seed if req.seed is not None else random.randrange(2**31)
    instruments = tracks.instruments_for(wanted)
    key_pcs, used_key = resolve_key(req.key, old_notes)
    tempo = resolve_tempo(req.tempo, old_notes)
    with _lock:
        merged = sampler.generate(model, start, end, inputs=events_of_song(req.song), top_p=req.top_p,
                                  seed=seed, instruments=instruments, key=key_pcs,
                                  key_strict=req.strict_key, drum_min_gap_ticks=drum_gap_ticks(instruments),
                                  **grid_args(tempo, req.groove))
    start_tick = round(start * TIME_RESOLUTION)
    new = [tok for i in range(0, len(merged), 3) if merged[i] - TIME_OFFSET >= start_tick
           for tok in merged[i:i + 3]]
    added = song_json(tracks.events_to_midi(new), seed)["tracks"]
    added = tidy.tidy_song({t: added[t] for t in wanted}, req.busyness, seed,
                           note_length=req.note_length, key=key_pcs, key_strict=req.strict_key,
                           tempo=tempo, groove=req.groove, dynamics=req.dynamics)
    out = {**req.song, "tracks": {**req.song.get("tracks", {})}}
    for t in wanted:
        out["tracks"][t] = sorted(list(req.song.get("tracks", {}).get(t, [])) +
                                  [n for n in added[t] if n["start"] < end],
                                  key=lambda n: (n["start"], n["pitch"]))
    out["seconds"] = round(end, 3)
    out["seed"] = seed
    out["key"] = used_key
    out.update(tempo_fields(tempo))
    return out


@app.post("/regenerate_track")
async def regenerate_track(request: Request, track: str = Query(...), style: str = "lofi",
                           model: str = "auto",
                           seed: int | None = None, top_p: float = Query(0.98, gt=0, le=1),
                           start: float | None = Query(None, ge=0), end: float | None = Query(None, gt=0),
                           busyness: float = Query(0.5, ge=0, le=1),
                           note_length: float = Query(0.5, ge=0, le=1),
                           key: str = "auto", strict_key: bool = False, tempo: str = "auto",
                           groove: float = Query(0.5, ge=0, le=1),
                           dynamics: float = Query(0.5, ge=0, le=1)):
    if track not in tracks.ALL_TRACKS:
        raise HTTPException(422, f"track must be one of {tracks.ALL_TRACKS}")
    if (start is None) != (end is None):
        raise HTTPException(422, "start and end go together: give both or neither")
    if start is not None and end - start < 0.5:
        raise HTTPException(422, "the range to rewrite must be at least half a second")
    body = await request.body()
    fmt = "json" if "json" in request.headers.get("content-type", "") else "midi"
    if fmt == "json":
        try:
            sent = json.loads(body)
            buf = io.BytesIO()
            json_to_midi(sent).write(buf)
            body = buf.getvalue()
        except Exception as e:
            raise HTTPException(400, f"could not read song JSON: {e}")
    model = get_model(style, model, (track,))
    seed = seed if seed is not None else random.randrange(2**31)

    with tempfile.NamedTemporaryFile(suffix=".mid") as f:
        f.write(body)
        f.flush()
        try:
            song = pretty_midi.PrettyMIDI(f.name)
            events = midi_to_events(f.name)
        except Exception as e:
            raise HTTPException(400, f"could not read MIDI: {e}")

    seconds = min(math.ceil(song.get_end_time()), MAX_SECONDS)
    if seconds < 1:
        raise HTTPException(400, "MIDI file is empty")
    by_track = tracks.split_events(events)
    fixed = ops.sort([tok for t in tracks.ALL_TRACKS if t != track for tok in by_track[t]])
    ranged = start is not None
    if ranged:
        end = min(end, seconds)
        if start >= end:
            raise HTTPException(422, "the range to rewrite starts after the song ends")

    existing_notes = [n for notes in song_json(tracks.events_to_midi(events), seed)["tracks"].values()
                      for n in notes]
    key_pcs, used_key = resolve_key(key, existing_notes)
    song_tempo = resolve_tempo(tempo, existing_notes)
    grid = grid_args(song_tempo, groove)
    instruments = tracks.instruments_for([track])
    gap_ticks = drum_gap_ticks(instruments)
    min_dur_ticks = 0 if track == "drums" else round(tidy.min_duration(track, note_length) * TIME_RESOLUTION)

    def run():
        with _lock:
            if ranged:
                return sampler.rewrite_range(model, ops.sort(events), instruments, start, end,
                                             top_p=top_p, seed=seed, key=key_pcs, key_strict=strict_key,
                                             min_duration_ticks=min_dur_ticks, drum_min_gap_ticks=gap_ticks,
                                             **grid)
            return sampler.accompany(model, fixed, seconds, instruments, top_p=top_p, seed=seed,
                                     key=key_pcs, key_strict=strict_key, min_duration_ticks=min_dur_ticks,
                                     drum_min_gap_ticks=gap_ticks, **grid)

    from starlette.concurrency import run_in_threadpool
    new_events = await run_in_threadpool(run)

    # Swap only the regenerated track; every other track's notes are returned untouched.
    new_notes = tracks.events_to_midi(new_events).instruments[tracks.ALL_TRACKS.index(track)].notes
    # Clean up only what the model just wrote (never the notes that were sent).
    fresh = tidy.tidy_track(track, [{"start": n.start, "duration": n.end - n.start, "pitch": n.pitch,
                                     "velocity": n.velocity} for n in new_notes],
                            busyness, random.Random(f"{seed}-{track}"), note_length=note_length,
                            key=key_pcs, key_strict=strict_key, tempo=song_tempo, groove=groove,
                            dynamics=dynamics)
    new_notes = [pretty_midi.Note(int(n["velocity"]), int(n["pitch"]), n["start"], n["start"] + n["duration"])
                 for n in fresh]
    if ranged:
        # Keep this track's notes outside the range (one ringing into it stops where it starts),
        # and add the new ones, which all start inside it.
        if fmt == "json":
            old = sent["tracks"].get(track, [])
        else:
            old = [{"start": n.start, "duration": n.end - n.start, "pitch": n.pitch, "velocity": n.velocity}
                   for i in song.instruments if tracks.all_track_of(i.program, i.is_drum) == track for n in i.notes]
        kept = []
        for n in old:
            if start <= n["start"] < end:
                continue
            if n["start"] < start < n["start"] + n["duration"]:
                n = {**n, "duration": start - n["start"]}
            kept.append(n)
        added = [{"start": n.start, "duration": n.end - n.start, "pitch": n.pitch, "velocity": n.velocity}
                 for n in new_notes]
        merged = sorted(kept + added, key=lambda n: (n["start"], n["pitch"]))
        if fmt == "json":
            sent["tracks"][track] = [{"start": round(n["start"], 3), "duration": round(n["duration"], 3),
                                      "pitch": n["pitch"], "velocity": n["velocity"]} for n in merged]
            sent["seed"] = seed
            sent["key"] = used_key
            sent.update(tempo_fields(song_tempo))
            return sent
        new_notes = [pretty_midi.Note(int(n["velocity"]), int(n["pitch"]), n["start"], n["start"] + n["duration"])
                     for n in merged]
    if fmt == "json":  # hand the client's other tracks back exactly as they were sent
        sent["tracks"][track] = [{"start": round(n.start, 3), "duration": round(n.end - n.start, 3),
                                  "pitch": n.pitch, "velocity": n.velocity} for n in new_notes]
        last = max((n["start"] + n["duration"] for n in sent["tracks"][track]), default=0)
        sent["seconds"] = round(max(float(sent.get("seconds", 0)), last), 3)
        sent["seed"] = seed
        sent["key"] = used_key
        sent.update(tempo_fields(song_tempo))
        return sent
    song.instruments = [i for i in song.instruments
                        if tracks.all_track_of(i.program, i.is_drum) != track]
    song.instruments.append(pretty_midi.Instrument(
        program=tracks.OUT_PROGRAM[track], is_drum=(track == "drums"), name=track))
    song.instruments[-1].notes = new_notes
    order = {t: n for n, t in enumerate(tracks.ALL_TRACKS)}
    song.instruments.sort(key=lambda i: order.get(tracks.all_track_of(i.program, i.is_drum), 99))
    return respond(song, seed, fmt)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)
