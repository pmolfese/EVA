#!/bin/bash
#
#  check-determinism.sh
#  EVA
#
#  Developed by P. Molfese, National Institutes of Health (NIH).
#
#  This software is a "work of the United States Government" prepared by a federal
#  employee as part of official duties. As such, it is not subject to copyright
#  protection within the United States (17 U.S.C. § 105). International copyrights
#  may apply.
#
#  Enforces the simulator's first principle: the same seed produces byte-identical
#  output.
#
#  This is the one guarantee nothing else can check. A changed forward model, a
#  changed event writer, a reordered random draw — all of them still emit a
#  perfectly valid recording that passes every other test, and the only symptom
#  is that a figure published from "scenario X, seed Y" can no longer be
#  regenerated. So the hashes are committed, and a change to them has to be a
#  deliberate, reviewable edit rather than silence.
#
#  Usage:
#    scripts/check-determinism.sh            # verify against committed hashes
#    scripts/check-determinism.sh --update   # re-record them after an intended change
#
#  When this fails, do not reach for --update reflexively. Establish *why* the
#  output moved first; if the move is intended, --update and say so in the commit
#  message, because that commit is the record that published data changed.
#

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATE="$REPO/Tools/EVASimulate/.build/eva-simulate"
SCENARIOS="$REPO/Tools/EVASimulate/scenarios"
BASELINE="$REPO/Tools/EVASimulate/determinism-baseline.txt"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

if [ ! -x "$SIMULATE" ]; then
    echo "eva-simulate is not built; build the EVASimulate target (e.g. via run-all-tests.sh, or 'xcodebuild -project EVA.xcodeproj -target EVASimulate build' and copy the product here) first" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Each scenario is generated exactly as written. Shortening it with a
# --duration override would be faster, but a scenario is a claim about a
# specific recording, and some of them (the ERP oddball) will not even build a
# valid trial schedule at another duration.

hash_scenario() {
    local scenario="$1"
    local name
    name="$(basename "$scenario" .json)"
    local out="$WORK/$name"
    rm -rf "$out"

    if ! "$SIMULATE" generate --config "$scenario" \
        --output "$out" > "$WORK/$name.log" 2>&1; then
        echo "generation failed for $name:" >&2
        tail -10 "$WORK/$name.log" >&2
        return 1
    fi

    # Hash file contents in a stable order, and record the path relative to the
    # run directory so the temporary prefix never enters the hash.
    ( cd "$out" && find . -type f ! -name '*.log' | LC_ALL=C sort | while read -r file; do
        printf '%s  %s\n' "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$file"
    done ) | shasum -a 256 | cut -d' ' -f1
}

STATUS=0
RESULTS="$WORK/results.txt"
: > "$RESULTS"

for scenario in "$SCENARIOS"/*.json; do
    [ -e "$scenario" ] || continue
    name="$(basename "$scenario" .json)"

    first="$(hash_scenario "$scenario")" || { STATUS=1; continue; }
    second="$(hash_scenario "$scenario")" || { STATUS=1; continue; }

    # Self-consistency first: two runs in this build must agree. A failure here
    # is a live nondeterminism bug (an unseeded source, dictionary iteration
    # order, a timestamp), which is a different and worse problem than drift
    # from the committed baseline.
    if [ "$first" != "$second" ]; then
        echo "  NONDETERMINISTIC: $name differs between two runs of this build" >&2
        echo "    run 1: $first" >&2
        echo "    run 2: $second" >&2
        STATUS=1
        continue
    fi

    printf '%s  %s\n' "$first" "$name" >> "$RESULTS"
done

if [ "$UPDATE" -eq 1 ]; then
    {
        echo "# EVA Simulate determinism baseline"
        echo "# SHA-256 over every file each scenario generates, at its own settings."
        echo "# Regenerate with scripts/check-determinism.sh --update, and only when"
        echo "# the output was *meant* to change — this file is the record that it did."
        cat "$RESULTS"
    } > "$BASELINE"
    echo "Recorded $(wc -l < "$RESULTS" | tr -d ' ') scenario hashes in ${BASELINE#"$REPO"/}"
    exit "$STATUS"
fi

if [ ! -f "$BASELINE" ]; then
    echo "no baseline at ${BASELINE#"$REPO"/}; create one with --update" >&2
    exit 2
fi

while read -r expected name; do
    actual="$(grep " $name\$" "$RESULTS" | cut -d' ' -f1)"
    if [ -z "$actual" ]; then
        echo "  MISSING: scenario '$name' is in the baseline but was not generated" >&2
        STATUS=1
    elif [ "$actual" != "$expected" ]; then
        echo "  CHANGED: $name" >&2
        echo "    baseline: $expected" >&2
        echo "    current:  $actual" >&2
        STATUS=1
    fi
done < <(grep -v '^#' "$BASELINE" | grep -v '^$')

while read -r _ name; do
    if ! grep -q " $name\$" "$BASELINE"; then
        echo "  NEW: scenario '$name' has no baseline entry; run --update" >&2
        STATUS=1
    fi
done < "$RESULTS"

if [ "$STATUS" -eq 0 ]; then
    echo "$(wc -l < "$RESULTS" | tr -d ' ') scenarios match the committed baseline."
fi
exit "$STATUS"
