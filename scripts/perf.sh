#!/usr/bin/env bash
# scripts/perf.sh — THE blessed way to measure cljw runtime speed.
#
# Builds an OPTIMISED binary (ReleaseFast by default) into a SEPARATE
# prefix, then times the expression against it. The dev binary
# `zig-out/bin/cljw` is left untouched.
#
# WHY THIS EXISTS (the principled perf guard, 2026-05-31):
#   `zig build` (no `-Doptimize`) defaults to **Debug** (fast dev
#   iteration). A Debug build of a tree-walk interpreter runs ~10-100x
#   slower than the shipped ReleaseSafe/Fast build, so timing
#   `zig-out/bin/cljw` yields MEANINGLESS perf numbers. An entire perf
#   "campaign" once chased Debug ghosts: `(count (vec (range 1e6)))`
#   read **121s in Debug** but **0.01s in ReleaseFast**; startup read
#   0.48s in Debug but ~ms in ReleaseFast (matching cw v0's ~4ms).
#   See `memory 20260909234455-390c5332 (perf_measure_release)`.
#
# RULE: measure runtime speed ONLY through this script (or the
# ReleaseFast `bench/`). NEVER `time zig-out/bin/cljw` — that is Debug.
#
# Usage:
#   bash scripts/perf.sh '(count (vec (range 1000000)))'   # 3 runs, ReleaseFast
#   bash scripts/perf.sh -n 5 '(reduce + (range 1e6))'     # 5 runs
#   bash scripts/perf.sh --file bench/fixtures/x.clj       # time a file
#   CLJW_PERF_MODE=ReleaseSafe bash scripts/perf.sh '...'  # match cw-v0's mode
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib_build_lock.sh"

MODE="${CLJW_PERF_MODE:-ReleaseFast}"
N=3
FILE=""
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -n) N="$2"; shift 2 ;;
        -f|--file) FILE="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "perf.sh: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

PREFIX="${TMPDIR:-/tmp}/cljw-perf"
echo "[perf] building $MODE into $PREFIX (dev zig-out/bin/cljw untouched)…" >&2
with_build_lock zig build -Dwasm -Doptimize="$MODE" -p "$PREFIX" >/dev/null
BIN="$PREFIX/bin/cljw"
[ -x "$BIN" ] || { echo "perf.sh: build produced no $BIN" >&2; exit 1; }
echo "[perf] $MODE binary ready; timing $N run(s):" >&2

for _i in $(seq 1 "$N"); do
    if [[ -n "$FILE" ]]; then
        /usr/bin/time -p "$BIN" "$FILE"
    else
        /usr/bin/time -p "$BIN" -e "$*"
    fi
done
