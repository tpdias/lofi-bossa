# Data and model licenses

Models that ship in the app are trained with `--licenses cc-by`, which uses only the sources
marked **ships** below. The filter lives in `training/licenses.py` and is applied by
`preprocess.py`, `finetune.py` and `cloud/train_all.sh` (which defaults to `cc-by`).

| Source | License | Used for | Ships |
|---|---|---|---|
| Anticipatory Music Transformer, `stanford-crfm/music-small-800k` | Apache 2.0 (weights); pretrained on the Lakh MIDI Dataset (CC BY 4.0) | Base model that every style is fine-tuned from | yes |
| Lakh MIDI Dataset, LMD-full | CC BY 4.0 | Lo-fi-like and bossa-like multitrack songs picked by `sources/lakh.py` | yes |
| Groove MIDI Dataset | CC BY 4.0 | Human drum performances: bossa (`latin/brazilian-*`) and lo-fi (`hiphop`, `jazz`, `soul`, `funk`) grooves | yes |
| GuitarSet | CC BY 4.0 (checked 2026-11-26 on Zenodo record 3371780, v1.1.0) | Real guitar comping: bossa nova (`BN`) and jazz excerpts | yes |
| GigaMIDI | CC BY-NC 4.0, gated, may contain copyrighted arrangements | Earlier experiments only | **no** |
| MidiCaps | CC BY-SA 4.0 | Not downloaded; would only add captions to Lakh files | no |
| Kaggle lo-fi MIDI | unknown | Not downloaded | no |

## Why each source is used

- **Lakh MIDI Dataset.** The biggest openly licensed collection of multitrack MIDI, and the
  data the base model was pretrained on, so fine-tuning on a slice of it only shifts the
  model's style rather than teaching it a new notation. LMD-full has no genre labels we can
  use, so `sources/lakh.py` picks files from the music itself: instruments (nylon guitar,
  brush and jazz drum kits, electric piano, upright and fingered bass, pads), tempo, swing,
  syncopation (sixteenth-note anticipations) and how often chords carry 7ths and 9ths. The
  Million Song Dataset matches and Last.fm tags that come with LMD are not used for training
  and are not included in the app; at most a few picks can be compared against them by hand.
- **Groove MIDI Dataset.** Drums played by people on an electronic kit, with style labels,
  so the drum track gets a human feel (ghost notes, swing) that sequenced MIDI lacks.
- **GuitarSet.** Real guitar performances, including bossa nova comping, which no MIDI
  collection has much of.
- **GigaMIDI** was most of the earlier training data, but its license is non-commercial, it
  is access-on-request and it may contain copyrighted arrangements, so it can't be part of an
  entry that has to follow every license it uses. It stays usable for local experiments with
  `--licenses all`; checkpoints trained that way must not be shipped.

## Credit, as it should appear in the app

> Music model: Anticipatory Music Transformer by John Thickstun, David Hall, Chris Donahue and
> Percy Liang (Stanford CRFM), Apache 2.0. Fine-tuned on the Lakh MIDI Dataset by Colin Raffel
> (CC BY 4.0), the Groove MIDI Dataset by Google Magenta (CC BY 4.0) and GuitarSet by Qingyang
> Xi, Rachel Bittner, Johan Pauwels, Xuzhou Ye and Juan P. Bello (CC BY 4.0). Changes: files
> were selected, reduced to seven instrument tracks and converted to training sequences.

## Citations

- Lakh MIDI Dataset: Colin Raffel. *Learning-Based Methods for Comparing Sequences, with
  Applications to Audio-to-MIDI Alignment and Matching.* PhD thesis, Columbia University, 2016.
  <https://colinraffel.com/projects/lmd/>
- Groove MIDI Dataset: Jon Gillick, Adam Roberts, Jesse Engel, Douglas Eck and David Bamman.
  *Learning to Groove with Inverse Sequence Transformations.* ICML 2019.
  <https://magenta.tensorflow.org/datasets/groove>
- GuitarSet: Qingyang Xi, Rachel M. Bittner, Johan Pauwels, Xuzhou Ye and Juan P. Bello.
  *GuitarSet: A Dataset for Guitar Transcription.* ISMIR 2018.
  <https://doi.org/10.5281/zenodo.3371780>
- Anticipatory Music Transformer: John Thickstun, David Hall, Chris Donahue and Percy Liang.
  *Anticipatory Music Transformer.* Transactions on Machine Learning Research, 2024.
  <https://huggingface.co/stanford-crfm/music-small-800k>
