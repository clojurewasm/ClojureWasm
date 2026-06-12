#!/usr/bin/env bash
# test/e2e/phase15_use_refer_all.sh — `:refer :all` + the `(:use …)` ns directive.
# `:refer :all` / `:use` refer ALL public vars of a ns (env.referAll, privates
# skipped). The validation-campaign prerequisite: real libs + the upstream
# Clojure test suite open with `(:use clojure.test)`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
CP="test/e2e/fixtures/cljwlib"
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# standalone require with :refer :all (refer-then-use as separate top-level forms)
assert_eq 'refer-all'  "$("$BIN" -e '(require (quote [clojure.string :refer :all])) (upper-case "hi")' 2>&1 | tail -1)" '"HI"'
# (:use embedded-ns) in an ns form
assert_eq 'use-string' "$("$BIN" -e '(ns foo (:use clojure.string)) (upper-case "hi")' 2>&1 | tail -1)" '"HI"'
# (:use clojure.test) — the campaign-critical form — then deftest/is/run-tests unqualified
assert_eq 'use-test'   "$("$BIN" -e '(ns foo (:use clojure.test)) (deftest t (is (= 1 1)) (is (= 2 2))) (let [s (run-tests)] [(:pass s) (:fail s)])' 2>&1 | tail -1)" '[2 0]'
# (:use disk-lib) off -cp
assert_eq 'use-disk'   "$("$BIN" -cp "$CP" -e '(ns foo (:use demo.math)) (square 6)' 2>&1 | tail -1)" '36'
# :use of multiple libs at once
assert_eq 'use-multi'  "$("$BIN" -e '(ns foo (:use clojure.string clojure.set)) [(upper-case "x") (union #{1} #{2})]' 2>&1 | tail -1)" '["X" #{1 2}]'

echo "OK — phase15_use_refer_all (5 cases) green"
