#!/bin/bash
#
#  compare-paired-run.sh
#  EVA
#
#  Developed by P. Molfese, National Institutes of Health (NIH).
#
#  This software is a "work of the United States Government" prepared by a federal
#  employee as part of official duties. As such, it is not subject to copyright
#  protection within the United States (17 U.S.C. § 105). International copyrights
#  may apply.
#
#  Byte-compares two MFF packages from a paired interactive/headless run.
#
#  Nothing in EVATests proves interactive/headless parity — it cannot. Every
#  divergence this project has found came from comparing bytes, and twice the
#  logs agreed while the data did not. So this exists to make the comparison
#  cheap enough that it actually gets done.
#
#  Usage:  Tools/compare-paired-run.sh <interactive.mff> <headless.mff>
#
#  Exit status is 0 when everything that must match does. Differences that are
#  *expected* (timestamps, the package's own name) are reported as notes, not
#  failures.
#

# Re-exec under bash when invoked as `sh compare-paired-run.sh`. The comparisons
# below use process substitution, which is a bash feature — under POSIX `sh` this
# dies with "syntax error near unexpected token `('" partway through, *after*
# printing real results, which reads like a partial failure rather than a shell
# problem.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

set -uo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <interactive.mff> <headless.mff>" >&2
    exit 2
fi

A="${1%/}"
B="${2%/}"
FAILED=0

for pkg in "$A" "$B"; do
    if [ ! -d "$pkg" ]; then
        echo "not a package directory: $pkg" >&2
        exit 2
    fi
done

# A file this script cannot *read* must not be reported as a file that
# *differs* — `cmp` exits non-zero either way, and a sandbox or permissions
# problem masquerading as a parity failure would waste exactly the time this
# script exists to save.
for pkg in "$A" "$B"; do
    probe=$(ls "$pkg"/*.xml 2>/dev/null | head -1)
    if [ -z "$probe" ] || ! head -c 1 "$probe" > /dev/null 2>&1; then
        echo "cannot read inside $pkg — check permissions, then re-run." >&2
        exit 2
    fi
done

echo "A: $A"
echo "B: $B"
echo

# ---------------------------------------------------------------- the samples
# The one that matters. Byte-identical or it is not parity.
echo "=== signal data ==="
for bin in signal1.bin signal2.bin; do
    if [ -f "$A/$bin" ] || [ -f "$B/$bin" ]; then
        if cmp -s "$A/$bin" "$B/$bin"; then
            printf '  %-16s IDENTICAL (%s bytes)\n' "$bin" "$(stat -f%z "$A/$bin")"
        else
            printf '  %-16s **DIFFERS**\n' "$bin"
            FAILED=1
        fi
    fi
done
echo

# ------------------------------------------------------------- structural XML
echo "=== structure ==="
for f in categories.xml epochs.xml info1.xml coordinates.xml sensorLayout.xml Events_EVA.xml; do
    if [ -f "$A/$f" ] || [ -f "$B/$f" ]; then
        if cmp -s "$A/$f" "$B/$f"; then
            printf '  %-20s identical\n' "$f"
        else
            printf '  %-20s **DIFFERS**\n' "$f"
            FAILED=1
        fi
    fi
done
echo

# ------------------------------------------------------------------- eva.xml
# Timestamps are expected to differ; everything else is not.
echo "=== eva.xml (timestamps stripped) ==="
strip_times() {
    sed -E 's/ (writtenAt|appliedAt)="[^"]*"//g' "$1"
}
if diff <(strip_times "$A/eva.xml") <(strip_times "$B/eva.xml") > /tmp/eva-diff.$$ 2>&1; then
    echo "  identical apart from timestamps"
else
    echo "  **DIFFERS**"
    sed 's/^/    /' /tmp/eva-diff.$$
    FAILED=1
fi
rm -f /tmp/eva-diff.$$
echo

# ---------------------------------------------------------------- the sidecars
echo "=== payload sidecars ==="
for f in eva_ica.json eva_artifacts.json; do
    if [ -f "$A/$f" ] && [ -f "$B/$f" ]; then
        # `createdAt` is provenance and is expected to move.
        if diff <(grep -v '"createdAt"' "$A/$f") <(grep -v '"createdAt"' "$B/$f") > /dev/null; then
            printf '  %-20s identical (createdAt ignored)\n' "$f"
        else
            printf '  %-20s **DIFFERS**\n' "$f"
            FAILED=1
        fi
    elif [ -f "$A/$f" ]; then
        printf '  %-20s in A only  <-- the headless output did not carry it forward\n' "$f"
        FAILED=1
    elif [ -f "$B/$f" ]; then
        printf '  %-20s in B only\n' "$f"
        FAILED=1
    else
        printf '  %-20s (neither)\n' "$f"
    fi
done
echo

# ------------------------------------------------------------------- the log
# The header names the package, so it is expected to differ. Every result line
# is not — and `sme` is the one that used to drift before the seeding fix.
echo "=== log_eva (timestamps and header stripped) ==="
LOG_A=$(ls "$A"/log_eva_*.txt 2>/dev/null | head -1)
LOG_B=$(ls "$B"/log_eva_*.txt 2>/dev/null | head -1)
if [ -n "$LOG_A" ] && [ -n "$LOG_B" ]; then
    if diff <(sed -E 's/^\[[^]]*\] //; /^EVA .* export —/d' "$LOG_A") \
            <(sed -E 's/^\[[^]]*\] //; /^EVA .* export —/d' "$LOG_B") > /tmp/log-diff.$$ 2>&1; then
        echo "  identical apart from the header"
    else
        echo "  **DIFFERS**"
        sed 's/^/    /' /tmp/log-diff.$$
        FAILED=1
    fi
    rm -f /tmp/log-diff.$$
else
    echo "  missing a log in one or both packages"
    FAILED=1
fi
echo

# ------------------------------------------------- expected, reported as notes
echo "=== expected differences (not failures) ==="
if ! cmp -s "$A/subject.xml" "$B/subject.xml" 2>/dev/null; then
    echo "  subject.xml — Patient ID is seeded from the package name (MFFWriter)"
fi
echo "  eva.xml writtenAt / appliedAt, log header, sidecar createdAt"
echo

if [ "$FAILED" -eq 0 ]; then
    echo "PASS — everything that must match does."
else
    echo "FAIL — see the marked sections above."
fi
exit "$FAILED"
