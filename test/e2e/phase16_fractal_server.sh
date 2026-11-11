#!/usr/bin/env bash
# e2e-process-boundary: docs/examples/fractal/server.clj over real HTTP.
# Starts the demo server on a fixed port, then checks the routes the page
# depends on: / (the page), /engines, /kernel.wasm?k=<id> (bytes equal to the
# committed file) and /tile on every engine (exactly w*h*4 bytes, X-Render-Ms
# and X-Iters set, identical pixels and iteration totals across engines), plus
# the 400 refusals of an unknown engine and of a formula cljw does not render.
# Serial: fixed port. Correctness only, no timing thresholds.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${CLJW_BIN:-zig-out/bin/cljw}"
fail() { echo "FAIL fractal-server: $1" >&2; exit 1; }
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}
command -v curl >/dev/null 2>&1 || { echo "SKIP fractal-server (curl unavailable)"; exit 0; }
version="$(run_bounded 10 "$BIN" --version)" || fail "cannot query $BIN"
if ! grep -q wasm <<<"$version"; then
  echo "SKIP fractal-server: cljw was built without -Dwasm ($version)"
  exit 0
fi

DEMO="docs/examples/fractal"
PORT=8159
URL="http://127.0.0.1:$PORT"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_fractal_srv_XXXXXX")"
# A backgrounded function runs in a subshell, so $! would be that subshell and
# a kill would leave the server holding the port. Exec makes $! the server's
# own bounding process.
(if command -v timeout >/dev/null 2>&1; then exec timeout 120 "$BIN" "$DEMO/server.clj" "$PORT"
 elif command -v gtimeout >/dev/null 2>&1; then exec gtimeout 120 "$BIN" "$DEMO/server.clj" "$PORT"
 else exec "$BIN" "$DEMO/server.clj" "$PORT"; fi) >"$scratch/server.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$scratch"' EXIT

up=0
for _ in $(seq 1 100); do
  if curl -s -o /dev/null "$URL/engines" 2>/dev/null; then up=1; break; fi
  sleep 0.1
done
[[ "$up" == 1 ]] || fail "server did not come up on :$PORT
$(cat "$scratch/server.log")"

ENGINES="zig-jit zig-interp zig-simd-jit c-jit c-interp rust-jit rust-interp cljw-clj"
KERNELS="zig zig-simd c rust"
want='{"engines":["zig-jit","zig-interp","zig-simd-jit","c-jit","c-interp","rust-jit","rust-interp","cljw-clj"],"kernels":["zig","zig-simd","c","rust"]}'
engines="$(curl -s "$URL/engines")"
[[ "$engines" == "$want" ]] || fail "/engines: got '$engines'"
echo "PASS fractal-server-engines -> $engines"

code=$(curl -s -o "$scratch/index.html" -w "%{http_code}" "$URL/")
[[ "$code" == "200" ]] && grep -q 'js/main.js' "$scratch/index.html" || fail "/: status $code, or no js/main.js"
echo "PASS fractal-server-page -> /"

for k in $KERNELS; do
  file="$DEMO/kernel.wasm"
  [[ "$k" == zig ]] || file="$DEMO/kernel_${k//-/_}.wasm"
  [[ "$k" == zig-simd ]] && file="$DEMO/kernel_simd.wasm"
  curl -s -o "$scratch/k.$k" "$URL/kernel.wasm?k=$k"
  cmp -s "$scratch/k.$k" "$file" || fail "/kernel.wasm?k=$k differs from $file"
done
echo "PASS fractal-server-kernels -> $KERNELS, identical to the committed files"

W=64; H=48
ref_sum=""; ref_iters=""
for e in $ENGINES; do
  curl -s -D "$scratch/h.$e" -o "$scratch/t.$e" \
    "$URL/tile?cx=-0.5&cy=0&scale=0.05&w=$W&h=$H&iter=128&engine=$e"
  len=$(wc -c <"$scratch/t.$e" | tr -d ' ')
  [[ "$len" == $((W * H * 4)) ]] || fail "/tile $e: $len bytes, want $((W * H * 4))"
  grep -qi '^x-render-ms:' "$scratch/h.$e" || fail "/tile $e: no X-Render-Ms header"
  iters=$(grep -i '^x-iters:' "$scratch/h.$e" | tr -d '\r' | awk '{print $2}')
  [[ -n "$iters" && "$iters" -gt 0 ]] || fail "/tile $e: bad X-Iters '$iters'"
  sum=$(cksum <"$scratch/t.$e" | awk '{print $1}')
  if [[ -z "$ref_sum" ]]; then ref_sum="$sum"; ref_iters="$iters"
  else
    [[ "$sum" == "$ref_sum" ]] || fail "/tile $e pixels differ from zig-jit"
    [[ "$iters" == "$ref_iters" ]] || fail "/tile $e X-Iters $iters, zig-jit had $ref_iters"
  fi
done
echo "PASS fractal-server-tiles -> ${W}x${H} RGBA on 8 engines, identical (X-Iters $ref_iters)"

code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/tile?engine=nope")
[[ "$code" == "400" ]] || fail "/tile unknown engine: status $code, want 400"
code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/tile?engine=zig-jit&formula=tricorn")
[[ "$code" == "400" ]] || fail "/tile tricorn on zig-jit: status $code, want 400"
echo "PASS fractal-server-refusals -> 400 for an unknown engine and an unrendered formula"
