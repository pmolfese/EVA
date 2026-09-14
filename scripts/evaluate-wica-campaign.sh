#!/bin/bash
#
# Run the gated W-ICA simulator campaign and copy its reports out of EVA's
# sandboxed test container. Every substantive command is printed before it runs.
#
# Usage:
#   scripts/evaluate-wica-campaign.sh --quick   # 2 seeds, pipeline smoke/pilot
#   scripts/evaluate-wica-campaign.sh           # 10 seeds, primary campaign
#   scripts/evaluate-wica-campaign.sh --seeds 20

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="$HOME/Library/Containers/gov.nih.nimh.cmn.eva/Data/tmp"
DESTINATION="$REPO/.wica-campaign"
SEEDS=10

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) SEEDS=2; shift ;;
        --seeds)
            if [ "$#" -lt 2 ]; then echo "--seeds needs a positive integer" >&2; exit 2; fi
            SEEDS="$2"; shift 2 ;;
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

echo "The test prints the equivalent eva-simulate generate command for every campaign cell."
run env TEST_RUNNER_EVA_WICA_CAMPAIGN=1 \
    TEST_RUNNER_EVA_WICA_CAMPAIGN_SEEDS="$SEEDS" \
    xcodebuild test-without-building -project EVA.xcodeproj -scheme EVA \
    -destination platform=macOS -only-testing:EVATests/WICACampaignTests

run mkdir -p "$DESTINATION"
for name in eva-wica-campaign.csv eva-wica-campaign.md; do
    if [ ! -f "$CONTAINER/$name" ]; then
        echo "Expected report was not written: $CONTAINER/$name" >&2
        exit 1
    fi
    run cp "$CONTAINER/$name" "$DESTINATION/$name"
done

echo "Results:"
echo "  $DESTINATION/eva-wica-campaign.md"
echo "  $DESTINATION/eva-wica-campaign.csv"
run cat "$DESTINATION/eva-wica-campaign.md"
