#!/usr/bin/env bash
# test/e2e/phase15_clojure_test.sh — clojure.test (D-227): deftest/is/are/testing/
# run-tests with a per-ns registry keyed by ns symbol. run-tests returns the
# summary map {:test :pass :fail :error}; the report prints to stdout. We assert
# the returned counts (the last prn line). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# counts(prog) — run a program ending in a (prn [test pass fail error]) and return that line
counts() { "$BIN" -e "$1" 2>&1 | tail -1; }

C='(fn [s] [(:test s) (:pass s) (:fail s) (:error s)])'

# all pass: 1 test, 3 assertions
P1='(ns t1 (:require [clojure.test :refer [deftest is run-tests]]))
    (deftest a (is (= 1 1)) (is (pos? 3)) (is (not (nil? []))))
    ('"$C"' (run-tests (quote t1)))'
assert_eq 'all-pass' "$(counts "$P1")" '[1 3 0 0]'

# one fail
P2='(ns t2 (:require [clojure.test :refer [deftest is run-tests]]))
    (deftest a (is (= 1 1)) (is (= 1 2)))
    ('"$C"' (run-tests (quote t2)))'
assert_eq 'one-fail' "$(counts "$P2")" '[1 1 1 0]'

# error (uncaught throw inside is, not via thrown?)
P3='(ns t3 (:require [clojure.test :refer [deftest is run-tests]]))
    (deftest a (is (throw (ex-info "x" {}))))
    ('"$C"' (run-tests (quote t3)))'
assert_eq 'error' "$(counts "$P3")" '[1 0 0 1]'

# thrown? passes
P4='(ns t4 (:require [clojure.test :refer [deftest is run-tests]]))
    (deftest a (is (thrown? Throwable (throw (ex-info "x" {})))))
    ('"$C"' (run-tests (quote t4)))'
assert_eq 'thrown' "$(counts "$P4")" '[1 1 0 0]'

# are expands to N assertions
P5='(ns t5 (:require [clojure.test :refer [deftest is are run-tests]]))
    (deftest a (are [x y] (= x y) 1 1 2 2 3 3))
    ('"$C"' (run-tests (quote t5)))'
assert_eq 'are' "$(counts "$P5")" '[1 3 0 0]'

# two deftests in one ns, run-tests with no arg (current ns)
P6='(ns t6 (:require [clojure.test :refer [deftest is run-tests]]))
    (deftest a (is (= 1 1)))
    (deftest b (is (= 2 2)) (is (= 3 3)))
    ('"$C"' (run-tests))'
assert_eq 'multi-deftest' "$(counts "$P6")" '[2 3 0 0]'

# testing context does not change counts
P7='(ns t7 (:require [clojure.test :refer [deftest is testing run-tests]]))
    (deftest a (testing "ctx" (is (= 1 1)) (is (= 2 2))))
    ('"$C"' (run-tests (quote t7)))'
assert_eq 'testing' "$(counts "$P7")" '[1 2 0 0]'

echo "OK — phase15_clojure_test (7 cases) green"
