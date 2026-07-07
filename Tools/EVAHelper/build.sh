#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tools/EVAHelper/.build"
OUT="$OUT_DIR/eva-helper"

mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/ModuleCache"

swiftc -O \
  -module-cache-path "$OUT_DIR/ModuleCache" \
  -Xcc -DACCELERATE_NEW_LAPACK \
  -framework Accelerate \
  -framework Metal \
  "$ROOT/Tools/EVAHelper/Sources/EVAHelper/main.swift" \
  "$ROOT/Tools/EVAHelper/Sources/EVAHelper/BrainVisionHelperReader.swift" \
  "$ROOT/Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift" \
  "$ROOT/EVA/Core/AccelerateCompat.swift" \
  "$ROOT/EVA/Core/DSP.swift" \
  "$ROOT/EVA/Core/LinearAlgebra.swift" \
  "$ROOT/EVA/Core/Downsampler.swift" \
  "$ROOT/EVA/Epoching/EpochModel.swift" \
  "$ROOT/EVA/IO/MFFReader.swift" \
  "$ROOT/EVA/IO/MFFWriter.swift" \
  "$ROOT/EVA/Gradient/GradientRemover.swift" \
  -o "$OUT"

echo "$OUT"
