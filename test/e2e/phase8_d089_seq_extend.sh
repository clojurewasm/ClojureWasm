#!/usr/bin/env bash
# D-089: native-tag extension changes global dispatch, so isolate the process.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
"$BIN" test/clj/process/seq_protocol_extensions.clj
