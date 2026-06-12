#!/usr/bin/env bash
# test/e2e/phase14_regex_lookahead.sh
#
# Regex zero-width lookahead `(?=e)` / `(?!e)` (ADR-0115). Compiled to a `look`
# inst whose sub-program runs anchored at the current position consuming nothing
# (the Pike NFA's epsilon-closure runs it like an anchor). A positive lookahead's
# inner captures thread through (full JVM parity, no divergence). Values
# clj-oracle-confirmed. Unblocks honeysql (`honey.sql/dehyphen` uses `#"(\w)-(?=\w)"`).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

# honeysql dehyphen — the driving case
assert_eq 'dehyphen'  "$(run '(clojure.string/replace "a-b-c" #"(\w)-(?=\w)" "$1 ")')" '"a b c"'
# positive lookahead: matches (consumes nothing), so the body is just "foo"
assert_eq 'pos_hit'   "$(run '(re-find #"foo(?=bar)" "foobar")')" '"foo"'
assert_eq 'pos_miss'  "$(run '(nil? (re-find #"foo(?=bar)" "foobaz"))')" 'true'
# negative lookahead
assert_eq 'neg_hit'   "$(run '(re-find #"foo(?!bar)" "foobaz")')" '"foo"'
assert_eq 'neg_miss'  "$(run '(nil? (re-find #"foo(?!bar)" "foobar"))')" 'true'
# lookahead does not consume — the trailing "px" stays unmatched
assert_eq 'no_consume' "$(run '(re-find #"\d+(?=px)" "10px")')" '"10"'
# re-seq across a separator via lookahead (last token has no trailing comma)
assert_eq 'reseq'     "$(run '(re-seq #"\w+(?=,)" "a,b,c")')" '("a" "b")'
# alternation inside a lookahead
assert_eq 'alt_look'  "$(run '(re-find #"x(?=a|b)" "xb")')" '"x"'
# captures INSIDE a positive lookahead thread through (full JVM parity, no AD)
assert_eq 'cap_look'  "$(run '(re-find #"(?=(\w+))\w+" "abc")')" '["abc" "abc"]'
assert_eq 'cap_mixed' "$(run '(re-find #"(\w)-(?=(\w))" "a-b")')" '["a-" "a" "b"]'
