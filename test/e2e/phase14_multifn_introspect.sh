#!/usr/bin/env bash
# test/e2e/phase14_multifn_introspect.sh — multimethod introspection fns
# (methods / get-method / remove-method / prefers) as clojure.core wrappers
# over the rt/ primitives. Surfaced by the multimethod clj-diff sweep
# (the rt/__methods etc. primitives existed but had no public wrapper).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'methods_has'   "$("$BIN" -e '(do (defmulti m1 identity) (defmethod m1 :x [_] :x) (contains? (methods m1) :x))')" 'true'
assert_eq 'methods_count' "$("$BIN" -e '(do (defmulti m2 identity) (defmethod m2 :a [_] 1) (defmethod m2 :b [_] 2) (count (methods m2)))')" '2'
assert_eq 'get_method'    "$("$BIN" -e '(do (defmulti m3 identity) (defmethod m3 :a [_] :A) (some? (get-method m3 :a)))')" 'true'
assert_eq 'get_method_nil' "$("$BIN" -e '(do (defmulti m4 identity) (nil? (get-method m4 :missing)))')" 'true'
assert_eq 'remove_method' "$("$BIN" -e '(do (defmulti m5 identity) (defmethod m5 :a [_] :A) (remove-method m5 :a) (nil? (get-method m5 :a)))')" 'true'
assert_eq 'remove_returns' "$("$BIN" -e '(do (defmulti m6 identity) (defmethod m6 :a [_] :A) (remove-method m6 :a) (defmethod m6 :a [_] :B) (m6 :a))')" ':B'
assert_eq 'prefers_count' "$("$BIN" -e '(do (defmulti m7 identity) (prefer-method m7 :a :b) (count (prefers m7)))')" '1'
echo "OK — phase14_multifn_introspect smoke (7 cases) green"
