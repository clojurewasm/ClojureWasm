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

# *print-dup* / *flush-on-newline* (D-222 residual c). Roots match clj
# (false / true); binding print-dup false prints normally; binding
# flush-on-newline false still works (cljw's text_io flushes per call —
# flushing more than requested is a valid implementation of false).
assert_eq 'dup_root'     "$("$BIN" -e '*print-dup*')"            'false'
assert_eq 'fon_root'     "$("$BIN" -e '*flush-on-newline*')"     'true'
assert_eq 'dup_false'    "$("$BIN" -e '(binding [*print-dup* false] (pr-str {:a 1}))')" '"{:a 1}"'
assert_eq 'fon_false'    "$("$BIN" -e '(binding [*flush-on-newline* false] (with-out-str (println "x")))')" '"x\n"'
# set! works at top level (baseline binding frame, ADR-0096).
assert_eq 'fon_set'      "$("$BIN" -e '(set! *flush-on-newline* false) *flush-on-newline*')" 'false
false'
# *print-dup* TRUE is fail-loud: clj emits JVM #=(class/create …) ctor forms
# cljw cannot represent (no JVM classes, ADR-0059) — an explicit error, never
# a silent normal-form print.
dup_true_out="$("$BIN" -e '(binding [*print-dup* true] (pr-str {:a 1}))' 2>&1 || true)"
case "$dup_true_out" in
  *'print-dup'*) echo "PASS dup_true_raises -> ok" ;;
  *) fail "dup_true_raises: got '$dup_true_out'" ;;
esac

echo "OK — phase14_print_control smoke (12 cases) green"
