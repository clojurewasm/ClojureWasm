#!/usr/bin/env bash
# test/e2e/phase14_defn_docstring.sh — defn with a leading docstring and/or
# attr-map (D-091). JVM defn accepts (defn name doc-string? attr-map? [params]
# body) and the multi-arity equivalent; cljw previously raised "defn parameter
# list must be a vector". The fn is defined correctly; :doc/attr metadata
# attachment awaits var-metadata support (separate gap). A string AFTER the
# params is the body, not a docstring (regression guard). clj-grounded.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# single-arity + docstring
assert_eq 'doc_single'   "$("$BIN" -e '(do (defn f "squares x" [x] (* x x)) (f 4))')"      '16'
# single-arity + docstring + attr-map
assert_eq 'doc_attr'     "$("$BIN" -e '(do (defn g "doc" {:m 1} [x] x) (g 7))')"            '7'
# attr-map without docstring
assert_eq 'attr_only'    "$("$BIN" -e '(do (defn h {:m 1} [x] (inc x)) (h 4))')"            '5'
# multi-arity + docstring
assert_eq 'doc_multi'    "$("$BIN" -e '(do (defn k "doc" ([x] x) ([x y] (+ x y))) [(k 5) (k 5 6)])')" '[5 11]'
# multi-arity + docstring + attr-map
assert_eq 'doc_attr_mul' "$("$BIN" -e '(do (defn p "d" {:m 1} ([x] x) ([x y] (* x y))) [(p 3) (p 3 4)])')" '[3 12]'
# REGRESSION GUARD: a string after the params is the BODY, not a docstring
assert_eq 'str_is_body'  "$("$BIN" -e '(do (defn f [x] "ret") (f 9))')"                     '"ret"'
# still errors when no params vector at all
out="$("$BIN" -e '(defn f "doc")' 2>&1 || true)"; [[ "$out" == *"defn"* ]] || fail "incomplete: $out"; echo "PASS incomplete -> err"

# --- raw `def` docstring form: (def name doc-string init) → :doc in Var.meta ---
assert_eq 'def_doc'      "$("$BIN" -e '(do (def dv "the docs" 5) [dv (:doc (meta (var dv)))])')" '[5 "the docs"]'
# def docstring merges with reader ^meta
assert_eq 'def_doc_meta' "$("$BIN" -e '(do (def ^:private dp "d2" 9) [dp (:doc (meta (var dp))) (:private (meta (var dp)))])')" '[9 "d2" true]'
# REGRESSION GUARD: a 4-element def whose 3rd item is NOT a string is an arity error
out="$("$BIN" -e '(def bad 1 2)' 2>&1 || true)"; [[ "$out" == *"def"* ]] || fail "def 4-arg non-string: $out"; echo "PASS def_4arg_nonstring -> err"

echo "OK — phase14_defn_docstring (10 cases) green"
