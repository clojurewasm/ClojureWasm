#!/usr/bin/env bash
# clojure.test.tap backfill (D-273) — TAP (Test Anything Protocol) output for
# clojure.test. `with-tap-output` rebinds clojure.test/report (now ^:dynamic) to a
# TAP reporter emitting `ok` / `not ok` lines + `#` diagnostics + a `1..n` plan. Built
# on clj-compat clojure.test surface added here: with-test-out / inc-report-counter /
# testing-vars-str / testing-contexts-str / *testing-vars* / *stack-trace-depth*
# (also useful for running real clojure.test suites, D-232). Uses clojure.stacktrace
# (D-273) for the actual-trace diagnostic. Java `.split` → clojure.string/split-lines.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> ok"
}

# with-tap-output emits valid TAP: ok / not ok lines (named by the test var) +
# `#` diagnostics + the trailing `1..n` plan.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.test :as t] '[clojure.test.tap :as tap])
(t/deftest pass-t (t/is (= 1 1)))
(t/deftest fail-t (t/is (= 1 2)))
(print (with-out-str (tap/with-tap-output (t/run-tests 'user))))
EOF
)
want='ok user/pass-t
# expected:(= 1 1)
#   actual:(clojure.core/= 1 1)
not ok user/fail-t
# expected:(= 1 2)
#   actual:(clojure.core/not= 1 2)
1..2'
assert_eq 'tap_output' "$got" "$want"

echo
echo "clojure.test.tap backfill (D-273) e2e: all green."
