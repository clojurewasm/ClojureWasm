#!/usr/bin/env bash
# test/e2e/phase14_print_control.sh — *print-length* / *print-level* (ADR-0088)
# across the non-pr-str print surfaces (str / prn / println). The pr-str cases
# live in the print_control clj-diff corpus; this guards the str + stdout paths.
# Note: `cljw -e` echoes each top-level form's RETURN value, so prn/println
# (return nil) add a trailing `nil` line; str returns the (quoted) string.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> ok"; }

# str of a collection routes through printResult → *print-length* truncates.
assert_eq 'str_len'    "$("$BIN" -e '(binding [*print-length* 2] (str [1 2 3 4]))')"   '"[1 2 ...]"'
# str + *print-level*.
assert_eq 'str_level'  "$("$BIN" -e '(binding [*print-level* 1] (str {:a {:b 1}}))')"  '"{:a #}"'
# Default (unbound) str prints in full — no behaviour change.
assert_eq 'str_default' "$("$BIN" -e '(str (range 6))')"                               '"(0 1 2 3 4 5)"'
# prn to stdout honours *print-length* (then the -e echo adds the nil return).
assert_eq 'prn_stdout' "$("$BIN" -e '(binding [*print-length* 3] (prn (range 10)))')"  '(0 1 2 ...)
nil'
# println (raw) truncates the collection too.
assert_eq 'println'    "$("$BIN" -e '(binding [*print-length* 1] (println [10 20 30]))')" '[10 ...]
nil'
# Binding is dynamic-extent: a second prn outside the binding prints in full.
assert_eq 'extent'     "$("$BIN" -e '(do (binding [*print-length* 1] (prn [9 9 9])) (prn [1 2 3]))')" '[9 ...]
[1 2 3]
nil'
echo "OK — phase14_print_control smoke (6 cases) green"
