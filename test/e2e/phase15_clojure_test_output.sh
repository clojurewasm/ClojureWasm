#!/usr/bin/env bash
# test/e2e/phase15_clojure_test_output.sh — clojure.test OUTPUT fidelity (D-463).
# The report format is clj-grounded (oracle: clj 1.12). The FAIL line carries
# a ` (file:line)` suffix from the deftest VAR's source meta (D-563b) — clj
# points at the failing `is` via its JVM stack instead (deftest-line vs
# is-line = the narrowed AD-041); the :error cause trace stays AD-041.
# Everything else matches clj byte-for-line: `(not (= 1 2))` actual,
# `outer inner` context line, the `Testing <ns>` begin line, and a re-enabled
# `*test-out*` (binding it redirects report output — was a no-JVM deferral).
# Uses `cljw -` (stdin program: only explicit output, no per-form echo). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
has() { local n="$1" out="$2" line="$3"; grep -Fqx "$line" <<<"$out" || fail "$n: missing line '$line'"; echo "PASS $n -> $line"; }
hasf() { local n="$1" out="$2" sub="$3"; grep -Fq "$sub" <<<"$out" || fail "$n: missing '$sub'"; echo "PASS $n -> $sub"; }

# --- A. = fail: FAIL line via testing-vars-str + clj actual (not (= …)) + Testing line + summary
A=$("$BIN" - <<'EOF' 2>&1
(ns demo (:require [clojure.test :refer [deftest is run-tests]]))
(deftest eqfail (is (= 1 2)))
(run-tests 'demo)
EOF
)
has 'A-testing'   "$A" 'Testing demo'
hasf 'A-fail-in'  "$A" 'FAIL in (eqfail) ('   # suffix present (D-563b; stdin label)
has 'A-expected'  "$A" 'expected: (= 1 2)'
has 'A-actual'    "$A" '  actual: (not (= 1 2))'
has 'A-ran'       "$A" 'Ran 1 tests containing 1 assertions.'
has 'A-summary'   "$A" '1 failures, 0 errors.'

# --- B. predicate (non-=) fail: actual wraps the evaluated form in (not …)
B=$("$BIN" - <<'EOF' 2>&1
(ns demo (:require [clojure.test :refer [deftest is run-tests]]))
(deftest pf (is (pos? -1)))
(run-tests 'demo)
EOF
)
has 'B-actual' "$B" '  actual: (not (pos? -1))'

# --- C. testing context: clj prints the joined context strings (outermost first)
C=$("$BIN" - <<'EOF' 2>&1
(ns demo (:require [clojure.test :refer [deftest is testing run-tests]]))
(deftest cf (testing "outer" (testing "inner" (is (= :a :b)))))
(run-tests 'demo)
EOF
)
has 'C-context' "$C" 'outer inner'

# --- D. = pass actual renders the bare form (= 1 1), not clojure.core/=
D=$("$BIN" - <<'EOF' 2>&1
(require '[clojure.test :as t :refer [deftest is run-tests]] '[clojure.test.tap :as tap])
(deftest p (is (= 1 1)))
(tap/with-tap-output (run-tests 'user))
EOF
)
hasf 'D-pass-actual' "$D" '#   actual:(= 1 1)'

# --- E. *test-out* is re-enabled: resolvable + binding it redirects report output
E=$("$BIN" - <<'EOF' 2>&1
(require '[clojure.test])
(prn (some? (resolve 'clojure.test/*test-out*)))
EOF
)
has 'E-resolvable' "$E" 'true'

F=$("$BIN" - <<'EOF' 2>&1
(ns d2 (:require [clojure.test :as t :refer [deftest is run-tests]]))
(deftest f (is (= 1 2)))
(print "CAP[" (with-out-str (binding [t/*test-out* *out*] (run-tests 'd2))) "]CAP")
EOF
)
hasf 'F-capture' "$F" 'CAP['
hasf 'F-captured-fail' "$F" 'FAIL in (f) ('

echo "OK — phase15_clojure_test_output (D-463) green"
