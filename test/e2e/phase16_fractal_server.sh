#!/usr/bin/env bash
# e2e-process-boundary: docs/examples/fractal/server.clj over real HTTP.
# Starts the demo server on a fixed port, then checks the routes the page
# depends on: /engines, /kernel.wasm (bytes equal to the committed file) and
# /tile on every engine (exactly w*h*4 bytes, X-Render-Ms and X-Iters set,
# identical pixels and iteration totals across engines). Serial: fixed port.
# Correctness only, no timing thresholds.
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
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_fractal_srv_XXXXXX")"
run_bounded 120 "$BIN" "$DEMO/server.clj" "$PORT" >"$scratch/server.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$scratch"' EXIT

up=0
for _ in $(seq 1 100); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/engines" 2>/dev/null; then up=1; break; fi
  sleep 0.1
done
[[ "$up" == 1 ]] || fail "server did not come up on :$PORT
$(cat "$scratch/server.log")"

engines="$(curl -s "http://127.0.0.1:$PORT/engines")"
[[ "$engines" == '{"engines":["jit","interp","jit-simd"]}' ]] || fail "/engines: got '$engines'"
echo "PASS fractal-server-engines -> $engines"

curl -s -o "$scratch/kernel.wasm" "http://127.0.0.1:$PORT/kernel.wasm"
cmp -s "$scratch/kernel.wasm" "$DEMO/kernel.wasm" || fail "/kernel.wasm differs from the committed file"
echo "PASS fractal-server-kernel -> $(wc -c <"$DEMO/kernel.wasm" | tr -d ' ') bytes, identical"

W=64; H=48
ref_sum=""; ref_iters=""
for e in jit interp jit-simd; do
  curl -s -D "$scratch/h.$e" -o "$scratch/t.$e" \
    "http://127.0.0.1:$PORT/tile?cx=-0.5&cy=0&scale=0.05&w=$W&h=$H&iter=128&engine=$e"
  len=$(wc -c <"$scratch/t.$e" | tr -d ' ')
  [[ "$len" == $((W * H * 4)) ]] || fail "/tile $e: $len bytes, want $((W * H * 4))"
  grep -qi '^x-render-ms:' "$scratch/h.$e" || fail "/tile $e: no X-Render-Ms header"
  iters=$(grep -i '^x-iters:' "$scratch/h.$e" | tr -d '\r' | awk '{print $2}')
  [[ -n "$iters" && "$iters" -gt 0 ]] || fail "/tile $e: bad X-Iters '$iters'"
  sum=$(cksum <"$scratch/t.$e" | awk '{print $1}')
  if [[ -z "$ref_sum" ]]; then ref_sum="$sum"; ref_iters="$iters"
  else
    [[ "$sum" == "$ref_sum" ]] || fail "/tile $e pixels differ from jit"
    [[ "$iters" == "$ref_iters" ]] || fail "/tile $e X-Iters $iters, jit had $ref_iters"
  fi
done
echo "PASS fractal-server-tiles -> ${W}x${H} RGBA on jit, interp, jit-simd, identical (X-Iters $ref_iters)"

code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/tile?engine=nope")
[[ "$code" == "400" ]] || fail "/tile unknown engine: status $code, want 400"
echo "PASS fractal-server-bad-engine -> 400"
