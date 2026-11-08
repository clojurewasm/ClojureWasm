#!/usr/bin/env bash
# Guard: the number of test/e2e/*.sh scripts may only go DOWN.
#
# Decision 2026-09-11 (memory 20260911144411-22d9cd94): cljw tests are deftests
# in test/clj/suites/, not new bash e2e scripts. The rule was prose only and
# was broken twice in round 5 (test/e2e/phase16_compare_comparable.sh, added
# by a ling and then edited by the coordinator; migrated in ae0d8195). This
# check freezes the count so the next new script fails the gate instead of
# relying on someone remembering the rule.
#
# A test that genuinely has to cross a process boundary (exit codes, signals,
# stdin/stdout piping of the cljw binary itself) may still be a script: put the
# marker line
#     # e2e-process-boundary: <one-line reason>
# in it and it is not counted. Every other script counts against BASELINE.
#
# When you migrate a script to a suite and the count drops, lower BASELINE in
# the same commit (the check prints the new number). Never raise it.
#
#   bash scripts/check_e2e_count.sh
#   E2E_DIR=/tmp/x bash scripts/check_e2e_count.sh   # self-test on a scratch dir
#
# bash 3.2 compatible (the macOS host runs the system bash).
set -uo pipefail

BASELINE=263

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="${E2E_DIR:-$SCRIPT_DIR/../test/e2e}"
[ -d "$E2E_DIR" ] || { echo "check_e2e_count: no $E2E_DIR" >&2; exit 1; }

n=0
exempt=0
for f in "$E2E_DIR"/*.sh; do
    [ -e "$f" ] || continue
    if grep -q '^# e2e-process-boundary:' "$f"; then
        exempt=$((exempt + 1))
    else
        n=$((n + 1))
    fi
done

if [ "$n" -gt "$BASELINE" ]; then
    echo "check_e2e_count: FAIL — $n counted test/e2e/*.sh scripts, baseline $BASELINE." >&2
    echo "  New tests are deftests in test/clj/suites/ (decision 20260911144411-22d9cd94)." >&2
    echo "  A test that must cross a process boundary takes the marker line" >&2
    echo "  '# e2e-process-boundary: <reason>' and is then not counted." >&2
    exit 1
fi

if [ "$n" -lt "$BASELINE" ]; then
    echo "check_e2e_count: ok — $n < baseline $BASELINE; lower BASELINE in scripts/check_e2e_count.sh to $n ($exempt exempt)"
    exit 0
fi

echo "check_e2e_count: ok — $n counted (baseline $BASELINE, $exempt exempt by marker)"
