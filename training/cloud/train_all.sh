#!/usr/bin/env bash
# Fine-tune both styles on all seven tracks. Run from the repo root after setup.sh, with
# processed/ uploaded (see training/cloud/README.md). Logs go to logs/<style>.log.
#
#   bash training/cloud/train_all.sh            # full run
#   EPOCHS=1 bash training/cloud/train_all.sh   # shorter
set -euo pipefail
mkdir -p logs
for style in bossa lofi; do
  .venv/bin/python -u training/finetune.py --style "$style" \
    --epochs "${EPOCHS:-3}" --batch-size "${BATCH:-16}" \
    --transpose --boost-vibes 3 --boost-lead 1 \
    --eval-every 100 --save-last 2>&1 | tee "logs/$style.log"
done
bash training/cloud/pack.sh
