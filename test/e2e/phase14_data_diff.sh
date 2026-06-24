#!/usr/bin/env bash
# test/e2e/phase14_data_diff.sh — clojure.data/diff (new ns) + the
# contains?-on-vector fix it surfaced. `(contains? vec i)` tests INDEX
# validity (not element membership); the data/diff sequential path needs it.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# contains? on vectors (index validity)
assert_eq 'cv_in'    "$("$BIN" -e '(contains? [1 2 3] 2)')"   'true'
assert_eq 'cv_oob'   "$("$BIN" -e '(contains? [1 2 3] 5)')"   'false'
assert_eq 'cv_neg'   "$("$BIN" -e '(contains? [1 2 3] -1)')"  'false'
assert_eq 'cv_kw'    "$("$BIN" -e '(contains? [1 2 3] :x)')"  'false'
# clojure.data/diff
assert_eq 'dd_eq'    "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff 1 1))')"               '[nil nil 1]'
assert_eq 'dd_ne'    "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff 1 2))')"               '[1 2 nil]'
assert_eq 'dd_map'   "$("$BIN" -e '(do (require (quote [clojure.data])) (nth (clojure.data/diff {:a 1 :b 2} {:a 1 :c 3}) 2))')" '{:a 1}'
assert_eq 'dd_seq'   "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff [1 2 3] [1 2 4]))')"   '[[nil nil 3] [nil nil 4] [1 2]]'
assert_eq 'dd_grow'  "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff [1 2 3] [1 2 3 4]))')" '[nil [nil nil nil 4] [1 2 3]]'
assert_eq 'dd_nest'  "$("$BIN" -e '(do (require (quote [clojure.data])) (nth (clojure.data/diff {:a {:x 1}} {:a {:x 1 :y 2}}) 1))')" '{:a {:y 2}}'
assert_eq 'dd_str'   "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff "a" "a"))')"           '[nil nil "a"]'
assert_eq 'dd_nil'   "$("$BIN" -e '(do (require (quote [clojure.data])) (clojure.data/diff nil {:a 1}))')"        '[nil {:a 1} nil]'
echo "OK — phase14_data_diff smoke (12 cases) green"
