#!/usr/bin/env bash
# test/e2e/phase15_deferred_host_ref.sh — ADR-0113 / AD-022, the one case that
# needs a process. An unresolved `clojure.lang.*` reference defers to a
# CALL-time feature_not_supported; that raise is a .not_implemented error,
# which no (catch …) intercepts, so observing it means reading the stderr of a
# process that died of it. The deferral itself (defines + loads, value
# position, a user alias typo staying loud) is in-process and lives in
# test/clj/suites/forms_and_literals_test.clj (p15-deferred-host-ref).
# e2e-process-boundary: the call-time raise is an uncatchable not_implemented, observable only on stderr
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

# raises_when_called: invoking the unsupported ref errors loudly at call time
got="$("$BIN" -e '(do (defn f [] (clojure.lang.RT/baseLoader)) (f))' 2>&1 || true)"
grep -q 'clojure.lang.RT/baseLoader is not supported' <<<"$got" || fail "raises_when_called: got '$got'"
echo "PASS raises_when_called -> feature_not_supported"

echo "OK — phase15_deferred_host_ref (1 process case) green"
