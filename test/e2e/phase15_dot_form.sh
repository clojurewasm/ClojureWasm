#!/usr/bin/env bash
# test/e2e/phase15_dot_form.sh — the `.` interop special form (D-232).
# `(. recv member)`, `(. recv member args…)`, and `(. recv (member args…))`
# are the canonical interop primitive that `(.member recv …)` / `(Class/m …)`
# sugar over. Lowers to the existing InteropCallNode: static when the receiver
# is a class with the method, else an instance member. clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# instance member, no args
assert_eq 'inst-noarg' "$("$BIN" -e '(. "abc" toUpperCase)' 2>&1 | tail -1)" '"ABC"'
# instance member, flat args
assert_eq 'inst-args'  "$("$BIN" -e '(. "abcd" substring 1 3)' 2>&1 | tail -1)" '"bc"'
# instance member, (member args) list shape
assert_eq 'inst-list'  "$("$BIN" -e '(. "abcd" (substring 1 3))' 2>&1 | tail -1)" '"bc"'
# static method (class receiver), flat args
assert_eq 'static'     "$("$BIN" -e '(. Math abs -3)' 2>&1 | tail -1)" '3'
# static method, list shape
assert_eq 'static-list' "$("$BIN" -e '(. Math (abs -3))' 2>&1 | tail -1)" '3'
# regression: the (.member recv) sugar still works
assert_eq 'sugar-still' "$("$BIN" -e '(.toUpperCase "hi")' 2>&1 | tail -1)" '"HI"'

echo "OK — phase15_dot_form (6 cases) green"
