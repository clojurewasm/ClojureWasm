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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

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

# --- named fn binds its name in scope for self-recursion (D-147 landed):
#     `(fn name [params] body)` lowers to `(letfn* [name (fn <rest>)] name)` ---
assert_eq 'fn_named_basic'    "$("$BIN" -e '((fn foo [x] x) 1)')"  '1'
assert_eq 'fn_named_selfrec'  "$("$BIN" -e '((fn f [n] (if (= n 0) 1 (* n (f (dec n))))) 5)')"  '120'
assert_eq 'fn_named_multi'    "$("$BIN" -e '((fn g ([x] (g x 0)) ([x y] (+ x y))) 7)')"  '7'
# --- self-name reaches the Function VALUE, not just scope (D-325 / ADR-0121):
#     `(fn name ..)` lowers to `(letfn* [name (fn ..)] name)`, and the ADR-0119
#     letfn naming patch (analyzeLetfnStar) names the inner fn after its binding,
#     so the named fn prints `#<user/name>` (not the gensym `#<user/fn__N>`).
#     Pins that the self-name is on the value, closing D-325. ---
assert_eq 'fn_named_printform' "$("$BIN" -e '(pr-str (fn foo [x] x))')"  '"#<user/foo>"'
# --- empty-body arity → nil (clj parity; medley deep-merge's `([])`) ---
assert_eq 'fn_empty_body'     "$("$BIN" -e '((fn []))')"                                  'nil'
assert_eq 'fn_empty_arity'    "$("$BIN" -e '[((fn ([]) ([a] a))) ((fn ([]) ([a] a)) 5)]')" '[nil 5]'
assert_eq 'defn_empty_body'   "$("$BIN" -e '(do (defn ebq []) (ebq))')"                   'nil'

echo
echo "Phase 14 D-145 fn macro e2e: all green."
