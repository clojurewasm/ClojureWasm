#!/usr/bin/env bash
# test/e2e/composition_unlock_a1.sh
#
# Phase 6.16.a-1 EXIT smoke — core glue fundamentals
# (count / seq / first / rest / cons / empty) per ADR-0033 D6.
#
# After this cycle lands, user composition unlocks the first round
# of Pattern A recipes that depend on these six (e.g. `(rest [1 2 3])`,
# `(cons 0 [1 2])`). Phase 6.16.a-2 unlocks more via conj/disj/etc.

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

# --- count ---
assert_eq 'count_vector_3'  "$("$BIN" -e '(count [1 2 3])')"  '3'
assert_eq 'count_string_4'  "$("$BIN" -e '(count "café")')"   '4'   # DIVERGENCE D1: codepoint count
assert_eq 'count_nil_0'     "$("$BIN" -e '(count nil)')"      '0'
assert_eq 'count_set_3'     "$("$BIN" -e '(count (hash-set 1 2 3))')" '3'

# --- seq ---
assert_eq 'seq_empty_nil'   "$("$BIN" -e '(seq [])')"         'nil'
assert_eq 'seq_vec_2'       "$("$BIN" -e '(seq [1 2])')"      '(1 2)'
assert_eq 'seq_nil_nil'     "$("$BIN" -e '(seq nil)')"        'nil'

# --- first ---
assert_eq 'first_vec_1'     "$("$BIN" -e '(first [1 2 3])')"  '1'
assert_eq 'first_nil_nil'   "$("$BIN" -e '(first nil)')"      'nil'

# --- rest ---
assert_eq 'rest_vec_2_3'    "$("$BIN" -e '(rest [1 2 3])')"   '(2 3)'
assert_eq 'rest_nil_nil'    "$("$BIN" -e '(rest nil)')"       'nil'

# --- cons ---
assert_eq 'cons_x_nil'      "$("$BIN" -e '(cons 0 nil)')"     '(0)'
assert_eq 'cons_x_vec'      "$("$BIN" -e '(cons 0 [1 2])')"   '(0 1 2)'

# --- empty ---
assert_eq 'empty_vec_empty' "$("$BIN" -e '(empty [1 2 3])')"  '[]'
assert_eq 'empty_set_empty' "$("$BIN" -e '(empty (hash-set 1 2))')" '#{}'
assert_eq 'empty_nil_nil'   "$("$BIN" -e '(empty nil)')"      'nil'

# --- compositional sanity (unlocked by this cycle) ---
assert_eq 'first_of_rest'    "$("$BIN" -e '(first (rest [1 2 3]))')" '2'
assert_eq 'count_of_cons'    "$("$BIN" -e '(count (cons 0 [1 2]))')" '3'

echo ""
echo "=== composition_unlock_a1: all assertions passed ==="
