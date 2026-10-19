#!/bin/bash
# Compile the production builder with only lightweight display-data adapters.
# Usage: ./Tools/spatial-benchmark/run.sh [events=1000] [sensors=128] [repeats=3]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eva-spatial-benchmark.XXXXXX")"
trap 'rm -rf "$BENCH_DIR"' EXIT
swiftc -O -D PROGRESSIVE -module-cache-path "$BENCH_DIR/modules" -parse-as-library \
    "$ROOT/Tools/spatial-benchmark/Support.swift" \
    "$ROOT/EVA/Artifacts/ArtifactSpatialGrouping.swift" \
    "$ROOT/Tools/spatial-benchmark/Benchmark.swift" -o "$BENCH_DIR/benchmark"
"$BENCH_DIR/benchmark" "${1:-1000}" "${2:-128}" "${3:-3}"
