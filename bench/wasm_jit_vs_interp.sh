#!/usr/bin/env bash
# bench/wasm_jit_vs_interp.sh — reproducible JIT-vs-interp demonstration (zwasm ADR-0200
# adoption; ROADMAP §9.0 gap area III VM-perf). Runs the SAME compute-heavy wasm
# module (bench/fixtures/sumto.wasm — a 100M-iteration i32 tight loop) through
# cljw's zwasm embedding under `:engine :jit` and `:engine :interp`, and prints the
# wall-clock for each plus the speedup ratio. This is the north-star rationale made
# concrete: the JIT is dramatically faster than the interpreter on a tight loop.
#
# ON-DEMAND ONLY (Layer 4 bench, not a gate step; no pass/fail threshold — perf is
# machine-dependent). Requires a `-Dwasm` ReleaseSafe binary + the relative-path
# zwasm tree (the JIT experiment, see .dev/zwasm_capabilities.md). Run:
#   bash bench/wasm_jit_vs_interp.sh [N]      # N = iteration count (default 100000000)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/../scripts/lib_build_lock.sh"
source "$(dirname "$0")/../scripts/lib_cljw_bin.sh"
BIN="zig-out/bin/cljw"
N="${1:-100000000}"
WASM="bench/fixtures/sumto.wasm"

cljw_bin_require "$BIN" wasm_jit_vs_interp
"$BIN" --version | grep -q wasm || { echo "cljw is not wasm-enabled ($("$BIN" --version))" >&2; exit 1; }

# :fuel 0 = unmetered (trusted module; a 1e8-iteration loop would exhaust the finite
# default fuel). Both engines wrap i32 identically, so the printed result matches.
run() { printf '(wasm/call (wasm/load "%s" {:engine :%s :fuel 0}) "sumto" %s)\n' "$WASM" "$1" "$N" | "$BIN" - >/dev/null; }

# time(1) in a subshell; capture the real-seconds via the shell builtin TIMEFORMAT.
timeit() {
  local engine="$1" t
  t=$( { TIMEFORMAT='%R'; time run "$engine"; } 2>&1 )
  echo "$t"
}

echo "JIT-vs-interp on sumto($N), unmetered fuel:"
jit=$(timeit jit)
interp=$(timeit interp)
echo "  :jit    ${jit}s"
echo "  :interp ${interp}s"
# Ratio via awk (bash has no float division).
awk -v j="$jit" -v i="$interp" 'BEGIN { if (j>0) printf "  speedup  %.1fx (interp/jit, end-to-end incl. ~12ms startup)\n", i/j }'
