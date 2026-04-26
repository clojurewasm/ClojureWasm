#!/usr/bin/env bash
# bench/quick.sh
#
# Phase-1 baseline harness. The full bench/ machinery (bench.sh / record /
# compare / suite/NN_*) lands at Phase 8 per ROADMAP §10.1. Until then
# `quick.sh` runs whatever can be measured against the Phase-1 binary so
# we have a rough baseline to detect regressions during Phases 2–7.
#
# What we measure now (Phase 1, no evaluator):
#   1. Binary size (ReleaseFast, stripped).
#   2. Cold start latency: `cljw` (smoke output).
#   3. Read throughput: round-trip of a hand-written 100-form expression.
#   4. -e "(+ 1 2)" round-trip latency (Phase-1 exit criterion path).
#
# The hot benchmarks named in §9.3 task 1.11 (fib, arith_loop, list_build,
# map_filter_reduce, transduce, lazy_chain) need eval — they become live
# at Phase 4 (TreeWalk) / Phase 7 (transducers) and will be replayed
# through the same script. Lines marked `# TODO(phase4)` are the
# placeholders.
#
# Output: results land in bench/quick_baseline.txt as a "phase, metric,
# value" table. History grows by appending; do not edit existing rows.

set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE="bench/quick_baseline.txt"
PHASE="${PHASE_NAME:-phase1}"

# repeatable timestamp so reproducibility is obvious in diffs
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> 1. Build (ReleaseFast)"
zig build -Doptimize=ReleaseFast >/dev/null
BIN="zig-out/bin/cljw"
test -x "$BIN" || { echo "binary missing: $BIN"; exit 1; }

# Binary size in bytes (stat is BSD/macOS variant on Darwin, GNU on Linux).
if size_bytes=$(stat -f '%z' "$BIN" 2>/dev/null); then :; else size_bytes=$(stat -c '%s' "$BIN"); fi
echo "    binary_size_bytes = $size_bytes"

# --- timed measurements ---

# `time` output isn't portable across shells; use a Zig-style monotonic
# wallclock instead. Bash's built-in $EPOCHREALTIME is bash 5+; macOS
# defaults to 3.2, so fall back to python3 when missing.
now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        # Strip the dot, keep ms resolution. EPOCHREALTIME = "<sec>.<usec>".
        local er="${EPOCHREALTIME//./}"
        echo "${er:0:-3}"  # drop the last 3 digits (us → ms)
    else
        python3 -c "import time; print(int(time.time() * 1000))"
    fi
}

bench_run() {
    local label="$1"; shift
    local iters="${ITERS:-50}"
    local start end elapsed_ms
    start=$(now_ms)
    for ((i = 0; i < iters; i++)); do
        "$@" >/dev/null
    done
    end=$(now_ms)
    elapsed_ms=$((end - start))
    local per_run_us=$(( (elapsed_ms * 1000) / iters ))
    echo "    $label = ${per_run_us} us/run (n=$iters)"
    printf '%s\t%s\t%s\t%s\n' "$NOW" "$PHASE" "$label" "$per_run_us" >> "$BASELINE"
}

echo "==> 2. Cold start (no-args)"
bench_run cold_start_us "$BIN"

echo "==> 3. -e \"(+ 1 2)\" round-trip"
bench_run e_plus_round_trip_us "$BIN" -e "(+ 1 2)"

echo "==> 4. Read 100-form expression"
# `yes | head` would SIGPIPE under set -e + pipefail, so build the
# 100-form expression with a plain printf loop instead.
LONG=""
for ((i = 0; i < 100; i++)); do LONG+="(+ 1 2 3 4 5) "; done
bench_run read_100_forms_us "$BIN" -e "$LONG"

# --- record metadata ---
{
    if [[ ! -s "$BASELINE" ]]; then
        printf '# bench/quick_baseline.txt — Phase-1 baselines.\n'
        printf '# Columns: timestamp\tphase\tmetric\tvalue\n'
    fi
    printf '%s\t%s\t%s\t%s\n' "$NOW" "$PHASE" "binary_size_bytes" "$size_bytes"
} >> "$BASELINE"

# TODO(phase4): once TreeWalk lands, append rows for:
#   fib_recursive_us, arith_loop_us, list_build_us
# TODO(phase7): once transducers land:
#   map_filter_reduce_us, transduce_us, lazy_chain_us

echo
echo "Baseline rows appended to $BASELINE"
