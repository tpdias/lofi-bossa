# Training on a cloud GPU

Fine-tunes the model on all seven tracks (piano, guitar, bass, drums, keys & pads, lead, vibes)
for both styles. A single 24 GB GPU (RTX 4090 / A5000 / L4) is plenty. The CC BY set is about
4,200 files and 230-260 hours of music per style (2-5x the old GigaMIDI set), so expect several
hours per style; early stopping usually ends it sooner. To shorten it, pick fewer Lakh files:
`training/sources/lakh.py --max-per-style 2500` (default 4000), then rebuild the manifest.
Fine-tuning on the Mac works for smoke tests only.

## 1. Prepare the data locally

The models that ship are trained only on CC BY 4.0 data: a lo-fi / bossa slice of the Lakh
MIDI Dataset, the Groove MIDI Dataset and GuitarSet (see `training/DATA_LICENSES.md`). GigaMIDI
(CC BY-NC) is left out by `--licenses cc-by`, which is also what `train_all.sh` uses by default.
All commands run from the repo root on your Mac.

```bash
# once: LMD-full, lmd_full.tar.gz, 1.77 GB from colinraffel.com/projects/lmd -> datasets/lakh/
.venv/bin/python training/sources/lakh.py --download
# pick lo-fi-like and bossa-like files by their music (about an hour the first time on 8 cores;
# features are cached in processed/lakh_features.jsonl, so reruns take a minute)
.venv/bin/python training/sources/lakh.py --show 20
.venv/bin/python training/data/build_manifest.py          # adds Groove, GuitarSet (+ GigaMIDI rows)
.venv/bin/python training/preprocess.py --licenses cc-by  # drops the GigaMIDI rows
cat processed/report.md                                   # files and hours per style and source
grep -c gigamidi processed/index.jsonl                    # must print 0
tar czf processed.tar.gz processed/index.jsonl processed/midi
```

Start from an empty `processed/midi` (move an old GigaMIDI build out of `processed/` first)
so the tarball holds only the files in the new index.

## 2. Rent a machine

RunPod (or any provider): a PyTorch template with CUDA, one 24 GB GPU, 50 GB disk. Colab Pro
with an A100/L4 also works. Then, from your Mac:

```bash
git clone https://github.com/tpdias/lofi-bossa && cd lofi-bossa   # on the machine
# upload processed.tar.gz into the repo folder (runpodctl send, scp, or the web UI)
tar xzf processed.tar.gz
bash training/cloud/setup.sh
```

## 3. Train

```bash
bash training/cloud/train_all.sh
```

Runs `bossa` then `lofi` with `--licenses cc-by` (`LICENSES=all` would also use GigaMIDI;
never ship that result). Sequences are built once per style and cached in
`processed/sequences/`. It validates every 200 steps and keeping the checkpoint with the lowest
validation loss in `checkpoints/<style>/` (final weights also in `checkpoints/<style>-last/`).
Defaults are tuned against overfitting (a few thousand files per style overfit fast): 1 epoch,
learning rate 5e-6, weight decay 0.05, 2 copies per file, and an automatic stop after 5
validation runs without a new best (`--patience`). Batch size is 8; out of memory: `BATCH=4`.
Each validation line also prints the loss per track (piano, keys, lead, vibes...), which is the
number to watch for the extra tracks. More brakes if it still overfits: `--freeze-layers 6`,
`--dropout 0.2` (CUDA only; the Mac's MPS backend can't run attention dropout), `--lr 2e-6`.
It finishes by running `pack.sh`, which writes `checkpoints.zip`.

What the extra flags do: `--transpose` shifts every training copy by a random -5..+6 semitones;
`--boost-vibes 3` / `--boost-lead 1` add copies where that track is the one written, because
only ~12% of files have vibes.

## 4. Bring the result home

Download `checkpoints.zip` and unzip it in the repo root on your Mac (this replaces
`checkpoints/bossa` and adds `checkpoints/lofi`). Each checkpoint contains `tracks.json`, which
tells the server it knows all seven tracks; restart the server and `/health` shows
`finetuned_tracks`. Compare with the Model menu in the app: Pretrained vs Fine-tuned.

Optional but recommended: blend the fine-tuned weights with the base model and keep the mix
with the lowest validation loss. This often beats both ends when fine-tuning overfits:

```bash
cd training && ../.venv/bin/python blend.py --style bossa \
  --sequences ../processed/sequences/<the .npz that finetune.py built>
```

It writes `checkpoints/bossa-blend` when a mix wins (rename it to `checkpoints/bossa`), and
says plainly when the base model won, which means fine-tuning didn't help for that style.

Check `checkpoints/<style>/training_log.json`: `"licenses": "cc-by"` must be in it, and
`best_val_loss` should be clearly below `baseline_val_loss`. Note the baseline is lower than
with GigaMIDI: the base model was pretrained on Lakh, so it already knows these files' style of
MIDI, and the gain from fine-tuning is mostly the style shift. Stop the machine when done.

Note: the old `checkpoints/bossa` (trained on four tracks) keeps working; the server uses the
pretrained model for Keys, Lead and Vibes until it is replaced.
