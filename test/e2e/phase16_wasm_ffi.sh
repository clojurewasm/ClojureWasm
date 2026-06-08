#!/usr/bin/env bash
# test/e2e/phase16_wasm_ffi.sh — polyglot Wasm FFI smoke + leak guard (ADR-0099,
# D-259 (b)). Builds the `-Dwasm` binary (which resolves zwasm via the relative-
# path build.zig.zon), loads a Zig→Wasm module, calls an export, and asserts BOTH
# the correct result AND that the DebugAllocator reports NO leak on exit — i.e. the
# `.wasm_module` GC finaliser tears down the zwasm triple instead of leaking.
#
# This is the wasm-FFI regression guard the default gate otherwise lacks. It is
# OPT-IN: it builds `-Dwasm` itself (so it does pull in zwasm), which is why it is
# NOT in the default per-commit gate's step list — run it explicitly
# (`bash test/e2e/phase16_wasm_ffi.sh`) or in the wasm-aware gate. Keeping it out
# of the default run_all step list preserves F-001 (the default gate never
# resolves zwasm); this script opts into the relative-path zwasm tree on purpose.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

# Build the -Dwasm binary (resolves ../zwasm_from_scratch). Skip cleanly if the
# zwasm tree is absent (e.g. CI without the sibling checkout).
if [ ! -d "../zwasm_from_scratch" ]; then
  echo "SKIP phase16_wasm_ffi (../zwasm_from_scratch not present)"
  exit 0
fi
if ! zig build -Dwasm >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm relative-path consume broken?)"
fi

FIX="test/e2e/fixtures/wasm_ffi_smoke.clj"

# Run + capture combined output. ReleaseSafe/Debug DebugAllocator prints
# "...leaked:" lines on exit for any unfreed allocation; a clean run prints none.
out="$("$BIN" "$FIX" 2>&1)" || fail "cljw exited non-zero running $FIX:
$out"

# (1) Functional: the Zig->Wasm add export returns 42.
echo "$out" | grep -q "add(2,40) = 42" || fail "wasm add export: expected 'add(2,40) = 42', got:
$out"
echo "PASS wasm-ffi-add -> 42"

# (2) Leak guard (D-259 (b)): no DebugAllocator leak on exit — the .wasm_module
# finaliser freed the *Loaded box + tore down the zwasm triple.
leaks="$(echo "$out" | grep -c "leaked" || true)"
[ "$leaks" -eq 0 ] || fail "wasm handle leaked ($leaks leak line(s)) — .wasm_module finaliser not freeing:
$out"
echo "PASS wasm-ffi-no-leak -> 0 leaks"

# (3) FIX-4 catchability: every wasm-surface error is a catchable cljw exception
# (NOT an internal_error / exit 70). The fixture wraps each failing wasm/load +
# wasm/call in a (catch …); if any error were uncatchable the process would exit
# 70 here (non-zero), and a mismatched Kind would print NOT-CAUGHT.
catch_out="$("$BIN" test/e2e/fixtures/wasm_ffi_catch.clj 2>&1)" || fail "catchability fixture exited non-zero (an error escaped (catch …) → exit 70):
$catch_out"
echo "$catch_out" | grep -q "NOT-CAUGHT" && fail "a wasm error was not caught (or matched the wrong host class):
$catch_out"
echo "$catch_out" | grep -q "^DONE$" || fail "catchability fixture did not run to completion:
$catch_out"
echo "PASS wasm-ffi-catchable -> all errors caught, exit 0"

echo
echo "Phase 16 / wasm FFI smoke + leak guard + catchability: all green."
