#!/usr/bin/env bash
# test/e2e/phase16_wasm_engine_select.sh — zwasm ADR-0200 JIT-engine adoption smoke.
# Exercises per-instance engine selection at the cljw surface:
# `(wasm/load path {:engine :jit/:interp})` + `wasm/call`. Asserts the GPR export
# is byte-identical jit==interp (the F-012 differential discipline applied to engine
# choice), the SIMD body runs on the JIT (end-to-end through exportFuncSig, the JIT
# arm zwasm shipped @5b6449779 / from_cljw_02), the SIMD body traps catchably on
# interp (SIMD is JIT-only — to_cljw_03), and the no-opts default rides :auto = JIT
# (D-488 flipped 2026-06-22; zwasm v2.0.0-alpha.3 re-landed .auto→JIT — a SIMD body
# only the JIT can run returns 42 under the no-opts default).
#
# Like phase16_wasm_ffi.sh this is OPT-IN: it builds/uses the `-Dwasm` binary (which
# resolves zwasm via the relative-path build.zig.zon experiment), so it is NOT in the
# default per-commit gate's step list while F-001 keeps the default gate zwasm-free.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

# Honor the gate's shared-binary contract (CLJW_SKIP_BUILD); standalone build
# -Dwasm ReleaseSafe (NOT bare -Dwasm = Debug, ADR-0132).
if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

out="$("$BIN" test/e2e/fixtures/wasm/jit_engine_select.clj 2>&1)" || fail "fixture exited non-zero:
$out"

# (1) GPR export byte-identical across engines (dual-engine diff oracle).
grep -q "add-jit: 5" <<<"$out" || fail "add on :jit != 5:
$out"
grep -q "add-interp: 5" <<<"$out" || fail "add on :interp != 5:
$out"

# (2) SIMD body executes JIT-compiled → 42 (end-to-end via wasm/call/exportFuncSig).
grep -q "lane0-jit: 42" <<<"$out" || fail "SIMD lane0 on :jit != 42 (exportFuncSig JIT arm missing?):
$out"

# (3) SIMD body traps a CATCHABLE error on :interp (SIMD is JIT-only in zwasm).
grep -q "lane0-interp: TRAPPED" <<<"$out" || fail "SIMD lane0 on :interp did not trap catchably:
$out"

# (4) no-opts default rides :auto = JIT (D-488). GPR add works AND a SIMD body —
# which only the JIT can execute — returns 42 with no :engine opt (an interp default
# would TRAP, so default-simd: 42 is the proof the default flipped to JIT-first).
grep -q "default: 5" <<<"$out" || fail "no-opts default wasm/call broke:
$out"
grep -q "default-simd: 42" <<<"$out" || fail "no-opts default did NOT ride JIT (SIMD body should run under .auto=JIT default; interp would trap):
$out"

# (5) Multi-value (>1 scalar) result marshals to a cljw vector, identical jit==interp.
grep -q "divmod-jit: \[3 2\]" <<<"$out" || fail "multi-value divmod on :jit != [3 2]:
$out"
grep -q "divmod-interp: \[3 2\]" <<<"$out" || fail "multi-value divmod on :interp != [3 2]:
$out"

# (6) 2-arg f64 FP-bank is byte-identical jit==interp (zwasm @d7da97e04 fixed the
# 2-arg×FP-bank JIT dispatch — from_cljw_03 repro → to_cljw_04).
grep -q "addf-interp: 3.75" <<<"$out" || fail "f64 addf on :interp != 3.75:
$out"
grep -q "addf-jit: 3.75" <<<"$out" || fail "f64 addf on :jit != 3.75 (regressed? zwasm 2-arg×FP dispatch was fixed @d7da97e04):
$out"

# (6b) Mixed-bank 2-arg (i32,f64)→f64 byte-identical jit==interp (1/2-arg matrix
# completed @3cf40a573 — veneer falls through to the generic buffer thunk).
grep -q "mix-jit: 5.5" <<<"$out" || fail "mixed (i32,f64)->f64 on :jit != 5.5 (zwasm 1/2-arg matrix @3cf40a573):
$out"
grep -q "mix-interp: 5.5" <<<"$out" || fail "mixed (i32,f64)->f64 on :interp != 5.5:
$out"

# (6c) 3-arg FP via the generic buffer path (f64,f64,f64)->f64 byte-identical jit==interp.
grep -q "sum3-jit: 7" <<<"$out" || fail "3-arg (f64,f64,f64)->f64 on :jit != 7.0:
$out"
grep -q "sum3-interp: 7" <<<"$out" || fail "3-arg (f64,f64,f64)->f64 on :interp != 7.0:
$out"

# (7) Real SIMD arithmetic on the JIT: i32x4.mul → horizontal sum = 70.
grep -q "simd-dot-jit: 70" <<<"$out" || fail "SIMD i32x4.mul kernel on :jit != 70:
$out"

# (8) ADR-0196: engine truth at the surface. `wasm/engine` reports the selection
# a handle was loaded with, and the D-585 discriminator (a zero-result arity-4
# export) traps on the default with a message naming the export, its signature,
# the engine and the remedy, while it runs on :interp. If zwasm fixes the
# miscompile this step flips together with engine.zig's gap-lock test: delete
# the `jit_void_window` row in gaps.zig and turn the trap assertion into RAN.
grep -q "engine-jit: :jit" <<<"$out" || fail "wasm/engine on a :jit handle != :jit:
$out"
grep -q "engine-interp: :interp" <<<"$out" || fail "wasm/engine on an :interp handle != :interp:
$out"
grep -q "engine-default: :auto" <<<"$out" || fail "wasm/engine on a no-opts handle != :auto (did the default move?):
$out"
void4="$(grep '^void4-default:' <<<"$out")"
grep -qF "'gpr4_void' (i32 i32 i32 i32) -> () trapped on the auto (JIT-first) engine" <<<"$void4" || fail "void arity-4 trap on the default did not name the export, signature and engine (D-585 gap-lock flipped?):
$out"
grep -qF "load the module with {:engine :interp}" <<<"$void4" || fail "void arity-4 trap on the default did not carry the remedy:
$out"
grep -q "void4-interp: RAN" <<<"$out" || fail "void arity-4 export did not run on :interp:
$out"

grep -q "^DONE$" <<<"$out" || fail "fixture did not run to completion:
$out"

echo
echo "Phase 16 / wasm engine selection (zwasm ADR-0200 JIT adoption): all green."
