#!/usr/bin/env bash
# bench/release_metrics.sh — reproduce ClojureWasm's headline release metrics.
#
# The number we lock is BINARY SIZE: it is deterministic given a Zig version +
# target (anyone re-running this gets the same bytes), unlike cold start which
# varies by machine and filesystem cache. We report two builds: ReleaseSafe (the
# recommended release build — optimised WITH safety checks) and ReleaseSmall (the
# size floor). Cold start is a secondary, machine-dependent figure.
#
# Usage:  bash bench/release_metrics.sh
# Needs:  Zig 0.16 on PATH (direnv / nix develop); optionally `hyperfine`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== ClojureWasm release metrics =="
echo "zig: $(zig version)   host: $(uname -ms)"
echo

LAST_STRIPPED=""
measure() { # <optimize-mode> — prints a size line, sets LAST_STRIPPED to a temp stripped binary
  zig build -Doptimize="$1" >/dev/null
  local s sz disk
  s=$(mktemp); strip -o "$s" zig-out/bin/cljw
  sz=$(wc -c < "$s"); disk=$(wc -c < zig-out/bin/cljw)
  printf '%-12s stripped: %8d bytes  (%.2f MB)   on-disk: %d bytes\n' \
    "$1" "$sz" "$(echo "scale=4; $sz/1048576" | bc)" "$disk"
  LAST_STRIPPED="$s"
}

measure ReleaseSafe;  safe="$LAST_STRIPPED"   # recommended release build
measure ReleaseSmall; small="$LAST_STRIPPED"  # size floor

# Sanity: the shipped (ReleaseSafe) binary runs a full-numeric-tower expression.
echo
echo -n 'smoke (/ 1 3) => '; "$safe" -e '(/ 1 3)'

# Cold start — secondary, machine-dependent (measured on the ReleaseSafe build).
echo
if command -v hyperfine >/dev/null 2>&1; then
  hyperfine -N --warmup 5 "$safe -e nil" 2>/dev/null | grep -E 'Time|mean' || true
else
  echo "cold start: install hyperfine for a stable, machine-specific measurement"
fi
rm -f "$safe" "$small"
