#!/usr/bin/env bash
# test/e2e/phase14_string_getbytes.sh — (.getBytes s [charset]) (D-425). UTF-8
# bytes of s as a cljw byte .array of SIGNED-byte ints (clj byte[] parity: a
# byte > 127 is negative). cljw is UTF-8-only; a charset arg is accepted, UTF-8
# always used. (String. bytes) + StandardCharsets are a follow-up.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'ascii'      "$("$BIN" -e '(seq (.getBytes "abc"))' 2>/dev/null | tail -1)" '(97 98 99)'
assert_eq 'utf8_signed' "$("$BIN" -e '(seq (.getBytes "é"))' 2>/dev/null | tail -1)" '(-61 -87)'
assert_eq 'is_array'   "$("$BIN" -e '(alength (.getBytes "abc"))' 2>/dev/null | tail -1)" '3'
assert_eq 'charset_arg' "$("$BIN" -e '(vec (.getBytes "hi" "UTF-8"))' 2>/dev/null | tail -1)" '[104 105]'
assert_eq 'empty'      "$("$BIN" -e '(seq (.getBytes ""))' 2>/dev/null | tail -1)" 'nil'
# round-trips through aget (it is a real byte array)
assert_eq 'aget0'      "$("$BIN" -e '(aget (.getBytes "Xyz") 0)' 2>/dev/null | tail -1)" '88'

echo "OK — phase14_string_getbytes (6 cases) green"
