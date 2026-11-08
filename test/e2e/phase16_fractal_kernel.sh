#!/usr/bin/env bash
# e2e-process-boundary: rebuilds Zig wasm artifacts and compares compiler output
# Layer 2 correctness gate, not a performance gate: no timing thresholds.
# Committed artifacts must reproduce golden.edn's :ci views on every engine.
# Every exact header recipe must reproduce its committed file byte-for-byte.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${CLJW_BIN:-zig-out/bin/cljw}"
fail() { echo "FAIL fractal-kernel: $1" >&2; exit 1; }
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else fail "timeout or gtimeout is required"; fi
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

# Run in a scratch repo-shaped tree holding only the cljw half of the demo.
mkdir -p "$scratch/docs/examples/fractal/cljw"
cp "$DEMO/bench.clj" "$DEMO/mandel.clj" "$DEMO/golden.edn" \
   "$DEMO/kernel.zig" "$DEMO/kernel.c" "$DEMO/kernel.rs" \
   "$DEMO/kernel.wasm" "$DEMO/kernel_simd.wasm" "$DEMO/kernel_c.wasm" "$DEMO/kernel_rust.wasm" \
   "$scratch/docs/examples/fractal/"
cp "$DEMO"/cljw/*.clj "$scratch/docs/examples/fractal/cljw/"
out="$(cd "$scratch" && CLJW_FRACTAL_CI=1 run_bounded 60 "$BIN" docs/examples/fractal/bench.clj 2>&1)" \
  || fail "committed artifacts do not reproduce golden.edn:
$out"
# The :ci golden views (odd-tail, tip) on 8 engines: Zig, C and Rust on zwasm
# jit and interp, Zig simd128 on jit, plain Clojure. Every frame is golden.
grep -qF "PASS golden: 16 frames on 8 engines reproduce golden.edn" <<<"$out" \
  || fail "missing golden pass marker:
$out"
[ "$(grep -c '^frame .* golden$' <<<"$out")" -eq 16 ] || fail "expected 16 golden frames:
$out"
echo "PASS fractal-kernel-committed -> 16 golden frames on 8 engines"

# Rebuild from the header recipes, spelled out like phase16_zig_native.sh.
# Scratch is repo-shaped so the source and output paths match the header.
rm "$scratch/docs/examples/fractal/kernel.wasm" "$scratch/docs/examples/fractal/kernel_simd.wasm" \
   "$scratch/docs/examples/fractal/kernel_c.wasm"
(cd "$scratch" && run_bounded 90 zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel.wasm) \
  || fail "scalar header recipe failed"
(cd "$scratch" && run_bounded 90 zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel_simd.wasm) \
  || fail "SIMD header recipe failed"
(cd "$scratch" && run_bounded 90 zig cc -target wasm32-freestanding -O3 -nostdlib -fno-builtin -Wl,--no-entry -Wl,--strip-all -o docs/examples/fractal/kernel_c.wasm docs/examples/fractal/kernel.c) \
  || fail "C header recipe failed"
for artifact in kernel.wasm kernel_simd.wasm kernel_c.wasm; do
  cmp -s "$DEMO/$artifact" "$scratch/docs/examples/fractal/$artifact" \
    || fail "$artifact differs from exact header recipe output"
done
echo "PASS fractal-kernel-rebuilt -> Zig scalar, Zig simd128 and C artifacts byte-identical to committed files"

# Rust needs rustup's wasm32-unknown-unknown target; CI images may lack it.
if command -v rustc >/dev/null 2>&1 && rustc --print sysroot >/dev/null 2>&1 \
   && [ -d "$(rustc --print sysroot)/lib/rustlib/wasm32-unknown-unknown" ]; then
  rm "$scratch/docs/examples/fractal/kernel_rust.wasm"
  (cd "$scratch" && run_bounded 120 rustc --edition 2021 --crate-type=cdylib --target wasm32-unknown-unknown -C opt-level=3 -C panic=abort -C strip=symbols -o docs/examples/fractal/kernel_rust.wasm docs/examples/fractal/kernel.rs) \
    || fail "Rust header recipe failed"
  cmp -s "$DEMO/kernel_rust.wasm" "$scratch/docs/examples/fractal/kernel_rust.wasm" \
    || fail "kernel_rust.wasm differs from exact header recipe output"
  echo "PASS fractal-kernel-rust-rebuilt -> byte-identical to committed file"
else
  echo "SKIP fractal-kernel-rust-rebuilt: rustc wasm32-unknown-unknown target not installed"
fi
