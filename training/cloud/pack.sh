#!/usr/bin/env bash
# Zip the checkpoints and logs so they can be downloaded: checkpoints.zip in the repo root.
set -euo pipefail
zip -r checkpoints.zip checkpoints logs -x '*/optimizer*'
ls -lh checkpoints.zip
