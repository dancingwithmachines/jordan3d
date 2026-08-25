#!/usr/bin/env bash
# macOS TCC blocks the preview server from reading ~/Desktop, so the live
# preview is served from a /tmp mirror. Run this after editing the source.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST=/tmp/jordan3d-preview
mkdir -p "$DST"
rsync -a --delete --exclude 'sync.sh' --exclude '.git' --exclude 'grabs' "$SRC/" "$DST/"
echo "synced -> $DST"
