#!/usr/bin/env bash
# test/e2e/phase14_cold_start_threshold.sh
#
# Phase 14 §9.16 row 14.11 — D-100 (d) cold-start bench < 12 ms
# verification per ROADMAP §9 master table row 12 deliverable. The
# threshold is the v0.1.0 release commitment: a ReleaseFast cljw
# binary on a reasonable laptop class (Mac M-series / Linux x86_64
# medium-spec) must reach `(println ...)`-ready state in under 12 ms.
#
# Defers measurement to `bench/quick.sh`'s in-process internal
# `EPOCHREALTIME` timer — bash-driven external timing adds ~15ms of
# fork/exec/shell overhead and would over-report. The bench harness
# already measures n=50 samples + reports the median; we parse that
# value and assert against the threshold.

set -euo pipefail
cd "$(dirname "$0")/../.."

THRESHOLD_US=12000

fail() { echo "FAIL $1" >&2; exit 1; }

# Run the bench. Side-effect: appends a row to bench/quick_baseline.txt
# (which is committed alongside source-bearing changes per
# `.claude/rules/bench_baseline.md`).
out=$(PHASE_NAME=phase14_cs bash bench/quick.sh 2>&1)
cold_start_us=$(echo "$out" | grep -oE 'cold_start_us = [0-9]+' | grep -oE '[0-9]+' | head -n 1)

if [[ -z "$cold_start_us" ]]; then
    echo "$out" | head -20
    fail "cold_start_threshold: bench output did not contain a cold_start_us value"
fi

echo "cold_start_us=$cold_start_us (n=50; threshold=$THRESHOLD_US)"

if [[ "$cold_start_us" -lt "$THRESHOLD_US" ]]; then
    echo "PASS cold_start_threshold_under_${THRESHOLD_US}us -> ${cold_start_us}us"
else
    fail "cold_start_threshold: cold_start_us=${cold_start_us}us >= ${THRESHOLD_US}us (v0.1.0 release commitment)"
fi

echo
echo "Phase 14 row 14.11 (D-100d) cold-start threshold: PASS"
