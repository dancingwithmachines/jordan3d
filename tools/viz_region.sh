#!/usr/bin/env bash
# photo | mask | depth, side by side, for a crop of the frame.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
BIN="$DIR/.build/vizregion"
mkdir -p "$DIR/.build"
if [ ! -x "$BIN" ] || [ "$DIR/VizRegion.swift" -nt "$BIN" ]; then
  swiftc -sdk "$SDK" -target arm64-apple-macos15.0 -O "$DIR/VizRegion.swift" -o "$BIN"
fi
"$BIN" "$@"
