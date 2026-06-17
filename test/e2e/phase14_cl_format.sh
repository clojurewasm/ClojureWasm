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
# ~C char + ~& fresh-line (D-455 long-tail; clj-oracle byte-matched)
assert_eq 'char_iter'   "$(run '(prn (pp/cl-format nil "~{~c~^, ~}" "hello"))')" '"h, e, l, l, o"'
assert_eq 'char_one'    "$(run '(prn (pp/cl-format nil "~C" (char 65)))')"       '"A"'
assert_eq 'freshline'   "$(run '(prn (pp/cl-format nil "ab~&cd"))')"             '"ab\ncd"'
assert_eq 'fresh_collapse' "$(run '(prn (pp/cl-format nil "ab~&~&cd"))')"        '"ab\ncd"'
assert_eq 'fresh_atstart'  "$(run '(prn (pp/cl-format nil "~&top"))')"           '"top"'
assert_eq 'fresh_n'        "$(run '(prn (pp/cl-format nil "x~3&y"))')"           '"x\n\n\ny"'

# ~P plural / ~* arg-jump / ~T tabulate (D-455 long-tail; arg-navigator; clj-oracle)
assert_eq 'plural_one'  "$(run '(prn (pp/cl-format nil "~D dog~:P" 1))')"        '"1 dog"'
assert_eq 'plural_many' "$(run '(prn (pp/cl-format nil "~D dog~:P" 2))')"        '"2 dogs"'
assert_eq 'plural_y'    "$(run '(prn (pp/cl-format nil "~D pupp~:@P" 2))')"      '"2 puppies"'
assert_eq 'star_skip'   "$(run '(prn (pp/cl-format nil "~a~*~a" 1 2 3))')"       '"13"'
assert_eq 'star_abs'    "$(run '(prn (pp/cl-format nil "~a ~2@*~a" 1 2 3))')"    '"1 3"'
assert_eq 'tab_col'     "$(run '(prn (pp/cl-format nil "ab~10Tcd"))')"           '"ab        cd"'
assert_eq 'tab_inc'     "$(run '(prn (pp/cl-format nil "~a~,8T~a" "abc" "z"))')" '"abc      z"'

# ~$ monetary (D-455 chunk3; clj-oracle: ~d,n,w,padchar$ — d=2/n=1/w=0 defaults)
assert_eq 'money_basic' "$(run '(prn (pp/cl-format nil "~$" 3.14159))')"         '"3.14"'
assert_eq 'money_int'   "$(run '(prn (pp/cl-format nil "~$" 5))')"               '"5.00"'
assert_eq 'money_npad'  "$(run '(prn (pp/cl-format nil "~,4$" 3.14159))')"       '"0003.14"'
assert_eq 'money_width' "$(run '(prn (pp/cl-format nil "~,,8$" 3.14))')"         '"    3.14"'
assert_eq 'money_sign'  "$(run '(prn (pp/cl-format nil "~@$" 3.14))')"           '"+3.14"'
assert_eq 'money_neg'   "$(run '(prn (pp/cl-format nil "~$" -3.14159))')"        '"-3.14"'
assert_eq 'money_dn'    "$(run '(prn (pp/cl-format nil "~3,5$" 22.375))')"       '"00022.375"'
assert_eq 'money_dnw'   "$(run '(prn (pp/cl-format nil "~3,5,10$" 22.375))')"    '" 00022.375"'
assert_eq 'money_at_w'  "$(run '(prn (pp/cl-format nil "~3,5,14@$" 22.375))')"   '"    +00022.375"'
assert_eq 'money_atcol' "$(run '(prn (pp/cl-format nil "~3,5,14@:$" 22.375))')"  '"+    00022.375"'
assert_eq 'money_round' "$(run '(prn (pp/cl-format nil "~1$" 0.99))')"           '"1.0"'

