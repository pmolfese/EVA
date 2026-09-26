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
#   scripts/calibrate.sh wica            # just W-ICA preservation/removal
#   scripts/calibrate.sh gradient        # gradient run-grade residual vs truth
#   scripts/calibrate.sh ica             # ICA data sufficiency vs decomposition quality
#   scripts/calibrate.sh artifact        # artifact-clean touched fraction vs harm
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
CONTAINER="$HOME/Library/Containers/gov.nih.nimh.cmn.eva/Data/tmp"
RUNNER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
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
    local source="$CONTAINER/$name"
    if [ ! -f "$source" ] && [ -n "$RUNNER_TMP" ] && [ -f "$RUNNER_TMP/$name" ]; then
        source="$RUNNER_TMP/$name"
    fi
    if [ -f "$source" ]; then
        mkdir -p "$DEST/$sub"
        cp "$source" "$DEST/$sub/$name"
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

if [ "$WHICH" = "all" ] || [ "$WHICH" = "wica" ]; then
    run_test "WICAPreservationMeasurementTests"
    copy_out "eva-wica-preservation.txt" "wavelet-calibration"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "gradient" ]; then
    run_test "GradientRunGradeMeasurementTests"
    copy_out "eva-gradient-run-grade.txt" "gradient-calibration"
    copy_out "eva-gradient-run-grade.csv" "gradient-calibration"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "ica" ]; then
    run_test "ICARunGradeMeasurementTests"
    copy_out "eva-ica-run-grade.txt" "ica-calibration"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "artifact" ]; then
    run_test "ArtifactCleanRunGradeMeasurementTests"
    copy_out "eva-artifact-clean-run-grade.txt" "artifact-clean-calibration"
fi

echo "==> Done"
