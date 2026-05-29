#!/usr/bin/env bash
# test/e2e/phase14_fn_macro.sh
#
# D-145 — the `fn` macro. cljw had `fn*` (special form) but not `fn`, so
# `(fn [x] ...)` raised "Unable to resolve symbol: 'fn'" — a coverage-floor
# blocker since real corpus uses `(fn ...)` pervasively. `fn` is a bootstrap
# macro (macro_transforms.zig, the defn template) that rewrites the head to
# `fn*` for the no-name forms — shape-identical to fn* (multi-arity + & rest
# + closures all ride fn* per ADR-0041). Self-name `(fn name ...)` raises a
# clear transient error (D-147 — a dual-backend fn* extension); destructuring
# forwards to fn*'s existing not-supported path (D-076).
#
# Layer 2 (e2e CLI) per ADR-0021.

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
assert_contains() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name -> contains '$want'"
}

# --- basic anonymous fn ---
assert_eq 'fn_basic'    "$("$BIN" -e '((fn [x] (+ x 1)) 41)')"  '42'
# --- as a higher-order arg ---
assert_eq 'fn_hof'      "$("$BIN" -e '(into [] (map (fn [x] (* x 2)) [1 2 3]))')" '[2 4 6]'
# --- multi-arity (rides fn* per ADR-0041) ---
assert_eq 'fn_multi_1'  "$("$BIN" -e '((fn ([x] x) ([x y] (+ x y))) 9)')"   '9'
assert_eq 'fn_multi_2'  "$("$BIN" -e '((fn ([x] x) ([x y] (+ x y))) 3 4)')" '7'
# --- & rest variadic ---
assert_eq 'fn_variadic' "$("$BIN" -e '((fn [x & xs] (count xs)) 1 2 3)')"  '2'
# --- closure capture ---
assert_eq 'fn_closure'  "$("$BIN" -e '(((fn [x] (fn [y] (+ x y))) 3) 4)')"  '7'

# --- self-name raises a CLEAR transient error (D-147), not the confusing
#     fn* "parameter list must be a vector" nor "Unable to resolve 'fn'" ---
diag=$("$BIN" -e '((fn foo [x] x) 1)' 2>&1 || true)
assert_contains 'fn_named_clear_error' "$diag" 'not yet supported'
case "$diag" in
    *"Unable to resolve symbol: 'fn'"*) fail "fn_named: fn still unresolved ($diag)" ;;
esac

echo
echo "Phase 14 D-145 fn macro e2e: all green."
