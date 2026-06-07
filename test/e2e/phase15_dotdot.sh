#!/usr/bin/env bash
# test/e2e/phase15_dotdot.sh — clojure.core `..` member-access threading macro.
# `(.. x a b)` expands to `(. (. x a) b)`. cljw had no `..` macro and the
# analyzer's `.`-prefixed dot-arms misparsed the `..` head as a `.` member
# access, so `(.. s toString …)` raised "Unable to resolve symbol". The two
# dot-arms now exclude the exact `..` head, letting it reach the macro.
# Surfaced by honeysql's `(.. s toString (toUpperCase …))`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# single member symbol
assert_eq 'dotdot-one'   "$("$BIN" -e '(.. "hi" toString)' 2>&1 | tail -1)"               '"hi"'
# chained no-arg members
assert_eq 'dotdot-chain' "$("$BIN" -e '(.. "  hi  " trim toUpperCase)' 2>&1 | tail -1)"    '"HI"'
# a (method args) list form in the chain
assert_eq 'dotdot-args'  "$("$BIN" -e '(.. "abcde" toUpperCase (substring 1 3))' 2>&1 | tail -1)" '"BC"'

echo "OK — phase15_dotdot (3 cases) green"
