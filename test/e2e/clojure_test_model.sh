#!/usr/bin/env bash
# test/e2e/clojure_test_model.sh — clojure.test's var model and the three
# false-greens that a compliance campaign cannot tolerate in its own instrument:
#   (1) `(run-tests *ns*)` — the call clj's own 0-arity makes — reported
#       "Ran 0 tests" green because the registry is keyed by ns SYMBOL;
#   (2) `are` silently dropped a trailing partial group instead of throwing;
#   (3) `use-fixtures` appended where clj replaces, so a reloaded namespace ran
#       its fixtures twice per test.
# Plus the model itself: clj stores the body in the var's `:test` metadata and
# makes the var's value `(fn [] (test-var (var name)))`. Everything built on
# that — with-test / set-test / test-vars / test-all-vars / run-test, and every
# external runner that filters `ns-interns` on `:test` — follows from it.
# Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n"; }

# last(prog) — the value the program prn'd. `-e` echoes each top-level form's
# own value after it, so the prn line is the second-to-last, not the last.
last() { "$BIN" -e "$1" 2>&1 | tail -2 | sed -n 1p; }
out()  { "$BIN" -e "$1" 2>&1; }

C='(fn [s] [(:test s) (:pass s) (:fail s) (:error s)])'
REQ='(ns t (:require [clojure.test :refer [deftest is are testing use-fixtures run-tests test-var test-vars test-all-vars run-test with-test set-test deftest- successful?]]))'

# --- (1) run-tests accepts a Namespace object, not only its symbol ----------
P="$REQ
   (deftest a (is (= 1 1)) (is (= 2 2)))
   (prn ($C (run-tests *ns*)))"
assert_eq 'run-tests-ns-object' "$(last "$P")" '[1 2 0 0]'

P="$REQ
   (deftest a (is (= 1 1)))
   (prn ($C (run-tests \"t\")))"
assert_eq 'run-tests-ns-string' "$(last "$P")" '[1 1 0 0]'

# An unknown namespace is an error, not a silent clean run.
P="$REQ (prn (try (run-tests 'no.such.ns) :no-throw (catch Throwable _ :threw)))"
assert_eq 'run-tests-unknown-ns' "$(last "$P")" ':threw'

# --- (2) `are` rejects a partial trailing group ------------------------------
P="$REQ (prn (try (eval '(are [x y] (= x y) 1 1 2)) :no-throw (catch Throwable _ :threw)))"
assert_eq 'are-partial-group' "$(last "$P")" ':threw'

P="$REQ (deftest a (are [x y] (= x y) 1 1 2 2)) (prn ($C (run-tests 't)))"
assert_eq 'are-whole-groups' "$(last "$P")" '[1 2 0 0]'

# --- (3) use-fixtures REPLACES, so a reload cannot double-run a fixture ------
P="$REQ
   (def calls (atom 0))
   (defn f [g] (swap! calls inc) (g))
   (use-fixtures :each f)
   (use-fixtures :each f)
   (deftest a (is (= 1 1)))
   (deftest b (is (= 2 2)))
   (run-tests 't)
   (prn @calls)"
assert_eq 'use-fixtures-replaces' "$(last "$P")" '2'

# --- the :test metadata model ------------------------------------------------
P="$REQ (deftest a (is (= 1 1))) (prn (fn? (:test (meta (var a)))))"
assert_eq 'deftest-test-meta' "$(last "$P")" 'true'

# Re-evaluating a deftest must not register it twice.
P="$REQ
   (deftest a (is (= 1 1)))
   (deftest a (is (= 1 1)))
   (prn ($C (run-tests 't)))"
assert_eq 'deftest-reeval-no-dup' "$(last "$P")" '[1 1 0 0]'

# Calling the test var directly routes through test-var (so it reports).
P="$REQ (deftest a (is (= 1 2))) (a)"
assert_has 'deftest-direct-call-reports' "$(out "$P")" 'FAIL in (a)'

# --- the API that the :test model unlocks ------------------------------------
P="$REQ (deftest a (is (= 1 1))) (deftest b (is (= 2 2))) (prn ($C (test-vars [(var a) (var b)])))"
assert_eq 'test-vars' "$(last "$P")" '[2 2 0 0]'

P="$REQ (deftest a (is (= 1 1))) (prn ($C (test-all-vars *ns*)))"
assert_eq 'test-all-vars' "$(last "$P")" '[1 1 0 0]'

P="$REQ (deftest a (is (= 1 1))) (prn ($C (run-test a)))"
assert_eq 'run-test' "$(last "$P")" '[1 1 0 0]'

P="$REQ (with-test (defn f [x] (* 2 x)) (is (= 4 (f 2)))) (prn ($C (run-tests 't)))"
assert_eq 'with-test' "$(last "$P")" '[1 1 0 0]'

P="$REQ (defn f [x] x) (set-test f (is (= 1 (f 1)))) (prn ($C (run-tests 't)))"
assert_eq 'set-test' "$(last "$P")" '[1 1 0 0]'

P="$REQ (deftest- a (is (= 1 1))) (prn [(:private (meta (var a))) ($C (run-tests 't))])"
assert_eq 'deftest-private' "$(last "$P")" '[true [1 1 0 0]]'

# *load-tests* false: the definition still lands, the test does not.
P="$REQ
   (binding [clojure.test/*load-tests* false]
     (eval '(clojure.test/deftest a (clojure.test/is (= 1 2)))))
   (prn ($C (run-tests 't)))"
assert_eq 'load-tests-false' "$(last "$P")" '[0 0 0 0]'

# --- successful? + report :default -------------------------------------------
P="$REQ (prn [(successful? {:fail 0 :error 0}) (successful? {:fail 1 :error 0}) (successful? {:fail 0 :error 2})])"
assert_eq 'successful' "$(last "$P")" '[true false false]'

# An unrecognised report type is printed, not swallowed (clj prns it).
P="$REQ (clojure.test/do-report {:type :some-unknown-event :note 42})"
assert_has 'report-default-prints' "$(out "$P")" ':some-unknown-event'

echo "OK clojure_test_model"