# ~E exponential / ~G general float (D-455 chunk3b; CLtL Steele; clj-oracle).
# The 'X overflow/exponent-char param variants break shell single-quoting; their
# full surface is oracle-verified in the foo-e/foo-g torture probes (see note).
assert_eq 'exp_basic'  "$(run '(prn (pp/cl-format nil "~E" 3.14159))')"          '"3.14159E+0"'
assert_eq 'exp_big'    "$(run '(prn (pp/cl-format nil "~E" 1234.5))')"           '"1.2345E+3"'
assert_eq 'exp_wd'     "$(run '(prn (pp/cl-format nil "~10,3E" 0.8))')"          '"  8.000E-1"'
assert_eq 'exp_round'  "$(run '(prn (pp/cl-format nil "~10,2E" 9.99999))')"      '"   1.00E+1"'
assert_eq 'exp_e100'   "$(run '(prn (pp/cl-format nil "~10,2E" 9.99999E99))')"   '" 1.00E+100"'
assert_eq 'exp_neg'    "$(run '(prn (pp/cl-format nil "~E" -3.14159))')"         '"-3.14159E+0"'
assert_eq 'gen_fixed'  "$(run '(prn (pp/cl-format nil "~9,2G" 3.14159))')"       '"  3.1    "'
assert_eq 'gen_exp'    "$(run '(prn (pp/cl-format nil "~9,2G" 314.159))')"       '"  3.14E+2"'
assert_eq 'gen_wd'     "$(run '(prn (pp/cl-format nil "~10,3G" 0.8))')"          '" 0.800    "'
assert_eq 'gen_ratio'  "$(run '(prn (pp/cl-format nil "~10,3g" 4/5))')"          '" 0.800    "'

# ~[ conditional (D-455 chunk4a; clj-oracle square-bracket-tests; nesting-aware)
assert_eq 'cond_idx0'  "$(run '(prn (pp/cl-format nil "I ~[don'"'"'t ~]have one" 0))')"  '"I don'"'"'t have one"'
assert_eq 'cond_idx1'  "$(run '(prn (pp/cl-format nil "I ~[don'"'"'t ~]have one" 1))')"  '"I have one"'
assert_eq 'cond_semi'  "$(run '(prn (pp/cl-format nil "~[a~;b~;c~]" 1))')"               '"b"'
assert_eq 'cond_deflt' "$(run '(prn (pp/cl-format nil "~[a~;b~:;d~]" 9))')"              '"d"'
assert_eq 'cond_bool'  "$(run '(prn (pp/cl-format nil "~:[no~;yes~]" true))')"           '"yes"'
assert_eq 'cond_boolf' "$(run '(prn (pp/cl-format nil "~:[no~;yes~]" nil))')"            '"no"'
assert_eq 'cond_at_nil' "$(run '(prn (pp/cl-format nil "x~@[ (~D)~]" nil))')"            '"x"'
assert_eq 'cond_at_val' "$(run '(prn (pp/cl-format nil "x~@[ (~D)~]" 7))')"              '"x (7)"'
assert_eq 'cond_nest'  "$(run '(prn (pp/cl-format nil "~[B ~D~:[~; ok~]~;R~]." 0 7 true))')" '"B 7 ok."'

# ~< justification (D-455 chunk4b; clj-oracle angle-bracket-tests; ~mincol,colinc,minpad,padchar<)
assert_eq 'just_none'  "$(run '(prn (pp/cl-format nil "~<foo~;bar~;baz~>"))')"           '"foobarbaz"'
assert_eq 'just_w'     "$(run '(prn (pp/cl-format nil "~20<foo~;bar~;baz~>"))')"         '"foo      bar     baz"'
assert_eq 'just_minpad' "$(run '(prn (pp/cl-format nil "~,,2<foo~;bar~;baz~>"))')"       '"foo  bar  baz"'
assert_eq 'just_colon' "$(run '(prn (pp/cl-format nil "~20:<~A~;~A~;~A~>" "foo" "bar" "baz"))')" '"    foo    bar   baz"'
assert_eq 'just_at'    "$(run '(prn (pp/cl-format nil "~20@<~A~;~A~;~A~>" "foo" "bar" "baz"))')" '"foo    bar    baz   "'
assert_eq 'just_atcol' "$(run '(prn (pp/cl-format nil "~20@:<~A~;~A~;~A~>" "foo" "bar" "baz"))')" '"   foo   bar   baz  "'
assert_eq 'just_colinc' "$(run '(prn (pp/cl-format nil "~10,10<~A~;~A~;~A~>" "foo" "bar" "baz"))')" '"foo barbaz"'
assert_eq 'just_caret' "$(run '(prn (pp/cl-format nil "~20<~A~;~^~A~;~^~A~>" "foo" "bar"))')" '"foo              bar"'

# still-unimplemented directive raises explicitly (not silent mishandle): the V/#
# runtime-valued params (D-458) + the ~<…~:;…~> pretty-print column mode (no writer).
assert_eq 'unsupported-raises' "$(run '(prn (try (pp/cl-format nil "~VD" 5 42) (catch Throwable e :raised)))')" ':raised'

echo "OK — phase14_cl_format (82 cases) green"
