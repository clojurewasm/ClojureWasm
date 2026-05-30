#!/usr/bin/env bash
# test/e2e/phase14_doseq.sh — doseq (D-134 / phaseA26). Nested loop/recur over
# binding pairs with :let / :when / :while modifiers + multi-binding nesting.
# Always returns nil. Side effects observed via stdout (print); each case is
# wrapped in (do <doseq> :ok) so stdout = <effects>:ok (deterministic).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'nomod'   "$("$BIN" -e '(do (doseq [x [1 2 3]] (print x)) :ok)')" '123:ok'
assert_eq 'ret_nil' "$("$BIN" -e '(doseq [x [1 2 3]] x)')"                  'nil'
assert_eq 'when'    "$("$BIN" -e '(do (doseq [x [1 2 3 4] :when (odd? x)] (print x)) :ok)')" '13:ok'
assert_eq 'while'   "$("$BIN" -e '(do (doseq [x [1 2 3 4] :while (< x 3)] (print x)) :ok)')" '12:ok'
assert_eq 'let'     "$("$BIN" -e '(do (doseq [x [1 2 3] :let [y (* x 10)]] (print y)) :ok)')" '102030:ok'
assert_eq 'multi'   "$("$BIN" -e '(do (doseq [x [1 2] y [3 4]] (print (+ x y))) :ok)')" '4556:ok'
assert_eq 'combo'   "$("$BIN" -e '(do (doseq [x [1 2 3] :when (odd? x) y [0 1]] (print (+ x y))) :ok)')" '1234:ok'
assert_eq 'empty'   "$("$BIN" -e '(do (doseq [x []] (print x)) :ok)')" ':ok'
# nested :while cuts only the inner loop (JVM-faithful)
assert_eq 'nest_wh' "$("$BIN" -e '(do (doseq [x [1 2] y [10 20] :while (< y 15)] (print x y "|")) :ok)')" '1 10 |2 10 |:ok'
# destructuring bind (rides the let lowering)
assert_eq 'destr'   "$("$BIN" -e '(do (doseq [[a b] [[1 2] [3 4]]] (print (+ a b))) :ok)')" '37:ok'
# bad bindings → error
assert_has 'baderr' "$("$BIN" -e '(doseq [x] (print x))' 2>&1)" 'doseq bindings'
echo "OK — phase14_doseq smoke (11 cases) green"
