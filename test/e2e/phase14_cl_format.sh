#!/usr/bin/env bash
# test/e2e/phase14_cl_format.sh — clojure.pprint/cl-format (D-403 + D-455).
# Directive set: ~A (aesthetic) / ~S (standard) / ~D (decimal, +mincol,'pad +:grouped)
# / ~F (fixed float ~w,df) / ~X ~O (radix) / ~B (binary) / ~% (newline) / ~~ (tilde).
# Number directives parse the `~mincol,'padchar` parameter grammar + delegate to
# `format`. `(cl-format nil fmt & args)` returns the string; still-deferred directives
# (~{~} iteration, ~R cardinal, ~:( case) raise explicitly. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
(require '[clojure.pprint :as pp])
$1
EOF
}

assert_eq 'aesthetic'  "$(run '(prn (pp/cl-format nil "~a + ~a = ~a" 1 2 3))')"  '"1 + 2 = 3"'
assert_eq 'standard'   "$(run '(prn (pp/cl-format nil "~s" "hi"))')"             '"\"hi\""'
assert_eq 'decimal'    "$(run '(prn (pp/cl-format nil "~d items" 42))')"         '"42 items"'
assert_eq 'newline'    "$(run '(prn (pp/cl-format nil "a~%b"))')"                '"a\nb"'
assert_eq 'tilde'      "$(run '(prn (pp/cl-format nil "100~~"))')"               '"100~"'
assert_eq 'aesthetic-string' "$(run '(prn (pp/cl-format nil "[~a]" "x"))')"      '"[x]"'
# D-455 number directives (clj-verified): float / radix / grouping / padding
assert_eq 'fixed-float'  "$(run '(prn (pp/cl-format nil "~,2f" 3.14159))')"      '"3.14"'
assert_eq 'fixed-float-w' "$(run '(prn (pp/cl-format nil "~,3f" 1.5))')"         '"1.500"'
assert_eq 'hex'          "$(run '(prn (pp/cl-format nil "~x" 255))')"            '"ff"'
assert_eq 'octal'        "$(run '(prn (pp/cl-format nil "~o" 64))')"            '"100"'
assert_eq 'binary'       "$(run '(prn (pp/cl-format nil "~b" 10))')"            '"1010"'
assert_eq 'grouped'      "$(run '(prn (pp/cl-format nil "~:d" 1000000))')"       '"1,000,000"'
assert_eq 'zero-padded'  "$(run '(prn (pp/cl-format nil "~5,'"'"'0d" 42))')"     '"00042"'
assert_eq 'star-padded'  "$(run '(prn (pp/cl-format nil "~8,'"'"'*d" 42))')"     '"******42"'
assert_eq 'hex-width'    "$(run '(prn (pp/cl-format nil "~6x" 255))')"           '"    ff"'
# D-455 iteration ~{~^~} (clj-verified): apply the enclosed format per list element,
# ~^ exits before the trailing separator on the last element.
assert_eq 'iter-join'    "$(run '(prn (pp/cl-format nil "~{~a~^, ~}" [1 2 3]))')" '"1, 2, 3"'
assert_eq 'iter-around'  "$(run '(prn (pp/cl-format nil "[~{~a~^ | ~}]" [:a :b :c]))')" '"[:a | :b | :c]"'
assert_eq 'iter-empty'   "$(run '(prn (pp/cl-format nil "~{~a~^, ~}" []))')"      '""'
assert_eq 'iter-pairs'   "$(run '(prn (pp/cl-format nil "~{~a=~a ~}" [:x 1 :y 2]))')" '":x=1 :y=2 "'
# D-455 case directives (clj-verified): ~( lower / ~:( cap-each-word / ~@( cap-first / ~:@( upper
assert_eq 'case-lower'   "$(run '(prn (pp/cl-format nil "~(~a~)" "Hello WORLD"))')" '"hello world"'
assert_eq 'case-words'   "$(run '(prn (pp/cl-format nil "~:(~a~)" "hello world"))')" '"Hello World"'
assert_eq 'case-first'   "$(run '(prn (pp/cl-format nil "~@(~a~)" "hello WORLD"))')" '"Hello world"'
assert_eq 'case-upper'   "$(run '(prn (pp/cl-format nil "~:@(~a~)" "hello world"))')" '"HELLO WORLD"'
# D-455 ~R numeral directive (clj-verified): cardinal / ordinal / Roman / radix
assert_eq 'cardinal'     "$(run '(prn (pp/cl-format nil "~r" 42))')"             '"forty-two"'
assert_eq 'cardinal-big' "$(run '(prn (pp/cl-format nil "~r" 1234567))')"        '"one million, two hundred thirty-four thousand, five hundred sixty-seven"'
assert_eq 'ordinal'      "$(run '(prn (pp/cl-format nil "~:r" 42))')"            '"forty-second"'
assert_eq 'roman'        "$(run '(prn (pp/cl-format nil "~@r" 99))')"            '"XCIX"'
assert_eq 'radix'        "$(run '(prn (pp/cl-format nil "~16r" 255))')"          '"ff"'
# still-unimplemented directive raises explicitly (not silent mishandle)
assert_eq 'unsupported-raises' "$(run '(prn (try (pp/cl-format nil "~p" 2) (catch Throwable e :raised)))')" ':raised'

echo "OK — phase14_cl_format (30 cases) green"
