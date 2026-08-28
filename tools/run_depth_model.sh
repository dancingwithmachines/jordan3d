#!/usr/bin/env bash
# Wrapper so the venv does not need activating.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -x "$DIR/.venv/bin/python" ]; then
  echo "no venv — run: python3 -m venv tools/.venv && tools/.venv/bin/pip install torch transformers pillow numpy" >&2
  exit 1
fi
exec "$DIR/.venv/bin/python" "$DIR/depth_model.py" "$@"
