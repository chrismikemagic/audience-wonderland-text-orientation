#!/bin/bash
# Builds LumenTest (first run, or whenever the code changed) and runs it.
# Usage: tester/run.sh [--replay sample] [--claude] [--help]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BIN="$HERE/.build/lumen-test"
SRC=("$ROOT/TextOrientation.swift" "$ROOT/VisionTextOrientation.swift" "$HERE/main.swift")

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "This needs Apple's free developer tools. Run this once, click Install, then try again:"
  echo "  xcode-select --install"
  exit 1
fi

needs_build=0
[ -x "$BIN" ] || needs_build=1
for f in "${SRC[@]}" "$HERE/Info.plist"; do [ "$f" -nt "$BIN" ] && needs_build=1; done

if [ "$needs_build" = 1 ]; then
  echo "Building LumenTest (about 30 seconds the first time)..."
  mkdir -p "$HERE/.build"
  xcrun swiftc -O -o "$BIN" "${SRC[@]}" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HERE/Info.plist"
fi

exec "$BIN" "$@"
