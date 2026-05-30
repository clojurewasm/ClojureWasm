#!/usr/bin/env bash
# test/e2e/phase14_format.sh — format (clojure.core/format, D-134). printf
# subset %s %d %f %.Nf %x %% %n; no width/flags (those raise). %f defaults to
# 6 fractional digits (printf-faithful); %.Nf controls precision.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'plain'   "$("$BIN" -e '(format "hello")')"            '"hello"'
assert_eq 'd'       "$("$BIN" -e '(format "%d items" 3)')"       '"3 items"'
assert_eq 'sd'      "$("$BIN" -e '(format "%s = %d" "x" 42)')"   '"x = 42"'
assert_eq 'f6'      "$("$BIN" -e '(format "%f" 1.5)')"           '"1.500000"'
assert_eq 'fprec'   "$("$BIN" -e '(format "%.2f" 3.14159)')"     '"3.14"'
assert_eq 'f0'      "$("$BIN" -e '(format "%.0f" 3.7)')"         '"4"'
assert_eq 'hex'     "$("$BIN" -e '(format "%x" 255)')"           '"ff"'
assert_eq 'pct'     "$("$BIN" -e '(format "100%%")')"            '"100%"'
assert_eq 'kw'      "$("$BIN" -e '(format "%s/%s" :a :b)')"      '":a/:b"'
assert_eq 'multi'   "$("$BIN" -e '(format "%d-%d-%d" 1 2 3)')"   '"1-2-3"'
assert_eq 'newline' "$("$BIN" -e '(count (format "x%ny"))')"     '3'
assert_eq 'nl_mid'  "$("$BIN" -e '(vec (clojure.string/split (format "x%ny") #"\n"))')" '["x" "y"]'
assert_has 'badtype' "$("$BIN" -e '(format "%d" "x")' 2>&1)"     'expected integer'
assert_has 'fewargs' "$("$BIN" -e '(format "%d")' 2>&1)"         'not enough arguments'
assert_has 'width'   "$("$BIN" -e '(format "%5d" 3)' 2>&1)"      'unsupported directive'
assert_has 'fmtstr'  "$("$BIN" -e '(format 42)' 2>&1)"           'expected string'
echo "OK — phase14_format smoke (16 cases) green"
