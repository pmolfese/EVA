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
  "$ROOT/Tools/EVAHelper/Sources/EVAHelper/OriginalCWLCorrectorEngine.swift" \
  "$ROOT/EVA/Core/AccelerateCompat.swift" \
  "$ROOT/EVA/Core/DSP.swift" \
  "$ROOT/EVA/Core/LinearAlgebra.swift" \
  "$ROOT/EVA/Core/Downsampler.swift" \
  "$ROOT/EVA/Epoching/EpochModel.swift" \
  "$ROOT/EVA/Channels/SensorLayout.swift" \
  "$ROOT/EVA/IO/EGISensorXMLParser.swift" \
  "$ROOT/EVA/IO/MFFReader.swift" \
  "$ROOT/EVA/IO/MFFFileType.swift" \
  "$ROOT/EVA/Pipeline/EVAProcessingScript.swift" \
  "$ROOT/EVA/IO/MFFWriter.swift" \
  "$ROOT/EVA/Gradient/MotionParameters.swift" \
  "$ROOT/EVA/Gradient/GradientAAS.swift" \
  "$ROOT/EVA/Gradient/GradientCorrectionTypes.swift" \
  "$ROOT/EVA/Gradient/GradientEpochLayout.swift" \
  "$ROOT/EVA/Gradient/GradientSincResampler.swift" \
  "$ROOT/EVA/Gradient/GradientFilters.swift" \
  "$ROOT/EVA/Gradient/GradientANC.swift" \
  "$ROOT/EVA/Gradient/GradientAcceleration.swift" \
  "$ROOT/EVA/Gradient/GradientMetalBackend.swift" \
  "$ROOT/EVA/Gradient/GradientEpochAligner.swift" \
  "$ROOT/EVA/Gradient/GradientOBS.swift" \
  "$ROOT/EVA/Gradient/GradientTemplateCorrector.swift" \
  "$ROOT/EVA/Gradient/GradientDonorSelection.swift" \
  -o "$OUT"

echo "$OUT"
