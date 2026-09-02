#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tools/EVABIDS/.build"
OUT="$OUT_DIR/eva-bids"

mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/ModuleCache"

swiftc -O \
  -module-cache-path "$OUT_DIR/ModuleCache" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/main.swift" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/BIDSCommon.swift" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/EDFCodec.swift" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/ToBIDS.swift" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/FromBIDS.swift" \
  "$ROOT/Tools/EVABIDS/Sources/EVABIDS/InspectBIDS.swift" \
  "$ROOT/EVACore/Epoching/EpochModel.swift" \
  "$ROOT/EVACore/IO/EGISensorXMLParser.swift" \
  "$ROOT/EVACore/IO/MFFReader.swift" \
  "$ROOT/EVACore/IO/MFFFileType.swift" \
  "$ROOT/EVACore/Pipeline/EVAProcessingScript.swift" \
  "$ROOT/EVACore/IO/MFFWriter.swift" \
  "$ROOT/EVACore/Channels/SensorLayout.swift" \
  "$ROOT/EVACore/Channels/ElectrodeGeometry.swift" \
  -o "$OUT"

echo "$OUT"
