#!/usr/bin/env bash
# test/e2e/phase14_threading_macros.sh
#
# D-134 missing-core batch — threading-conditional family:
# as-> / cond-> / cond->> / some-> / some->>. All expand to a let*
# cascade reusing the -> / ->> threadStep (macro_transforms.zig).
# (Keyword thread-steps `(-> m :k)` stay unsupported pending
# keyword-as-IFn — see D-085; not exercised here.)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# as-> (explicit-placement rebind)
assert_eq 'as_arith'  "$("$BIN" -e '(as-> 5 x (+ x 1) (* x 2))')"             '12'
assert_eq 'as_map'    "$("$BIN" -e '(as-> {:a 1} m (assoc m :b 2) (get m :b))')" '2'
assert_eq 'as_mixed'  "$("$BIN" -e '(as-> [1 2 3] v (conj v 4) (count v))')"  '4'
# cond-> (thread-first, conditional clauses)
assert_eq 'cond_inc'  "$("$BIN" -e '(cond-> 1 true inc false inc (= 2 2) inc)')" '3'
assert_eq 'cond_conj' "$("$BIN" -e '(cond-> [] true (conj 1) false (conj 2) true (conj 3))')" '[1 3]'
assert_eq 'cond_none' "$("$BIN" -e '(cond-> 10 false inc false dec)')"        '10'
# cond->> (thread-last)
assert_eq 'condl_red' "$("$BIN" -e '(cond->> [1 2 3] true (map inc) true (reduce +))')" '9'
# some-> (thread-first, nil short-circuit)
assert_eq 'some_chain' "$("$BIN" -e '(some-> 1 inc inc)')"                    '3'
assert_eq 'some_nil0'  "$("$BIN" -e '(some-> nil inc)')"                      'nil'
assert_eq 'some_mid'   "$("$BIN" -e '(some-> {:a 1} (get :b) inc)')"          'nil'
# some->> (thread-last, nil short-circuit)
assert_eq 'somel_red'  "$("$BIN" -e '(some->> [1 2 3] (map inc) (reduce +))')" '9'
assert_eq 'somel_nil'  "$("$BIN" -e '(some->> nil (map inc))')"               'nil'

echo "OK — phase14_threading_macros smoke (12 cases) green"
