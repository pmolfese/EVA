#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tools/mffTimingTool/.build"
OUT="$OUT_DIR/mff-timing-tool"

mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/ModuleCache"

swiftc -O \
  -module-cache-path "$OUT_DIR/ModuleCache" \
  "$ROOT/Tools/mffTimingTool/Sources/mffTimingTool/main.swift" \
  -o "$OUT"

echo "$OUT"
