#!/bin/bash
#
#  run-all-tests.sh
#  EVA
#
#  Developed by P. Molfese, National Institutes of Health (NIH).
#
#  This software is a "work of the United States Government" prepared by a federal
#  employee as part of official duties. As such, it is not subject to copyright
#  protection within the United States (17 U.S.C. § 105). International copyrights
#  may apply.
#
#  One command that says whether the whole repository is green.
#
#  Until now that knowledge lived in four separate build.sh files and in
#  somebody's head: the EVA unit suite runs under xcodebuild, each command-line
#  tool builds on its own, and EVASimulate validates its *model* through a
#  `selftest` subcommand rather than through a test target. Those are all
#  reasonable in isolation and there was no single place that ran them.
#
#  Usage:
#    ./run-all-tests.sh              # everything
#    ./run-all-tests.sh --fast       # skip the xcodebuild unit suite (~2 min)
#    ./run-all-tests.sh --list       # show the stages without running them
#
#  Exits non-zero if any stage fails. Stages continue after a failure so one
#  run reports every problem rather than only the first.
#

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

FAST=0
LIST=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        --list) LIST=1 ;;
        -h|--help)
            sed -n '/^#  Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

LOG_DIR="${TMPDIR:-/tmp}/eva-tests-$$"
mkdir -p "$LOG_DIR"

FAILED=()
PASSED=()
SKIPPED=()

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; DIM=""; RESET=""
fi

# stage <name> <command...>
#
# Output goes to a log file rather than the terminal; only the tail of a failing
# stage is printed. A full xcodebuild run is tens of thousands of lines and
# burying the one real error in it is how test output stops being read.
stage() {
    local name="$1"; shift
    local log="$LOG_DIR/${name// /-}.log"

    if [ "$LIST" -eq 1 ]; then
        echo "  $name"
        return 0
    fi

    printf '%s' "${BOLD}▸ ${name}${RESET} ... "
    local start=$SECONDS
    if "$@" > "$log" 2>&1; then
        printf '%sok%s %s(%ds)%s\n' "$GREEN" "$RESET" "$DIM" "$((SECONDS - start))" "$RESET"
        PASSED+=("$name")
        return 0
    fi

    printf '%sFAILED%s %s(%ds)%s\n' "$RED" "$RESET" "$DIM" "$((SECONDS - start))" "$RESET"
    FAILED+=("$name")
    echo "${DIM}--- last 25 lines of $log${RESET}"
    tail -25 "$log" | sed 's/^/    /'
    echo "${DIM}--- full log: $log${RESET}"
    return 1
}

# Builds a Swift command-line tool via its own build.sh.
build_tool() {
    local tool="$1"
    stage "build $tool" bash -c "cd '$REPO/Tools/$tool' && ./build.sh"
}

echo "${BOLD}EVA test run${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
[ "$LIST" -eq 1 ] && echo "Stages:"

# ---------------------------------------------------------------- command-line tools
# Test for existence, not the executable bit: a build.sh that lost +x should be
# a visible failure, not a silently skipped stage.
for tool in EVASimulate EVAHelper EVABIDS mffTimingTool; do
    if [ -f "Tools/$tool/build.sh" ]; then
        build_tool "$tool"
    else
        SKIPPED+=("build $tool (no build.sh)")
    fi
done

# EVASimulate's self-test validates the simulation *model* — that locked clocks
# cancel, that the gradient template returns to baseline, that the forward model
# matches its closed forms. It is not a test of EVA's code and deliberately
# ships inside the binary so a reviewer can run it.
if [ -x "Tools/EVASimulate/.build/eva-simulate" ]; then
    stage "EVASimulate model self-test" \
        bash -c "cd '$REPO/Tools/EVASimulate' && .build/eva-simulate selftest"
else
    SKIPPED+=("EVASimulate model self-test (binary not built)")
fi

# ---------------------------------------------------------------- determinism
# The simulator's central promise is that a seed reproduces a recording
# byte-for-byte. Nothing else in this script would notice if that broke: a
# changed forward model or event writer still emits perfectly valid output.
if [ -x "Tools/EVASimulate/.build/eva-simulate" ] && [ -x "scripts/check-determinism.sh" ]; then
    stage "scenario determinism" bash -c "'$REPO/scripts/check-determinism.sh'"
else
    SKIPPED+=("scenario determinism (scripts/check-determinism.sh missing)")
fi

# ---------------------------------------------------------------- regression corpus
# Tier 7: recordings with known ground truth for the pipeline-regression tests.
# Generated fresh rather than committed — no binary blobs in git, and the
# generator/pipeline seam gets exercised instead of frozen. The tests skip
# cleanly when this directory is absent, so a bare `xcodebuild test` stays fast.
CORPUS="$REPO/.regression-corpus"
if [ "$FAST" -eq 1 ]; then
    SKIPPED+=("regression corpus (--fast)")
