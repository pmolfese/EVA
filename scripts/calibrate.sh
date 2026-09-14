#!/bin/bash
#
# Runs the calibration measurements — the slow, on-demand sweeps that SET the
# run-grade bands, kept out of the default test suite (they are gated behind
# EVA_CALIBRATION=1). Same shape as compare-methods.sh: the app test host is
# sandboxed, so each measurement writes its table into the app container, and
# this copies the results back into docs/provenance/data/ where they are read.
#
# Usage:
#   scripts/calibrate.sh                 # all calibrations
#   scripts/calibrate.sh wavelet         # just the wavelet oversmoothing sweep
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
CONTAINER="$HOME/Library/Containers/gov.nih.nimh.cmn.eva/Data/tmp"
DEST="$REPO/docs/provenance/data"
WHICH="${1:-all}"

echo "==> Building EVA for testing"
xcodebuild build-for-testing -project EVA.xcodeproj -scheme EVA \
    -destination 'platform=macOS' -quiet

run_test() {
    local suite="$1"
    echo "==> Running $suite (EVA_CALIBRATION=1)"
    env TEST_RUNNER_EVA_CALIBRATION=1 \
        xcodebuild test-without-building -project EVA.xcodeproj -scheme EVA \
        -destination 'platform=macOS' -only-testing:"EVATests/$suite" -quiet
}

copy_out() { # container-filename  dest-subdir
    local name="$1" sub="$2"
    if [ -f "$CONTAINER/$name" ]; then
        mkdir -p "$DEST/$sub"
        cp "$CONTAINER/$name" "$DEST/$sub/$name"
        echo "==> Wrote $DEST/$sub/$name"
        cat "$DEST/$sub/$name"
    else
        echo "!! $CONTAINER/$name not found — did the measurement run?" >&2
    fi
}

if [ "$WHICH" = "all" ] || [ "$WHICH" = "wavelet" ]; then
    run_test "WaveletOversmoothingMeasurementTests"
    copy_out "eva-wavelet-oversmoothing.txt" "wavelet-calibration"
fi

echo "==> Done"
