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

# Portable bounded run: GNU `timeout`, else coreutils `gtimeout`, else
# unbounded (hosted mac runners ship neither). The D-347 case relies on this as
# a backstop only — a green run trips the guest's own fuel trap long before it.
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

# Honor the gate's shared-binary contract (CLJW_SKIP_BUILD): skip our own build
# to avoid clobbering the shared binary mid-run. Standalone, build -Dwasm
# ReleaseSafe (NOT bare -Dwasm = Debug; ADR-0132). zwasm resolves via the
# build.zig.zon tag-pin (no sibling dir), so this runs on ubuntunote too
# (F-001 amended 2026-06-12).
if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

out="$("$BIN" test/e2e/fixtures/wasm_run_probe.clj 2>&1)" || fail "cljw exited non-zero:
$out"

grep -q "PASS wasm-run-basic" <<<"$out" || fail "argv/stdin/stdout/stderr capture failed:
$out"
grep -q "PASS wasm-run-exit-code" <<<"$out" || fail "non-zero exit not returned as data:
$out"
grep -q "PASS wasm-run-env" <<<"$out" || fail "the :env option (D-348) failed to parse/run:
$out"
grep -q "PASS wasm-run-cache$" <<<"$out" || fail "a cached wasm/run differed from an uncached one (D-350):
$out"
grep -q "PASS wasm-run-cache-fuel" <<<"$out" || fail "fuel did not apply to a cached module (D-350):
$out"
grep -q "cache-bad-type: CAUGHT" <<<"$out" || fail "a non-boolean :cache was not rejected (D-350):
$out"
grep -q "NOT-CAUGHT" <<<"$out" && fail "a wasm/run error escaped (catch …):
$out"
grep -q "^DONE$" <<<"$out" || fail "fixture did not run to completion:
$out"

# D-347 (SE): (wasm/run …) must be fuel-metered BY DEFAULT, like (wasm/load …).
# Before the fix the C-API run path got a `.{}` Limits whose axes all default to
# null = unmetered, so an infinite loop in an untrusted guest hung the host
# forever while the same loop under wasm/load was fuel-trapped. The bound here
# is the assertion: a spinning guest must come back, and quickly.
start=$(date +%s)
out="$(run_bounded 60 "$BIN" -e '(println :exit (:exit (wasm/run "test/e2e/fixtures/wasm_spin.wasm")))' 2>&1 || true)"
elapsed=$(( $(date +%s) - start ))
grep -q ":exit 1" <<<"$out" || fail "an infinite-loop guest was not fuel-trapped (D-347) after ${elapsed}s:
$out"
[[ "$elapsed" -lt 45 ]] || fail "fuel trap took ${elapsed}s — the default budget is not being applied (D-347)"
echo "PASS wasm-run-fuel-metered-by-default -> trapped in ${elapsed}s"

echo
echo "Phase 16 / wasm/run WASI command smoke: all green."
