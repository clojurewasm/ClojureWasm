#!/usr/bin/env bash
# test/e2e/phase16_wasm_run.sh — (wasm/run …) WASI command smoke (ADR-0124).
# Builds the `-Dwasm` binary, runs a Rust wasm32-wasip1 command via wasm/run, and
# asserts captured stdout/stderr, the exit code returned as DATA (not raised), and
# that every failure path stays a catchable cljw exception (no exit-70 crash).
#
# OPT-IN, like phase16_wasm_ffi.sh: it builds `-Dwasm` (so it resolves the
# relative-path zwasm tree) and is therefore NOT in the default per-commit gate's
# step list. Run it explicitly for wasm-surface changes.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ ! -d "../zwasm_from_scratch" ]; then
  echo "SKIP phase16_wasm_run (../zwasm_from_scratch not present)"
  exit 0
fi
# Honor the wasm-gate's shared-binary contract (CLJW_SKIP_BUILD): skip our own
# build to avoid clobbering the shared binary mid-run. Standalone, build it
# ReleaseSafe (NOT a bare -Dwasm = Debug; ADR-0132).
if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm relative-path consume broken?)"
fi

out="$("$BIN" test/e2e/fixtures/wasm_run_probe.clj 2>&1)" || fail "cljw exited non-zero:
$out"

echo "$out" | grep -q "PASS wasm-run-basic" || fail "argv/stdin/stdout/stderr capture failed:
$out"
echo "$out" | grep -q "PASS wasm-run-exit-code" || fail "non-zero exit not returned as data:
$out"
echo "$out" | grep -q "NOT-CAUGHT" && fail "a wasm/run error escaped (catch …):
$out"
echo "$out" | grep -q "^DONE$" || fail "fixture did not run to completion:
$out"

echo
echo "Phase 16 / wasm/run WASI command smoke: all green."
