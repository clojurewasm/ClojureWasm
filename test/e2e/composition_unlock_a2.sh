#!/usr/bin/env bash
# test/e2e/composition_unlock_a2.sh
#
# Phase 6.16.a-2 EXIT smoke — collection ops
# (conj / disj / contains? / get / nth / assoc / dissoc / keys / vals)
# per ADR-0033 D6 + v5 §5.2.
#
# After this cycle lands, user composition unlocks the second round
# of Pattern A recipes (`(reduce conj #{} ...)` etc once reduce
# lands in Phase 6.16.a-3).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

# --- conj ---
assert_eq 'conj_vec_append'    "$("$BIN" -e '(conj [1 2] 3)')"           '[1 2 3]'
assert_eq 'conj_set_add'       "$("$BIN" -e '(conj (hash-set 1) 2)')"    '#{1 2}'
assert_eq 'conj_nil_one_elt'   "$("$BIN" -e '(conj nil 42)')"            '(42)'

# --- disj ---
assert_eq 'disj_set'           "$("$BIN" -e '(disj (hash-set 1 2 3) 2)')" '#{1 3}'

# --- contains? ---
assert_eq 'contains_set_true'  "$("$BIN" -e '(contains? (hash-set 1 2) 1)')"  'true'
assert_eq 'contains_set_false' "$("$BIN" -e '(contains? (hash-set 1 2) 99)')" 'false'
assert_eq 'contains_nil_false' "$("$BIN" -e '(contains? nil 1)')"             'false'

# --- get ---
assert_eq 'get_set_present'    "$("$BIN" -e '(get (hash-set 1 2) 1)')"      '1'
assert_eq 'get_nil_nil'        "$("$BIN" -e '(get nil :a)')"                 'nil'
assert_eq 'get_default'        "$("$BIN" -e '(get nil :a "default")')"       '"default"'

# --- nth ---
assert_eq 'nth_vec_indexed'    "$("$BIN" -e '(nth [10 20 30] 1)')"          '20'
assert_eq 'nth_oob_default'    "$("$BIN" -e '(nth [10 20 30] 99 "oob")')"   '"oob"'

# --- assoc ---
assert_eq 'assoc_nil_to_map'   "$("$BIN" -e '(assoc nil :a 1)')"            '{:a 1}'
assert_eq 'assoc_vec_replace'  "$("$BIN" -e '(assoc [1 2 3] 1 99)')"        '[1 99 3]'

# --- dissoc ---
assert_eq 'dissoc_map'         "$("$BIN" -e '(dissoc (hash-map :a 1 :b 2) :a)')" '{:b 2}'

# --- keys / vals ---
assert_eq 'keys_map'           "$("$BIN" -e '(keys (hash-map :a 1 :b 2))')" '(:a :b)'
assert_eq 'vals_map'           "$("$BIN" -e '(vals (hash-map :a 1 :b 2))')" '(1 2)'

# --- compositional sanity (using a-1 primitives) ---
assert_eq 'count_after_conj'   "$("$BIN" -e '(count (conj [1 2] 3))')"     '3'
assert_eq 'first_of_keys'      "$("$BIN" -e '(first (keys (hash-map :a 1 :b 2)))')" ':a'

echo ""
echo "=== composition_unlock_a2: all assertions passed ==="