elif [ -x "Tools/EVASimulate/.build/eva-simulate" ]; then
    stage "regression corpus" bash -c "
        set -e
        rm -rf '$CORPUS'
        mkdir -p '$CORPUS'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/regression-gradient-locked.json' \
            --output '$CORPUS/gradient-locked'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/regression-gradient-locked.json' \
            --no-gradient --with-bcg --bcg-amplitude 0 \
            --no-impedance --no-impedance-noise \
            --output '$CORPUS/clean-control'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/regression-gradient-locked.json' \
            --clock-offset 152 \
            --output '$CORPUS/gradient-drifting'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/bcg-generators.json' \
            --no-gradient --rate 250 --duration 60 --qrs-jitter 25 \
            --output '$CORPUS/bcg-jitter'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/oddball-erp.json' \
            --no-gradient --no-bcg --rate 250 --duration 50 --erp-trials 30 \
            --output '$CORPUS/oddball-erp'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/teaching-demo.json' \
            --no-gradient --no-bcg --no-emg --blinks 0 --eye-movements 0 \
            --line-noise 0 --rate 250 --duration 30 \
            --bad-channels '7:noisy,15:drift' --bridge '3:4' --bad-reference 30 \
            --output '$CORPUS/recording-defects'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/teaching-demo.json' \
            --no-gradient --rate 250 --duration 60 \
            --eeg-model dipole --sources 5 --bcg-model generators \
            --bcg-amplitude 150 --qrs-jitter 0 --ocular-model dipole \
            --blinks 12 --eye-movements 8 --with-emg --emg 8 \
            --emg-amplitude 60 --emg-high 100 --line-noise 60 \
            --line-noise-amplitude 15 --with-impedance-noise \
            --bad-channels '7:noisy,15:drift' \
            --output '$CORPUS/labeller-benchmark'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/bcg-generators.json' \
            --no-gradient --rate 200 --duration 30 --channels 20 --seed 5401 \
            --eeg-model dipole --sources 5 --bcg-model generators \
            --bcg-field-strength 1.5 --bcg-amplitude 80 --bcg-morphology-jitter 0.08 \
            --bcg-generator-scales '1.4,0.7,0.7,0.5' \
            --no-emg --blinks 0 --eye-movements 0 --line-noise 0 \
            --output '$CORPUS/bcg-labeller-train-lowfield'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/bcg-generators.json' \
            --no-gradient --rate 200 --duration 30 --channels 32 --seed 5402 \
            --eeg-model dipole --sources 7 --bcg-model generators \
            --bcg-field-strength 3 --bcg-amplitude 140 --bcg-morphology-jitter 0.20 \
            --bcg-generator-scales '0.8,1.2,1.2,0.9' \
            --no-emg --blinks 0 --eye-movements 0 --line-noise 0 \
            --output '$CORPUS/bcg-labeller-train-standard'
        '$REPO/Tools/EVASimulate/.build/eva-simulate' generate \
            --config '$REPO/Tools/EVASimulate/scenarios/bcg-generators.json' \
            --no-gradient --rate 200 --duration 30 --channels 24 --seed 5499 \
            --eeg-model dipole --sources 6 --bcg-model generators \
            --bcg-field-strength 7 --bcg-amplitude 70 --bcg-morphology-jitter 0.35 \
            --bcg-generator-scales '0.3,1.7,0.5,1.6' \
            --no-emg --blinks 0 --eye-movements 0 --line-noise 0 \
            --output '$CORPUS/bcg-labeller-heldout'
    "
else
    SKIPPED+=("regression corpus (eva-simulate not built)")
fi

# ---------------------------------------------------------------- EVA unit suite
# EVAUITests is excluded: it needs the UI automation runner, which fails on a
# headless or otherwise busy machine for reasons unrelated to the code. Run it
# yourself when touching the UI.
if [ "$FAST" -eq 1 ]; then
    SKIPPED+=("EVATests unit suite (--fast)")
else
    stage "EVATests unit suite" \
        xcodebuild test \
            -project EVA.xcodeproj \
            -scheme EVA \
            -destination 'platform=macOS' \
            -only-testing:EVATests
fi

# ---------------------------------------------------------------- report
if [ "$LIST" -eq 1 ]; then
    exit 0
fi

echo
echo "${BOLD}Summary${RESET}"
for name in "${PASSED[@]:-}";  do [ -n "$name" ] && echo "  ${GREEN}ok${RESET}      $name"; done
for name in "${SKIPPED[@]:-}"; do [ -n "$name" ] && echo "  ${DIM}skipped${RESET} $name"; done
for name in "${FAILED[@]:-}";  do [ -n "$name" ] && echo "  ${RED}FAILED${RESET}  $name"; done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo
    echo "${RED}${#FAILED[@]} stage(s) failed.${RESET} Logs in $LOG_DIR"
    exit 1
fi

rm -rf "$LOG_DIR"
echo
echo "${GREEN}All stages passed.${RESET}"
