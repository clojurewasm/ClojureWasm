#!/usr/bin/env bash
# test/e2e/phase14_syntax_quote.sh — syntax-quote `` ` ``/`~`/`~@`/`foo#` (D-226,
# ADR-0082, STAGE 1: non-qualifying). Unquote/splice/auto-gensym work; symbols
# stay bare (full ns-qualification is stage 2), so single-ns + core-symbol macros
# run. A macro must be DEFINED before use (separate top-level forms — the same-
# form `(do (defmacro …)(use))` limitation is pre-existing). cljw -e prints each
# top-level form's value, so macro cases read the last line. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# literal templates (qualification-free → clj-identical values)
assert_eq 'unquote'  "$("$BIN" -e '`(1 2 ~(+ 1 2))')"            '(1 2 3)'
assert_eq 'vec'      "$("$BIN" -e '`[1 ~(* 2 2) 3]')"           '[1 4 3]'
assert_eq 'splice'   "$("$BIN" -e '`(0 ~@(list 1 2 3) 4)')"      '(0 1 2 3 4)'
assert_eq 'map'      "$("$BIN" -e '`{:a ~(+ 1 1)}')"            '{:a 2}'
assert_eq 'empty'    "$("$BIN" -e '`()')"                       '()'
assert_eq 'splice2x' "$("$BIN" -e '(let [xs [1 2]] `[~@xs ~@xs])')" '[1 2 1 2]'

# macros (defined then used as SEPARATE top-level forms; read the result line)
assert_eq 'mac_inc'  "$("$BIN" -e '(defmacro m-inc [x] `(+ ~x 1)) (m-inc 41)' 2>&1 | tail -1)" '42'
assert_eq 'mac_when' "$("$BIN" -e '(defmacro m-when [t & b] `(if ~t (do ~@b) nil)) (m-when true 7 8 9)' 2>&1 | tail -1)" '9'
assert_eq 'mac_when_f' "$("$BIN" -e '(defmacro m-when [t & b] `(if ~t (do ~@b) nil)) (m-when false 99)' 2>&1 | tail -1)" 'nil'
# auto-gensym foo# (consistent within one syntax-quote)
assert_eq 'gensym'   "$("$BIN" -e '(defmacro m-dbl [x] `(let [y# ~x] (+ y# y#))) (m-dbl 21)' 2>&1 | tail -1)" '42'
assert_eq 'gensym_swap' "$("$BIN" -e '(defmacro m-swap [a b] `(let [t# ~a] [~b t#])) (m-swap 1 2)' 2>&1 | tail -1)" '[2 1]'
# stage 2: symbol qualification (clj hygiene)
assert_eq 'qual_user'  "$("$BIN" -e '(pr-str `foo)')"           '"user/foo"'
assert_eq 'qual_core'  "$("$BIN" -e '(pr-str `+)')"            '"clojure.core/+"'
assert_eq 'qual_form'  "$("$BIN" -e "(pr-str \`(if x y z))")"  '"(if user/x user/y user/z)"'
assert_eq 'qual_class' "$("$BIN" -e '(pr-str `Throwable)')"    '"Throwable"'
# THE stage-2 win: a macro referencing its OWN ns private helper resolves
assert_eq 'helper'   "$("$BIN" -e '(defn helper [x] (* x 10)) (defmacro mh [x] `(helper ~x)) (mh 5)' 2>&1 | tail -1)" '50'
# try/catch macro with a gensym binding (bare binding is a clj-faithful error)
assert_eq 'try_mac'  "$("$BIN" -e '(defmacro mt [x] `(try ~x (catch Throwable e# :caught))) (mt (/ 1 0))' 2>&1 | tail -1)" ':caught'

# ~ outside a syntax-quote errors
if "$BIN" -e '~x' >/dev/null 2>&1; then fail 'unquote_bare: should error'; fi
echo 'PASS unquote_bare -> errors'

echo "OK — phase14_syntax_quote (18 cases) green"
