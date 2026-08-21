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
  "$ROOT/EVA/Epoching/EpochModel.swift" \
  "$ROOT/EVA/IO/EGISensorXMLParser.swift" \
  "$ROOT/EVA/IO/MFFReader.swift" \
  "$ROOT/EVA/IO/MFFFileType.swift" \
  "$ROOT/EVA/Pipeline/EVAProcessingScript.swift" \
  "$ROOT/EVA/IO/MFFWriter.swift" \
  "$ROOT/EVA/Channels/SensorLayout.swift" \
  "$ROOT/EVA/Channels/ElectrodeGeometry.swift" \
  -o "$OUT"

echo "$OUT"
