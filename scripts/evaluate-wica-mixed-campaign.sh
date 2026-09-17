#!/bin/bash
# High-density mixed-component rejection/W-ICA/hybrid comparison.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="$HOME/Library/Containers/gov.nih.nimh.cmn.eva/Data/tmp"
DESTINATION="$REPO/.wica-campaign"
SEEDS=10
CHANNELS="64,128,256"
DURATION=120
SOURCES=20

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) SEEDS=2; shift ;;
        --seeds) SEEDS="$2"; shift 2 ;;
        --channels) CHANNELS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --sources) SOURCES="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if ! [[ "$SEEDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "--seeds needs a positive integer" >&2
    exit 2
fi

cd "$REPO"
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

run xcodebuild build-for-testing -project EVA.xcodeproj -scheme EVA \
    -destination platform=macOS -quiet

echo "The test prints each simulator fixture and checkpoints reports after every fit."
run env TEST_RUNNER_EVA_WICA_MIXED_CAMPAIGN=1 \
    TEST_RUNNER_EVA_WICA_MIXED_CAMPAIGN_SEEDS="$SEEDS" \
    TEST_RUNNER_EVA_WICA_CHANNELS="$CHANNELS" \
    TEST_RUNNER_EVA_WICA_DURATION_SECONDS="$DURATION" \
    TEST_RUNNER_EVA_WICA_SOURCE_COUNT="$SOURCES" \
    xcodebuild test-without-building -project EVA.xcodeproj -scheme EVA \
    -destination platform=macOS -only-testing:EVATests/WICACampaignTests

run mkdir -p "$DESTINATION"
for name in eva-wica-density-mixed.csv eva-wica-density-mixed.md \
    eva-wica-density-mixed-routing.csv eva-wica-density-mixed-routing.md; do
    if [ ! -f "$CONTAINER/$name" ]; then
        echo "Expected report was not written: $CONTAINER/$name" >&2
        exit 1
    fi
    run cp "$CONTAINER/$name" "$DESTINATION/$name"
done

echo "Results:"
echo "  $DESTINATION/eva-wica-density-mixed.md"
echo "  $DESTINATION/eva-wica-density-mixed.csv"
echo "  $DESTINATION/eva-wica-density-mixed-routing.md"
echo "  $DESTINATION/eva-wica-density-mixed-routing.csv"
run cat "$DESTINATION/eva-wica-density-mixed.md"
run cat "$DESTINATION/eva-wica-density-mixed-routing.md"
