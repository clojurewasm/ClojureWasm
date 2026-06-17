#!/usr/bin/env bash
# test/e2e/phase14_anon_fn_reader.sh
#
# D-146 — the `#(...)` anonymous-function reader macro. `#(< % 3)` raised
# "Invalid token '#'" (a coverage-floor blocker — terse lambdas are
# pervasive in real corpus). The reader now rewrites `#(body)` at read
# time to `(fn* [%1 %2 … & %&] body)`: `%`≡`%1`, `%N` positional (arity =
# max N), `%&` rest; bare `%` is canonicalised to `%1` in the body. Rides
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

# AD-039 pin: the #() expansion uses DETERMINISTIC params (%1/%2/%&), where clj
# uses non-reproducible gensyms (p1__N#). Behaviour matches; only the printed
# param names differ.
assert_eq 'anon_readform_pct1' "$("$BIN" -e '(read-string "#(+ % 1)")')"     '(fn* [%1] (+ %1 1))'
assert_eq 'anon_readform_rest' "$("$BIN" -e '(read-string "#(apply + % %&)")')" '(fn* [%1 & %&] (apply + %1 %&))'

echo
echo "Phase 14 D-146 #() anonymous-fn reader macro e2e: all green."
