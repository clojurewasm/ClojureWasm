#!/usr/bin/env bash
# test/e2e/phase14_fn_recur.sh — recur in fn-tail position (D-090). JVM treats
# a fn as an implicit loop* over its params: a tail recur rebinds the param
# slots and re-enters the body (constant stack — deep recursion is safe). A
# recur inside an enclosing loop* targets the loop, not the fn. Variadic fns
# rebind the rest param too. clj-grounded.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# anonymous fn tail recur
assert_eq 'anon_recur'  "$("$BIN" -e '((fn [n acc] (if (zero? n) acc (recur (dec n) (inc acc)))) 5 0)')" '5'
# defn tail recur, deep (constant stack — no overflow). Multi-form -e prints
# the defn's #'user/cnt then the call result; take the last line.
assert_eq 'defn_deep'   "$("$BIN" -e '(defn cnt [n] (if (= n 0) :done (recur (dec n)))) (cnt 1000000)' | tail -1)" ':done'
# accumulating sum via fn recur
assert_eq 'sum_recur'   "$("$BIN" -e '(defn s [n a] (if (zero? n) a (recur (dec n) (+ a n)))) (s 100 0)' | tail -1)" '5050'
# variadic fn recur rebinds the rest param
assert_eq 'variadic'    "$("$BIN" -e '((fn [a & r] (if (empty? r) a (recur (+ a (first r)) (rest r)))) 0 1 2 3 4)')" '10'
# recur inside an enclosing loop* targets the loop, not the fn
assert_eq 'loop_in_fn'  "$("$BIN" -e '(defn f [x] (loop [i 0 s 0] (if (< i x) (recur (inc i) (+ s i)) s))) (f 5)' | tail -1)" '10'
# arity mismatch is still a compile-time error
out="$("$BIN" -e '((fn [a b] (recur 1)) 1 2)' 2>&1 || true)"; [[ "$out" == *"expected 2"* ]] || fail "arity_err: $out"; echo "PASS arity_err -> err"
# both backends agree (dual-backend parity)
assert_eq 'compare'     "$("$BIN" --compare -e '((fn [n acc] (if (zero? n) acc (recur (dec n) (inc acc)))) 8 0)' | tail -1)" 'OK 8'

echo "OK — phase14_fn_recur (7 cases) green"
