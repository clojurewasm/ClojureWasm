#!/usr/bin/env bash
# test/e2e/phase14_print_family.sh
#
# Phase 14 §9.16 row 14.13 — D-127 discharge. clojure.core print family:
# pr-str / prn / print. JVM splits readable (pr/prn/pr-str: strings
# quoted) from human (print/println: strings unquoted). cw v1 already
# ships println; this cluster adds the other three.
#
# `cljw -e` prints the form's return value after side-effect output, so
# each case asserts on the FIRST line (the side effect) via head -1.
# `print` emits no trailing newline, so its output merges with the
# printed `nil` return (e.g. `hinil`) — that merge is the assertion.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
first_line() { printf '%s' "$1" | head -1; }
assert_first() {
    local name="$1"; local expr="$2"; local want="$3"
    local got; got="$(first_line "$("$BIN" -e "$expr" 2>/dev/null)")"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- prn: readable, strings quoted, trailing newline ---
assert_first 'prn_string'  '(prn "hi")'   '"hi"'
assert_first 'prn_vector'  '(prn [1 2])'  '[1 2]'

# --- print: human, strings unquoted, NO trailing newline (merges nil) ---
assert_first 'print_unquoted' '(print "hi")'  'hinil'
assert_first 'print_spaced'   '(print 1 2)'   '1 2nil'

# --- pr-str: readable value->string (tested via println to show content) ---
assert_first 'pr_str_map'    '(println (pr-str {:a 1}))' '{:a 1}'
assert_first 'pr_str_string' '(println (pr-str "x"))'    '"x"'

# --- D-185: *print-readably* threads into COLLECTION elements, not just the
# top level. print/println render nested strings raw + chars bare; pr/prn/str
# keep them readable. (char 98)=\b, (char 121)=\y. ---
assert_first 'print_coll_str'  '(print ["a" "b"])'                '[a b]nil'
assert_first 'print_coll_mix'  '(print ["a" (char 98) {:k "v"}])' '[a b {:k v}]nil'
assert_first 'println_list'    '(println (list "x" (char 121)))'  '(x y)'
assert_first 'prn_coll_quoted' '(prn ["a" (char 98)])'            '["a" \b]'
assert_first 'str_coll_quoted' '(println (str ["a" (char 98)]))'  '["a" \b]'

echo "ALL phase14_print_family PASS"
