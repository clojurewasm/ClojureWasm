#!/usr/bin/env bash
# test/e2e/phase14_anon_fn_reader.sh
#
# D-146 — the `#(...)` anonymous-function reader macro. `#(< % 3)` raised
# "Invalid token '#'" (a coverage-floor blocker — terse lambdas are
# pervasive in real corpus). The reader now rewrites `#(body)` at read
# time to `(fn* [p1__N# p2__N# … & rest__N#] body)`, as clj does: `%`≡`%1`,
# `%N` positional (arity = max N), `%&` rest, all renamed to per-literal
# gensyms (ADR-0200: two equal `#()` texts are distinct forms). Rides
# the existing fn* Node (no new analyzer Node, no differential per
# ADR-0036). Nested `#()` is a read error (JVM-compatible — `%` would be
# ambiguous across levels).
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

# --- bare % (≡ %1) ---
assert_eq 'anon_bare_pct'  "$("$BIN" -e '(#(+ % 1) 41)')"  '42'
# --- as a higher-order arg ---
assert_eq 'anon_hof'       "$("$BIN" -e '(into [] (map #(* % %) [1 2 3]))')"  '[1 4 9]'
# --- positional %1 %2 ---
assert_eq 'anon_positional' "$("$BIN" -e '(#(+ %1 %2) 3 4)')"  '7'
# --- mixed bare % + %2 (both canonicalise: % → %1) ---
assert_eq 'anon_mixed'     "$("$BIN" -e '(#(+ % %2) 10 5)')"  '15'
# --- rest %& ---
assert_eq 'anon_rest'      "$("$BIN" -e '(#(apply + %&) 1 2 3)')"  '6'
# --- arity 0 (no % params) ---
assert_eq 'anon_zero'      "$("$BIN" -e '(#(+ 1 2))')"  '3'

# --- nested #() is a read error (not a silent accept) ---
diag=$("$BIN" -e '(#(+ % #(* % 2)) 5)' 2>&1 || true)
assert_contains 'anon_nested_error' "$diag" 'Nested #()'
case "$diag" in
    *"Invalid token"*) fail "anon_nested: still 'Invalid token' — #( not recognised ($diag)" ;;
esac

# ADR-0200 (retired AD-039): the #() params are clj-shaped gensyms, one id
# per literal, so the expansion reads like clj's and two equal literals are
# distinct forms (a set of two `#(inc %)` holds two fns, no duplicate key).
assert_match() { local n="$1" g="$2" re="$3"; [[ "$g" =~ $re ]] || fail "$n: got '$g' want /$re/"; echo "PASS $n -> $g"; }
assert_match 'anon_readform_pct1' "$("$BIN" -e '(read-string "#(+ % 1)")')" \
  '^\(fn\* \[p1__([0-9]+)#\] \(\+ p1__\1# 1\)\)$'
assert_match 'anon_readform_rest' "$("$BIN" -e '(read-string "#(apply + % %&)")')" \
  '^\(fn\* \[p1__([0-9]+)# & rest__\1#\] \(apply \+ p1__\1# rest__\1#\)\)$'
assert_eq 'anon_distinct_forms' "$("$BIN" -e '(= (read-string "#(inc %)") (read-string "#(inc %)"))')" 'false'
assert_eq 'anon_set_of_two'     "$("$BIN" -e '(count #{#(inc %) #(inc %)})')" '2'
assert_eq 'anon_syntax_quoted'  "$("$BIN" -e '(defmacro m [] `(map #(inc %) [1 2])) (m)' 2>&1 | tail -1)" '(2 3)'

echo
echo "Phase 14 D-146 #() anonymous-fn reader macro e2e: all green."
