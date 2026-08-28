#!/bin/bash
#
# Runs the method-comparison harness (ROADMAP 3.2) and puts its results where a
# human can find them.
#
# Why this script exists at all: the test host is the sandboxed EVA app, so the
# harness cannot write into the working tree — it writes inside the app
# container instead. Copying the results back out is something only a process
# outside the sandbox can do, which is this one.
#
# Usage:
#   ./compare-methods.sh                       # the committed matrix
#   ./compare-methods.sh path/to/matrix.json   # a one-off matrix
#   EVA_COMPARISON_REGENERATE=1 ./compare-methods.sh   # re-generate the corpus
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

MATRIX="${1:-}"
CONTAINER="$HOME/Library/Containers/gov.nih.nimh.cmn.eva/Data/Library/Application Support/EVAComparison"
DESTINATION="$REPO/.comparison"

# The harness scores through eva-simulate, so it has to exist first.
if [ ! -x "Tools/EVASimulate/.build/eva-simulate" ]; then
    echo "==> Building eva-simulate"
    swift build -c release --package-path Tools/EVASimulate
    mkdir -p Tools/EVASimulate/.build
    cp "$(swift build -c release --package-path Tools/EVASimulate --show-bin-path)/eva-simulate" \
        Tools/EVASimulate/.build/eva-simulate
fi

echo "==> Building EVA for testing"
xcodebuild build-for-testing -project EVA.xcodeproj -scheme EVA \
    -destination 'platform=macOS' -quiet

echo "==> Running the comparison matrix (this is minutes of compute per arm)"
# `TEST_RUNNER_` is how xcodebuild passes an environment variable through to the
# test process; a plain export does not reach it.
env TEST_RUNNER_EVA_COMPARISON=1 \
    ${MATRIX:+TEST_RUNNER_EVA_COMPARISON_MATRIX="$(cd "$(dirname "$MATRIX")" && pwd)/$(basename "$MATRIX")"} \
    ${EVA_COMPARISON_REGENERATE:+TEST_RUNNER_EVA_COMPARISON_REGENERATE="$EVA_COMPARISON_REGENERATE"} \
    xcodebuild test-without-building -project EVA.xcodeproj -scheme EVA \
    -destination 'platform=macOS' -only-testing:EVATests/MethodComparisonTests

echo "==> Copying results out of the app container"
mkdir -p "$DESTINATION"
# Results only. The generated corpus and the processed packages stay in the
# container: they are large, they are rebuildable from the committed matrix and
# seeds, and keeping them out means `.comparison` is small enough to read.
for directory in "$CONTAINER"/*/; do
    name="$(basename "$directory")"
    case "$name" in
        corpus|runs) continue ;;
    esac
    mkdir -p "$DESTINATION/$name"
    # Results, the paired table, and the resolved scenario configurations — the
    # configurations especially: they are how someone regenerates these exact
    # recordings without reconstructing a command line.
    cp "$directory"comparison_results.* "$directory"comparison_paired.csv \
       "$directory"scenario-*.json "$DESTINATION/$name/" 2>/dev/null || true
done

echo
echo "Results in $DESTINATION"
ls -1 "$DESTINATION"/*/comparison_results.md 2>/dev/null || true
