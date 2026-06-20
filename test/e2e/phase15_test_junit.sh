#!/usr/bin/env bash
# test/e2e/phase15_test_junit.sh
#
# clojure.test.junit — bundled official stdlib (JUnit-XML reporter extending
# clojure.test's `report` multimethod). Bundling it required 3 generic
# clojure.test parity fixes (each benefits any reporter, not just junit):
#   - `file-position` — added (cljw has no source location, AD-041; returns
#     ["NO_SOURCE_FILE" 0] honestly).
#   - test-var now emits :begin-test-var / :end-test-var (junit's <testcase>).
#   - run-tests now emits :end-test-ns (junit's </testsuite>).
# Output matches clj exactly modulo the source position (AD-041).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

prog='(require (quote [clojure.test :as t]) (quote [clojure.test.junit :as ju]))
(t/deftest a-pass (t/is (= 1 1)))
(t/deftest a-fail (t/is (= 1 2)))
(ju/with-junit-output (t/run-tests (quote user)))'

out="$("$BIN" - <<<"$prog" 2>&1)"

# Structural assertions: the testsuite + both testcases + the failure + closing tags.
for needle in \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<testsuites>' \
  '<testsuite name="user">' \
  '<testcase name="a-pass" classname="user">' \
  '<testcase name="a-fail" classname="user">' \
  '<failure>expected: (= 1 2)' \
  '</testsuite>' \
  '</testsuites>'; do
  case "$out" in *"$needle"*) echo "PASS contains: $needle" ;; *) fail "missing: $needle (got: $out)" ;; esac
done

# begin/end-test-var fire for a custom reporter too (the generic win).
ev="$("$BIN" -e '(do (require (quote [clojure.test :as t])) (def evs (atom []))
  (defmethod t/report :begin-test-var [m] (swap! evs conj :begin))
  (defmethod t/report :end-test-var [m] (swap! evs conj :end))
  (t/deftest z (t/is true)) (binding [t/*test-out* *out*] (t/run-tests (quote user))) (pr-str @evs))' 2>&1 | tail -1)"
case "$ev" in *'[:begin :end]'*) echo "PASS begin/end-test-var fire" ;; *) fail "begin/end-test-var: got '$ev'" ;; esac

echo "ALL phase15_test_junit PASS"
