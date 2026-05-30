#!/usr/bin/env bash
# test/e2e/phase14_read_string.sh — clojure.core/read-string. In cljw the
# reader has no `#=` eval-reader, so core/read-string is the same full-reader
# readOne→formToValue as clojure.edn/read-string (a safe DIVERGENCE: JVM
# core/read-string can eval). Reads one form from a string as DATA.
#
# Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'rs_int'     "$("$BIN" -e '(read-string "42")')"                  '42'
assert_eq 'rs_vec'     "$("$BIN" -e '(read-string "[1 2 3]")')"             '[1 2 3]'
assert_eq 'rs_map'     "$("$BIN" -e '(read-string "{:a 1 :b 2}")')"         '{:a 1, :b 2}'
assert_eq 'rs_set'     "$("$BIN" -e '(read-string "#{1 2 3}")')"            '#{1 2 3}'
assert_eq 'rs_str'     "$("$BIN" -e '(read-string "\"hi\"")')"              '"hi"'
assert_eq 'rs_kw'      "$("$BIN" -e '(read-string ":foo")')"                ':foo'
assert_eq 'rs_list1st' "$("$BIN" -e '(first (read-string "(a b c)"))')"     'a'
assert_eq 'rs_nested'  "$("$BIN" -e '(read-string "[1 {:a [2 3]}]")')"      '[1 {:a [2 3]}]'
assert_eq 'rs_count'   "$("$BIN" -e '(count (read-string "(1 2 3 4)"))')"   '4'
echo "OK — phase14_read_string (9 cases) green"
