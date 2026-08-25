#!/usr/bin/env bash
# Compiles and runs the Vision-based depth builder.
# The SDK is pinned: the CLT ships a newer SDK than this swiftc supports.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
BIN="$DIR/.build/depthfrommatte"
mkdir -p "$DIR/.build"

if [ ! -x "$BIN" ] || [ "$DIR/DepthFromMatte.swift" -nt "$BIN" ]; then
  swiftc -sdk "$SDK" -target arm64-apple-macos15.0 -O \
    "$DIR/DepthFromMatte.swift" -o "$BIN"
fi

"$BIN" "$@"
