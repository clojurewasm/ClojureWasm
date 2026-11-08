#!/usr/bin/env bash
# D-530: native assertions; the shell selects the suite and optional library.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

"$BIN" -cp test/clj -M test/clj/run_suites.clj suites.deftype-overload-arity-test

PM="$HOME/Documents/OSS/data.priority-map"
if [ -d "$PM" ]; then
    run_bounded 40 "$BIN" -cp "$PM/src" test/clj/process/priority_map_bounds.clj
else
    echo "SKIP priority_map_subseq (data.priority-map not cloned at $PM)"
fi
