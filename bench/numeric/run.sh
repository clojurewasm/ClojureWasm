#!/usr/bin/env bash
# bench/numeric/run.sh: best-of-N wall time for the CLJW-PERF-NUMERIC-UNBOX
# probes (fib30.clj, loop10m.clj, startup.clj) on cljw, bb and jolt.
#
# Usage: bash bench/numeric/run.sh [CLJW_BIN] [N]
#   CLJW_BIN  an optimised cljw (ReleaseSafe or ReleaseFast); never the Debug
#             zig-out/bin/cljw (perf_measure_release rule).
#   N         runs per (runtime, program); the minimum is reported. Default 5.
set -euo pipefail
cd "$(dirname "$0")"
CLJW="${1:?usage: run.sh CLJW_BIN [N]}"
N="${2:-5}"

best_ms() {
    local best=""
    for _i in $(seq 1 "$N"); do
        local t0 t1 ms
        t0=$(date +%s%N)
        "$@" >/dev/null
        t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        if [[ -z "$best" || "$ms" -lt "$best" ]]; then best="$ms"; fi
    done
    echo "$best"
}

printf '%-12s %8s %8s %8s\n' program cljw bb jolt
for p in startup fib30 loop10m; do
    c=$(best_ms "$CLJW" "$p.clj")
    b=$(best_ms bb "$p.clj")
    j=$(best_ms jolt "$p.clj")
    printf '%-12s %8s %8s %8s\n' "$p" "$c" "$b" "$j"
done
