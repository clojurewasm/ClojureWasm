#!/usr/bin/env bash
# e2e-process-boundary: runs the zig toolchain to rebuild the example's wasm and shared library, which cljw cannot spawn
# test/e2e/phase16_zig_native.sh: docs/examples/zig-native is a gated claim.
# Two legs:
#
#   1. The COMMITTED kernel.wasm: zig_native.clj must print PASS zig-wasm and,
#      with no shared library present, SKIP zig-native.
#   2. The BUILD RECIPES from kernel.zig's header, in a scratch copy: rebuild
#      kernel.wasm and the shared library (zig is always here, it builds cljw),
#      then both legs must PASS.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved? check the build.zig.zon pin)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version))"
ABS_BIN="$(pwd)/$BIN"
DEMO="$(pwd)/docs/examples/zig-native"

run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

expect() {  # $1 dir  $2.. required markers
  local dir="$1" out; shift
  out="$(cd "$dir" && run_bounded 60 "$ABS_BIN" zig_native.clj 2>&1)" \
    || fail "zig_native.clj exited non-zero in $dir:
$out"
  for marker in "$@" DONE; do
    grep -q "^$marker" <<<"$out" || fail "missing '$marker' in $dir:
$out"
  done
}

# --- leg 1: the committed wasm, no native library -------------------------
[ ! -e "$DEMO/libkernel.so" ] && [ ! -e "$DEMO/libkernel.dylib" ] \
  || fail "a built libkernel is checked in under docs/examples/zig-native"
expect "$DEMO" "PASS zig-wasm" "SKIP zig-native"
echo "PASS zig-native-committed -> wasm"

# --- leg 2: both builds from the recipe, in a scratch copy ----------------
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_zig_native_XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cp -R "$DEMO/." "$scratch/"
rm -f "$scratch/kernel.wasm"
(cd "$scratch" && zig build-exe kernel.zig -target wasm32-freestanding -O ReleaseSmall \
   -fno-entry -rdynamic -femit-bin=kernel.wasm) || fail "the wasm build recipe failed"
(cd "$scratch" && zig build-lib -dynamic -O ReleaseFast kernel.zig) \
  || fail "the native build recipe failed"
expect "$scratch" "PASS zig-wasm" "PASS zig-native"
echo "PASS zig-native-rebuilt -> wasm, native"
