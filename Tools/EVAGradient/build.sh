#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tools/EVAGradient/.build"
OUT="$OUT_DIR/eva-gradient"

mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/ModuleCache"

swiftc -O \
  -module-cache-path "$OUT_DIR/ModuleCache" \
  -Xcc -DACCELERATE_NEW_LAPACK \
  -framework Accelerate \
  -framework Metal \
  "$ROOT/Tools/EVAGradient/main.swift" \
  "$ROOT/Tools/EVAGradient/ExperimentMethods.swift" \
  "$ROOT/Tools/EVAGradient/EngineAddons.swift" \
  "$ROOT/Tools/EVAGradient/JitterExperiment.swift" \
  "$ROOT/Tools/EVAGradient/MethodSelfTests.swift" \
  "$ROOT/EVACore/Core/AccelerateCompat.swift" \
  "$ROOT/EVACore/Core/DSP.swift" \
  "$ROOT/EVACore/Core/LinearAlgebra.swift" \
  "$ROOT/EVA/Core/Downsampler.swift" \
  "$ROOT/EVACore/Epoching/EpochModel.swift" \
  "$ROOT/EVACore/Channels/SensorLayout.swift" \
  "$ROOT/EVACore/Channels/BVEFMontage.swift" \
  "$ROOT/EVACore/Channels/ElectrodeGeometry.swift" \
  "$ROOT/EVACore/IO/EGISensorXMLParser.swift" \
  "$ROOT/EVACore/IO/MFFReader.swift" \
  "$ROOT/EVACore/IO/MFFFileType.swift" \
  "$ROOT/EVACore/Pipeline/EVAProcessingScript.swift" \
  "$ROOT/EVACore/IO/MFFWriter.swift" \
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
