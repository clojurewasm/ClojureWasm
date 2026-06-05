#!/usr/bin/env bash
# bench/release_metrics.sh — reproduce ClojureWasm's headline release metrics.
#
# The one number we lock is BINARY SIZE: it is deterministic given a Zig version
# + target (anyone re-running this gets the same bytes), unlike cold start which
# varies by machine and filesystem cache. Cold start is reported as a secondary,
# machine-dependent figure when `hyperfine` is available.
#
# Usage:  bash bench/release_metrics.sh
# Needs:  Zig 0.16 on PATH (direnv / nix develop); optionally `hyperfine`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== ClojureWasm release metrics =="
echo "zig: $(zig version)   host: $(uname -ms)"
echo

# Binary size — the locked, reproducible number (ReleaseSmall, stripped).
zig build -Doptimize=ReleaseSmall >/dev/null
bin=zig-out/bin/cljw
stripped=$(mktemp)
strip -o "$stripped" "$bin"
size=$(wc -c < "$stripped")
printf 'binary size (ReleaseSmall, stripped): %d bytes  (%.2f MB)\n' "$size" "$(echo "scale=4; $size/1048576" | bc)"
printf 'binary size (ReleaseSmall, on disk):  %d bytes\n' "$(wc -c < "$bin")"

# Sanity: the binary actually runs a full-numeric-tower expression.
echo
echo -n 'smoke (/ 1 3) => '; "$stripped" -e '(/ 1 3)'

# Cold start — secondary, machine-dependent.
echo
if command -v hyperfine >/dev/null 2>&1; then
  hyperfine -N --warmup 5 "$stripped -e nil" 2>/dev/null | grep -E 'Time|mean' || true
else
  echo "cold start: install hyperfine for a stable measurement (machine-dependent)"
fi
rm -f "$stripped"
