#!/usr/bin/env bash
# test/e2e/phase14_find.sh — D-134 find (map entry [k v] or nil; present-
# nil-value distinguished via contains?). Pattern A .clj, AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'find_hit'    "$("$BIN" -e '(find {:a 1 :b 2} :a)')"  '[:a 1]'
assert_eq 'find_miss'   "$("$BIN" -e '(find {:a 1} :missing)')" 'nil'
assert_eq 'find_nilval' "$("$BIN" -e '(find {:a nil} :a)')"     '[:a nil]'
assert_eq 'find_empty'  "$("$BIN" -e '(find {} :x)')"           'nil'
assert_eq 'find_strkey' "$("$BIN" -e '(find {"k" 9} "k")')"     '["k" 9]'
echo "OK — phase14_find smoke (5 cases) green"
