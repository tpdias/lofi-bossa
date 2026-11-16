"""Local inference server the macOS app talks to.

    .venv/bin/python training/server.py            # http://127.0.0.1:8765

    GET  /health
    POST /generate           JSON {style, seconds, model?, seed?, top_p?, format?}
    POST /regenerate_track   ?track=bass&style=lofi&model=&seed=&top_p=, body = a song

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
from anticipation.convert import midi_to_events
from fastapi import FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

import sampler
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


def model_source(style, choice="auto"):
    """auto = the style's fine-tuned checkpoint when there is one, otherwise the pretrained model."""
    if choice == "pretrained" or (choice == "auto" and not has_finetuned(style)):
        return BASE_MODEL
    return str(CHECKPOINTS / style)


def get_model(style, choice="auto"):
    if style not in STYLES:
        raise HTTPException(422, f"style must be one of {STYLES}")
    if choice not in MODEL_CHOICES:
        raise HTTPException(422, f"model must be one of {MODEL_CHOICES}")
    if choice == "finetuned" and not has_finetuned(style):
        raise HTTPException(422, f"there is no fine-tuned model for {style} (checkpoints/{style}/ is missing)")
    source = model_source(style, choice)
    if source not in _models:
        _models[source] = load_model(source).to(device).eval()
    return _models[source]


def midi_response(pm, seed):
    buf = io.BytesIO()
    pm.write(buf)
    return Response(buf.getvalue(), media_type="audio/midi", headers={"X-Seed": str(seed)})


def song_json(pm, seed):
    notes = {t: [] for t in tracks.TRACKS}
    for inst in pm.instruments:
        track = tracks.track_of(inst.program, inst.is_drum)
        if track:
            notes[track] += [{"start": round(n.start, 3), "duration": round(n.end - n.start, 3),
                              "pitch": n.pitch, "velocity": n.velocity} for n in inst.notes]
    for track_notes in notes.values():
        track_notes.sort(key=lambda n: (n["start"], n["pitch"]))
    return {"seed": seed, "seconds": round(pm.get_end_time(), 3), "tracks": notes}


def json_to_midi(song):
    pm = pretty_midi.PrettyMIDI()
    for t in tracks.TRACKS:
        inst = pretty_midi.Instrument(program=tracks.OUT_PROGRAM[t], is_drum=(t == "drums"), name=t)
        for n in song.get("tracks", {}).get(t, []):
            inst.notes.append(pretty_midi.Note(int(n["velocity"]), int(n["pitch"]), float(n["start"]),
                                               float(n["start"]) + max(float(n["duration"]), 0.01)))
        pm.instruments.append(inst)
    return pm


def respond(pm, seed, fmt):
    return song_json(pm, seed) if fmt == "json" else midi_response(pm, seed)


class GenerateRequest(BaseModel):
    style: str = "lofi"
    model: str = "auto"
    seconds: float = Field(30, ge=5, le=MAX_SECONDS)
    seed: int | None = None
    top_p: float = Field(0.98, gt=0, le=1)
    format: str = Field("midi", pattern="^(midi|json)$")


@app.get("/health")
def health():
    return {"device": device, "tracks": tracks.TRACKS,
            "styles": {s: model_source(s) for s in STYLES},
            "finetuned": [s for s in STYLES if has_finetuned(s)]}


@app.post("/generate")
def generate(req: GenerateRequest):
    model = get_model(req.style, req.model)
    seed = req.seed if req.seed is not None else random.randrange(2**31)
    with _lock:
        events = sampler.generate(model, 0, req.seconds, top_p=req.top_p, seed=seed,
                                  instruments=tracks.instruments_for(tracks.TRACKS))
        # the model often leaves an instrument out; write a part for any silent track
        by_track = tracks.split_events(events)
        for t in tracks.TRACKS:
            if len(by_track[t]) // 3 < 0.25 * req.seconds:
                fixed = ops.sort([tok for o in tracks.TRACKS if o != t for tok in by_track[o]])
                by_track[t] = sampler.accompany(model, fixed, req.seconds, tracks.instruments_for([t]),
                                                top_p=req.top_p, seed=seed)
        events = ops.sort([tok for t in tracks.TRACKS for tok in by_track[t]])
    return respond(tracks.events_to_midi(events), seed, req.format)


@app.post("/regenerate_track")
async def regenerate_track(request: Request, track: str = Query(...), style: str = "lofi",
                           model: str = "auto",
                           seed: int | None = None, top_p: float = Query(0.98, gt=0, le=1)):
    if track not in tracks.TRACKS:
        raise HTTPException(422, f"track must be one of {tracks.TRACKS}")
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
    model = get_model(style, model)
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
    fixed = ops.sort([tok for t in tracks.TRACKS if t != track for tok in by_track[t]])

    def run():
        with _lock:
            return sampler.accompany(model, fixed, seconds, tracks.instruments_for([track]),
                                     top_p=top_p, seed=seed)

    from starlette.concurrency import run_in_threadpool
    new_events = await run_in_threadpool(run)

    # Swap only the regenerated track; every other track's notes are returned untouched.
    new_notes = tracks.events_to_midi(new_events).instruments[tracks.TRACKS.index(track)].notes
    if fmt == "json":  # hand the client's other tracks back exactly as they were sent
        sent["tracks"][track] = [{"start": round(n.start, 3), "duration": round(n.end - n.start, 3),
                                  "pitch": n.pitch, "velocity": n.velocity} for n in new_notes]
        last = max((n["start"] + n["duration"] for n in sent["tracks"][track]), default=0)
        sent["seconds"] = round(max(float(sent.get("seconds", 0)), last), 3)
        sent["seed"] = seed
        return sent
    song.instruments = [i for i in song.instruments
                        if tracks.track_of(i.program, i.is_drum) != track]
    song.instruments.append(pretty_midi.Instrument(
        program=tracks.OUT_PROGRAM[track], is_drum=(track == "drums"), name=track))
    song.instruments[-1].notes = new_notes
    order = {t: n for n, t in enumerate(tracks.TRACKS)}
    song.instruments.sort(key=lambda i: order.get(tracks.track_of(i.program, i.is_drum), 99))
    return respond(song, seed, fmt)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)
