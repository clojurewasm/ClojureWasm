#!/usr/bin/env bash
# test/e2e/phase14_parse.sh — parse-long / parse-double / parse-boolean
# (clojure.core 1.11, D-134). Parse a string → value, nil if unparseable,
# type error for a non-string arg (JVM takes a CharSequence).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# parse-long
assert_eq 'pl_pos'   "$("$BIN" -e '(parse-long "42")')"   '42'
assert_eq 'pl_neg'   "$("$BIN" -e '(parse-long "-7")')"   '-7'
assert_eq 'pl_bad'   "$("$BIN" -e '(parse-long "abc")')"  'nil'
assert_eq 'pl_empty' "$("$BIN" -e '(parse-long "")')"     'nil'
assert_eq 'pl_float' "$("$BIN" -e '(parse-long "3.5")')"  'nil'
assert_has 'pl_type' "$("$BIN" -e '(parse-long 42)' 2>&1)" 'expected string'
# parse-double
assert_eq 'pd_dec'   "$("$BIN" -e '(parse-double "3.14")')" '3.14'
assert_eq 'pd_exp'   "$("$BIN" -e '(parse-double "1e3")')"  '1000.0'
assert_eq 'pd_int'   "$("$BIN" -e '(parse-double "5")')"    '5.0'
assert_eq 'pd_bad'   "$("$BIN" -e '(parse-double "x")')"    'nil'
# parse-boolean
assert_eq 'pb_true'  "$("$BIN" -e '(parse-boolean "true")')"  'true'
assert_eq 'pb_false' "$("$BIN" -e '(parse-boolean "false")')" 'false'
assert_eq 'pb_other' "$("$BIN" -e '(parse-boolean "yes")')"   'nil'
echo "OK — phase14_parse smoke (13 cases) green"
