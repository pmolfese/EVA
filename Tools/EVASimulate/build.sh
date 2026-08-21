#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tools/EVASimulate/.build"
OUT="$OUT_DIR/eva-simulate"

# clang stamps the literal path of every cached module into its .pcm and refuses
# to load two spellings of the same module ("module '_DarwinFoundation1' is
# defined in both ...", then a signal 11). On a case-insensitive filesystem
# .../Programming/eva and .../Programming/EVA are one directory but two
# spellings, so a cache populated by a build launched from one spelling crashes
# a build launched from the other. Keying the cache directory by the path as
# spelled keeps those builds from ever sharing one.
CACHE_KEY="$(printf '%s' "$ROOT" | shasum | cut -c1-12)"
MODULE_CACHE="$OUT_DIR/ModuleCache-$CACHE_KEY"

mkdir -p "$OUT_DIR"
mkdir -p "$MODULE_CACHE"

swiftc -O \
  -module-cache-path "$MODULE_CACHE" \
  -Xcc -DACCELERATE_NEW_LAPACK \
  -framework Accelerate \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationConfig.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SignalSynthesis.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/EEGGenerator.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/GradientArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/BCGArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/main.swift" \
  "$ROOT/EVA/Core/AccelerateCompat.swift" \
  "$ROOT/EVA/Core/DSP.swift" \
  "$ROOT/EVA/Core/LinearAlgebra.swift" \
  "$ROOT/EVA/Core/SeededGenerator.swift" \
  "$ROOT/EVA/Epoching/EpochModel.swift" \
  "$ROOT/EVA/IO/MFFFileType.swift" \
  "$ROOT/EVA/Pipeline/EVAProcessingScript.swift" \
  "$ROOT/EVA/IO/MFFReader.swift" \
  "$ROOT/EVA/IO/MFFWriter.swift" \
  -o "$OUT"

echo "$OUT"
