#!/usr/bin/env bash
# test/e2e/phase14_string_indexed.sh — a String is Indexed (D-217).
# clj treats a String as Indexed (nth) + index-gettable (get) + index-bounds
# (contains?), indexing by char. cljw indexes by codepoint (ASCII matches the
# JVM char; multibyte BMP chars also match). Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# nth: codepoint char at index; default / throw on OOR.
assert_eq 'nth0'      "$("$BIN" -e '(nth "abc" 0)')"          '\a'
assert_eq 'nth2'      "$("$BIN" -e '(nth "abc" 2)')"          '\c'
assert_eq 'nth_def'   "$("$BIN" -e '(nth "abc" 5 :default)')" ':default'
assert_eq 'nth_negd'  "$("$BIN" -e '(nth "abc" -1 :neg)')"    ':neg'
assert_eq 'nth_utf8'  "$("$BIN" -e '(nth "héllo" 1)')"        '\é'
# nth OOR without a default throws (clj StringIndexOutOfBounds parity).
"$BIN" -e '(nth "abc" 5)' >/dev/null 2>&1 && fail 'nth_oor: expected error' || true
echo 'PASS nth_oor -> errors'

# get: codepoint char, else default (OOR / non-integer key → default, no throw).
assert_eq 'get0'      "$("$BIN" -e '(get "abc" 0)')"          '\a'
assert_eq 'get_oor'   "$("$BIN" -e '(get "abc" 10)')"         'nil'
assert_eq 'get_oord'  "$("$BIN" -e '(get "abc" 10 :x)')"      ':x'
assert_eq 'get_negd'  "$("$BIN" -e '(get "abc" -1 :y)')"      ':y'

# contains?: index-bounds test (NOT char membership).
assert_eq 'has0'      "$("$BIN" -e '(contains? "abc" 0)')"    'true'
assert_eq 'has2'      "$("$BIN" -e '(contains? "abc" 2)')"    'true'
assert_eq 'has3'      "$("$BIN" -e '(contains? "abc" 3)')"    'false'
assert_eq 'has_neg'   "$("$BIN" -e '(contains? "abc" -1)')"   'false'
assert_eq 'has_empty' "$("$BIN" -e '(contains? "" 0)')"       'false'

# subs: codepoint-based, and clj bounds-checks (does NOT clamp). start/end
# past the codepoint length (or end < start, or negative) throw
# StringIndexOutOfBounds — cljw raises an index_error, not a clamped substring.
assert_eq 'subs_ok'       "$("$BIN" -e '(subs "hello" 2 4)')"  '"ll"'
assert_eq 'subs_end_eq'   "$("$BIN" -e '(subs "hello" 0 5)')"  '"hello"'
assert_eq 'subs_start_eq' "$("$BIN" -e '(subs "hello" 5)')"    '""'
assert_eq 'subs_utf8'     "$("$BIN" -e '(subs "héllo" 1 3)')"  '"él"'
"$BIN" -e '(subs "hello" 2 10)' >/dev/null 2>&1 && fail 'subs_end_oob: expected error' || true
echo 'PASS subs_end_oob -> errors'
"$BIN" -e '(subs "hello" 6)' >/dev/null 2>&1 && fail 'subs_start_oob: expected error' || true
echo 'PASS subs_start_oob -> errors'
"$BIN" -e '(subs "hello" 3 2)' >/dev/null 2>&1 && fail 'subs_end_lt_start: expected error' || true
echo 'PASS subs_end_lt_start -> errors'
"$BIN" -e '(subs "hello" -1)' >/dev/null 2>&1 && fail 'subs_neg: expected error' || true
echo 'PASS subs_neg -> errors'

echo "OK — phase14_string_indexed (23 cases) green"
