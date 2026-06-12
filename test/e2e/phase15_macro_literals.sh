#!/usr/bin/env bash
# test/e2e/phase15_macro_literals.sh — valueToForm numeric+regex literal family
# (D-232, from upstream `for` / `other_functions`). A macro whose expansion
# contains a ratio / bigint / bigdecimal / char / regex literal must re-analyse
# (valueToForm). Defmacro + call are two top-level forms in ONE process (a macro
# isn't registered until its top-level form completes). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'ratio'   "$("$BIN" -e '(defmacro m [] `~(/ 1 2)) (m)' 2>&1 | tail -1)" '1/2'
assert_eq 'bigint'  "$("$BIN" -e '(defmacro m [] `~(* 99999999999 99999999999)) (m)' 2>&1 | tail -1)" '9999999999800000000001N'
assert_eq 'bigdec'  "$("$BIN" -e '(defmacro m [] `~(+ 1.50M 2.25M)) (m)' 2>&1 | tail -1)" '3.75M'
assert_eq 'char'    "$("$BIN" -e '(defmacro m [] `~(char 98)) (m)' 2>&1 | tail -1)" '\b'
assert_eq 'mixed'   "$("$BIN" -e '(defmacro m [] `[~(/ 3 4) ~(bigint 123) ~(char 99)]) (m)' 2>&1 | tail -1)" '[3/4 123N \c]'
assert_eq 'regex'   "$("$BIN" -e '(defmacro m [] `(re-find #"a.c" "xabcy")) (m)' 2>&1 | tail -1)" '"abc"'

echo "OK — phase15_macro_literals (6 cases) green"
