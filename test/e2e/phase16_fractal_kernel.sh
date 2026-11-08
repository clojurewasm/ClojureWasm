#!/usr/bin/env bash
# e2e-process-boundary: rebuilds Zig wasm artifacts and compares compiler output
# Layer 2 correctness gate, not a performance gate: no timing thresholds.
# Committed artifacts must pass bench.clj's small parity cases across engines.
# Both exact header recipes must reproduce the committed files byte-for-byte.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${CLJW_BIN:-zig-out/bin/cljw}"
fail() { echo "FAIL fractal-kernel: $1" >&2; exit 1; }
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# The harness owns building cljw. Never silently rebuild a non-wasm binary.
version="$(run_bounded 10 "$BIN" --version)" || fail "cannot query $BIN"
if ! grep -q wasm <<<"$version"; then
  echo "SKIP fractal-kernel: cljw was built without -Dwasm ($version)"
  exit 0
fi
case "$BIN" in /*) ;; *) BIN="$(pwd)/$BIN" ;; esac
DEMO="$(pwd)/docs/examples/fractal"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_fractal_XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Run in a scratch repo-shaped tree, so CI never overwrites the human PPM.
mkdir -p "$scratch/docs/examples/fractal"
cp "$DEMO/bench.clj" "$DEMO/kernel.zig" "$DEMO/kernel.wasm" "$DEMO/kernel_simd.wasm" \
   "$scratch/docs/examples/fractal/"
out="$(cd "$scratch" && CLJW_FRACTAL_CI=1 run_bounded 60 "$BIN" docs/examples/fractal/bench.clj 2>&1)" \
  || fail "committed artifact parity failed:
$out"
for marker in "PASS scalar artifact: strict engine and vector-source parity" \
              "PASS simd128 JIT strict parity"; do
  grep -qF "$marker" <<<"$out" || fail "missing $marker:
$out"
done
# CI selects reduced views only, with exactly 18 frame comparisons.
[ "$(grep -c '^:.* checksum ' <<<"$out")" -eq 18 ] || fail "expected 18 parity frames:
$out"
echo "PASS fractal-kernel-committed -> 18 frames, scalar JIT/interp and simd128 JIT parity"

# Rebuild from the header recipes, spelled out like phase16_zig_native.sh.
# Scratch is repo-shaped so the source and output paths match the header.
rm "$scratch/docs/examples/fractal/kernel.wasm" "$scratch/docs/examples/fractal/kernel_simd.wasm"
(cd "$scratch" && run_bounded 90 zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel.wasm) \
  || fail "scalar header recipe failed"
(cd "$scratch" && run_bounded 90 zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel_simd.wasm) \
  || fail "SIMD header recipe failed"
for artifact in kernel.wasm kernel_simd.wasm; do
  cmp -s "$DEMO/$artifact" "$scratch/docs/examples/fractal/$artifact" \
    || fail "$artifact differs from exact header recipe output"
done
echo "PASS fractal-kernel-rebuilt -> both artifacts byte-identical to committed files"
