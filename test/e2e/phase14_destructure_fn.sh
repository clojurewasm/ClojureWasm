#!/usr/bin/env bash
# test/e2e/phase14_destructure_fn.sh — clojure.core/destructure (D-396). The
# public binding-expander macro authors call: `(destructure bindings)` returns a
# plain-symbol binding vector (gensym temps + nth/get) suitable for `let*`. cljw
# destructures in the analyzer but did not expose the fn, so libs writing their
# own binding macros (kezban's `letm`) hit name_error. Tested end-to-end through
# a macro that splices destructure's output into let*. clj-matched. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# A macro that uses destructure exactly like kezban: splice into let*.
PRE='(defmacro mlet [b & body] (cons (quote let*) (cons (destructure b) body)))'
run() { "$BIN" - <<EOF 2>&1 | tail -1
$PRE
$1
EOF
}

assert_eq 'plain'        "$(run '(prn (mlet [a 1 b 2] (+ a b)))')"                       '3'
assert_eq 'vector'       "$(run '(prn (mlet [[a b] [10 20]] (- b a)))')"                 '10'
assert_eq 'vector-rest'  "$(run '(prn (mlet [[a & r] [1 2 3 4]] [a r]))')"               '[1 (2 3 4)]'
assert_eq 'vector-as'    "$(run '(prn (mlet [[a :as all] [7 8]] [a all]))')"             '[7 [7 8]]'
assert_eq 'map-keys'     "$(run '(prn (mlet [{:keys [a b]} {:a 1 :b 2}] [a b]))')"       '[1 2]'
assert_eq 'map-or'       "$(run '(prn (mlet [{:keys [a b] :or {b 9}} {:a 1}] [a b]))')"  '[1 9]'
assert_eq 'map-as'       "$(run '(prn (mlet [{:keys [a] :as m} {:a 5}] [a m]))')"        '[5 {:a 5}]'
assert_eq 'map-strs'     "$(run '(prn (mlet [{:strs [x]} {"x" 4}] x))')"                 '4'
assert_eq 'nested'       "$(run '(prn (mlet [[a [b c]] [1 [2 3]]] [a b c]))')"           '[1 2 3]'
assert_eq 'map-in-vec'   "$(run '(prn (mlet [[{:keys [k]}] [{:k 8}]] k))')"              '8'
# already-plain bindings pass through unchanged (the every-symbol fast path)
assert_eq 'passthrough'  "$(run '(prn (= (destructure (quote [a 1 b 2])) (quote [a 1 b 2])))')" 'true'

echo "OK — phase14_destructure_fn (11 cases) green"
