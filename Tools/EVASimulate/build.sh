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
  "$ROOT/EVA/Core/Forward/ForwardTypes.swift" \
  "$ROOT/EVA/Core/Forward/SphericalForwardModel.swift" \
  "$ROOT/EVA/Core/Forward/EllipsoidalForwardModel.swift" \
  "$ROOT/EVA/Core/Forward/BEMForwardModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationConfig.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationScenario.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/GroupSimulation.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SignalSynthesis.swift" \
  "$ROOT/EVA/IO/EGISensorXMLParser.swift" \
  "$ROOT/EVA/Channels/ElectrodeGeometry.swift" \
  "$ROOT/EVA/Channels/SensorLayout.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/Montage.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationForwardDomain.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/EEGGenerator.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/NonstationaryEEGModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/DipoleEEGGenerator.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/ERPGenerator.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/OcularDipoleModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/OcularArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/EMGArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/AdditionalArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/ChannelDefectModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/ImpedanceModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/GradientArtifactModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/BCGGeneratorModel.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/BCGArtifactModel.swift" \
  "$ROOT/EVA/Artifacts/SourceInformed/SourceInformedOperator.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SurrogateSeparation.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/ERPEvaluation.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/RichMetrics.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SourceMetrics.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift" \
  "$ROOT/Tools/EVASimulate/Sources/EVASimulate/SI0ContractFixtures.swift" \
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
