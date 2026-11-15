# Lo-Fi / Bossa Nova music generator

macOS app (Swift) that generates 4-track background music (piano, guitar, bass, drums),
backed by a symbolic music model fine-tuned in Python.

- `training/` Python: data pipeline now; fine-tuning, evaluation and inference server later
- `app/` Swift macOS app (not started)

## Data pipeline

```bash
python3.13 -m venv .venv && .venv/bin/pip install -r training/requirements.txt
.venv/bin/python training/data/download.py groove guitarset
.venv/bin/python training/data/build_manifest.py \
  --midicaps-meta https://huggingface.co/datasets/amaai-lab/MidiCaps/resolve/main/train.json
.venv/bin/python training/preprocess.py
```

Output: `processed/manifest.jsonl` (candidates), `processed/midi/<style>/*.mid` (clean 4-track
files), `processed/index.jsonl`, `processed/report.md`.

Style rules live in `training/data/styles.py`. Each style has a `core` tier (tagged as the
style) and a `wide` tier (neighbouring genres).

## What the data looks like so far (2026-11-15)

| Source | bossa core | bossa wide | lofi core | lofi wide | Notes |
|---|---|---|---|---|---|
| GuitarSet | 72 | 72 | 0 | 72 | guitar only; real bossa nova comping |
| Groove MIDI | 2 | 46 | 35 | 78 | drums only |
| MidiCaps (metadata only) | 0 | 4,594 | 2 | 780 | multitrack, but see below |

MidiCaps has **no** bossa nova tag and almost no hip-hop/chillout tags (8 and 17 files out of
168,385). Its genre labels come from an audio tagger and are coarse, so it only provides a
"jazz / latin / easy listening" wide tier. Multitrack files that are genuinely bossa nova or
lo-fi have to come from GigaMIDI (gated, has Discogs / Last.fm style labels) or from
Lakh-matched files joined with Million Song Dataset artist and tag metadata.

## Pretrained model check (2026-11-15, M1 Pro, MPS)

```bash
.venv/bin/pip install torch transformers "anticipation @ git+https://github.com/jthickstun/anticipation.git"
.venv/bin/python training/check_model.py processed/midi/bossa/<guitar file>.mid
```

`stanford-crfm/music-small-800k` (128M parameters) loads through `transformers` as a GPT-2 model.

| Check | Result |
|---|---|
| Unconditional 12 s clip | 354 notes in 112 s; used guitar, bass, piano, drums **and strings** |
| Accompaniment around a fixed bossa guitar track, 12 s | 18 s; guitar notes preserved exactly; model added drums only |
| Training loss on a bossa guitar file | 3.13 nats/token (uniform = 10.92); gradients flow |

What this means for the next steps:
- Fine-tuning with plain `transformers` works; no need for the authors' Levanter setup.
- Sampling must mask the note vocabulary to our four instruments, and for "regenerate track X"
  to exactly instrument X. The library's `generate` has no such option.
- The library re-runs the full context for every token (no key/value cache), so dense music
  generates slower than real time on the Mac. The inference server needs its own cached sampler.

## Sampler (`training/sampler.py`, `training/tracks.py`)

Cached, instrument-restricted replacement for the library's `generate`. Tested on M1 Pro:

| Check | Result |
|---|---|
| Cached logits vs a full forward pass | max difference 0.0003, same top token |
| 45 s clip limited to the four tracks | 833 notes in 23 s (faster than real time); no other instruments |
| Regenerate bass around the other three tracks, 45 s | 15 s; only bass notes written |
| Same seed twice | identical output |

`tracks.events_to_midi` writes the 4-track MIDI the app will read. The model has no tempo or
velocity: time is absolute and velocities are fixed per track.

## Inference server (`training/server.py`)

```bash
.venv/bin/python training/server.py     # http://127.0.0.1:8765
```

```bash
curl -o song.mid -H 'Content-Type: application/json' -d '{"style":"bossa","seconds":30,"seed":42}' localhost:8765/generate
```

```bash
curl -o song2.mid --data-binary @song.mid "localhost:8765/regenerate_track?track=bass&style=bossa"
```

Both return 4-track MIDI with the seed in the `X-Seed` header. Tested on M1 Pro: a 30 s clip took
31 s on the first request (includes loading the model), regenerating its bass took 4 s, and
the other three tracks came back note-for-note identical. A style uses `checkpoints/<style>/`
when that folder exists, otherwise the pretrained base model, so **both styles currently
produce generic pretrained output**.

## Not done yet

- Real multitrack bossa / lo-fi data: GigaMIDI adapter (waiting on access), Kaggle lo-fi set
  (needs a Kaggle login; unzip into `datasets/kaggle_lofi/`), MidiCaps MIDI download (1.6 GB)
- Tokenization and fine-tuning script
- Tempo / key control (the model has neither; time is absolute)
- macOS app
