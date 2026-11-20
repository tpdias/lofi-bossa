#!/usr/bin/env bash
# One-time setup on a fresh cloud GPU machine (Ubuntu + CUDA, e.g. a RunPod PyTorch template).
# Run from the repo root:  bash training/cloud/setup.sh
set -euo pipefail
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r training/requirements.txt
.venv/bin/python -c "import torch; print('cuda:', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else '')"
