#!/usr/bin/env bash
# test/e2e/phase16_wasm_memory.sh — the (ptr,len) linear-memory surface
# (ADR-0192). `wasm/call` marshals scalars, which reaches every guest whose
# whole interface fits in numbers; a numeric guest's does not. This asserts the
# host can fill the buffer a guest's pointer argument names and read what the
# guest wrote back, that every element type round-trips through the wasm memory
# model (little-endian, unaligned-tolerant, i64 exact past the i48 window), and
# that every failure is a catchable exception rather than a host panic.
#
# OPT-IN for the same reason as phase16_wasm_ffi.sh: it builds `-Dwasm`, so it
# resolves zwasm, which the default gate never does (F-001).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

FIX="test/e2e/fixtures/wasm_memory_probe.clj"
out="$("$BIN" "$FIX" 2>&1)" || fail "cljw exited non-zero running $FIX:
$out"

want() {
  grep -qF "$1" <<<"$out" || fail "expected '$1' in the probe output, got:
$out"
}

# (1) The size is in BYTES (one 64 KiB page), not in pages.
want "size 65536"

# (2) Round trip through the guest. The host writes 4 doubles; the guest sums
#     them (10.0); the guest scales them in place and reports the new sum
#     (25.0); the host reads back what the guest wrote. Every one of those four
#     numbers is impossible without the memory surface.
want "wrote 4"
want "sum 10.0"
want "newsum 25.0"
want "scaled [2.5 5.0 7.5 10.0]"
echo "PASS wasm-memory-roundtrip -> guest read the host's buffer and wrote it back"

# (3) The bytes are the wasm memory model's: f64 1.5 little-endian.
want "as-u8 [0 0 0 0 0 0 248 63]"

# (4) i64 past the i48 immediate window survives EXACTLY. 2^53+1 is not
#     representable as an f64, so an equal round trip proves the value did not
#     pass through a float (which `Value.initInteger` alone would have done).
want "i64 [9007199254740993 -1]"
want "i64-exact true"
echo "PASS wasm-memory-i64-exact -> 2^53+1 round-trips without a float"

# (5) Unsigned and signed read the same bytes differently; unaligned works.
want "u32 [4294967295] i32 [-1]"
want "unaligned [7.25]"
echo "PASS wasm-memory-dtypes -> signedness + unaligned access"

# (5b) Primitive arrays cross in bulk (ADR-0204), every array kind through
#      its dtype, unsigned widening, and a cross-kind element-wise convert.
want "arr-wrote 4"
want "arr-newsum 20.0"
want "arr-f64 [2.0 4.0 6.0 8.0] true"
for dt in i8 i16 i32 i64 f32 f64; do want "arr-rt :$dt true"; done
want "arr-unsigned [65535] [4294967295]"
want "arr-convert [5.0 6.0]"
want "arr-object wasm/mem-write!: the data argument must be a vector of numbers"
want "arr-range wasm/mem-write!: element 1 is outside this element type's range"
want "arr-oob wasm/mem-read-array: 1 element(s) at byte offset 65530"
echo "PASS wasm-memory-arrays -> primitive arrays cross as one memcpy per kind"

# (6) Every failure is CATCHABLE and names the fn the user wrote. A NOT-CAUGHT
#     means the error escaped (catch …); an uncatchable one would have exited
#     70 above and never reached here.
grep -q "NOT-CAUGHT" <<<"$out" && fail "a wasm/mem-* error was not raised or not caught:
$out"
want "no-memory wasm/mem-size: this module exports no linear memory"
want "bad-handle wasm/mem-size: the first argument must be a loaded wasm module"
want "bad-dtype wasm/mem-read: the element type must be one of"
want "bad-index wasm/mem-read: the byte offset and the element count must both be integers"
want "oob wasm/mem-read: 1 element(s) at byte offset 65530"
want "negative wasm/mem-read: 1 element(s) at byte offset -8"
want "overflow wasm/mem-read: 9223372036854775807 element(s)"
want "bad-data wasm/mem-write!: the data argument must be a vector of numbers"
want "bad-element wasm/mem-write!: element 1 is not a number"
want "element-range wasm/mem-write!: element 1 is outside this element type's range"
want "element-fraction wasm/mem-write!: element 0 is not an integer"
echo "PASS wasm-memory-catchable -> negative offset / overflow / bad element all raise, none panic"

grep -q "^DONE$" <<<"$out" || fail "the probe did not run to completion:
$out"

echo
echo "Phase 16 / wasm linear memory (ADR-0192): all green."
