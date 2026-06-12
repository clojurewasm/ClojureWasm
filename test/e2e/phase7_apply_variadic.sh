#!/usr/bin/env bash
# test/e2e/phase7_apply_variadic.sh
#
# Phase 7 §9.9 row 7.9 — `apply` variadic-callee bind-direct fast-path
# (D-072, ADR-0042).
#
# The ADR-0042 gate fires when:
#   - callee f.tag() == .fn_val
#   - f.variadic != null AND f.variadic.arity == leading.len
#   - trailing tag in {.list, .cons, .chunked_cons, .lazy_seq, .nil}
# applyFn then passes args[1..] = [leading..., trailing] straight
# through; callFunction's rest-pack gate binds trailing to the
# `& rest` slot without realising or cons-wrapping. Other shapes
# (fixed-arity callee, builtin, keyword-as-fn, vector / non-seq
# trailing) take the eager-spread fallback.
#
# Diff_test (`src/lang/diff_test.zig`) locks the equivalence on
# both backends; this e2e exercises the CLI surface.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

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

# --- Case 1: bind-direct path, list tail, no leading ---
got=$("$BIN" -e "(apply (fn* [& xs] (count xs)) '(1 2 3 4 5))" 2>/dev/null)
assert_eq 'bind_direct_list_no_leading' "$got" '5'

# --- Case 2: bind-direct path, list tail, with leading ---
got=$("$BIN" -e "(apply (fn* [a b & xs] (count xs)) 10 20 '(3 4 5))" 2>/dev/null)
assert_eq 'bind_direct_list_with_leading' "$got" '3'

# --- Case 3: bind-direct preserves seq identity (first walks the seq) ---
got=$("$BIN" -e "(apply (fn* [& xs] (first xs)) '(99 100 101))" 2>/dev/null)
assert_eq 'bind_direct_first_through_rest' "$got" '99'

# --- Case 4: vector tail (NOT in seq-tag set; eager-spread fallback) ---
got=$("$BIN" -e "(apply (fn* [& xs] (count xs)) [1 2 3 4 5])" 2>/dev/null)
assert_eq 'vector_tail_spread' "$got" '5'

# --- Case 5: builtin callee (fn_val gate skipped; eager spread) ---
got=$("$BIN" -e "(apply + 1 2 '(3 4 5))" 2>/dev/null)
assert_eq 'builtin_apply_list_tail' "$got" '15'

# --- Case 6: fixed-arity callee (variadic == null; eager spread) ---
got=$("$BIN" -e "(apply (fn* [a b c d] (+ a b c d)) 1 '(2 3 4))" 2>/dev/null)
assert_eq 'fixed_arity_apply_list_tail' "$got" '10'

# --- Case 7: nil tail (empty rest) ---
got=$("$BIN" -e "(apply (fn* [& xs] (count xs)) nil)" 2>/dev/null)
assert_eq 'bind_direct_nil_empty_rest' "$got" '0'

# --- Case 8: leading != variadic.arity (gate misses; eager spread) ---
# Callee variadic arity = 1; leading count = 0; trailing list (5 elts).
# Gate condition `v.arity == leading.len` fails → eager spread →
# args = [10 20 30 40 50], a=10, xs=(20 30 40 50), count = 4.
got=$("$BIN" -e "(apply (fn* [a & xs] (count xs)) '(10 20 30 40 50))" 2>/dev/null)
assert_eq 'gate_miss_arity_mismatch_eager' "$got" '4'

echo
echo "Phase 7 row 7.9 apply variadic e2e: all green."
