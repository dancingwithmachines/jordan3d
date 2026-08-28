#!/usr/bin/env bash
# Compiles and runs the layer splitter. SDK is pinned for the same reason as
# make_depth.sh — the CLT ships a newer SDK than this swiftc supports.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
BIN="$DIR/.build/splitlayers"
mkdir -p "$DIR/.build"
if [ ! -x "$BIN" ] || [ "$DIR/SplitLayers.swift" -nt "$BIN" ]; then
  swiftc -sdk "$SDK" -target arm64-apple-macos15.0 -O "$DIR/SplitLayers.swift" -o "$BIN"
fi
"$BIN" "$@"
