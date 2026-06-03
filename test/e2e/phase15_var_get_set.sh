#!/usr/bin/env bash
# test/e2e/phase15_var_get_set.sh — `var-get` / `var-set` (D-232).
# `(var-get v)` returns the Var's current value (thread binding if bound, else
# root). `(var-set v val)` sets the Var's CURRENT THREAD BINDING (per clj it
# requires the var to be thread-bound — root is def/alter-var-root's job — and
# throws otherwise). clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

# var-get returns the var's value
assert_eq 'var-get-root'  "$("$BIN" -e '(def y 5) (var-get (var y))' 2>&1 | tail -1)" '5'
assert_eq 'var-get-hash'  "$("$BIN" -e '(def y 7) (var-get #'"'"'y)' 2>&1 | tail -1)" '7'
# var-set mutates the current thread binding; returns the value
assert_eq 'var-set-bind'  "$("$BIN" -e '(def ^:dynamic *x* 0) (binding [*x* 1] (var-set (var *x*) 9) *x*)' 2>&1 | tail -1)" '9'
assert_eq 'var-set-ret'   "$("$BIN" -e '(def ^:dynamic *x* 0) (binding [*x* 1] (var-set (var *x*) 9))' 2>&1 | tail -1)" '9'
# var-set restores after the binding pops (frame-only mutation)
assert_eq 'var-set-frame' "$("$BIN" -e '(def ^:dynamic *x* 0) (do (binding [*x* 1] (var-set (var *x*) 9)) *x*)' 2>&1 | tail -1)" '0'
# var-set on an unbound var raises a clean error (not a silent root write)
assert_has 'var-set-unbd' "$("$BIN" -e '(def ^:dynamic *x* 0) (var-set (var *x*) 9)' 2>&1)" 'not thread-bound'

echo "OK — phase15_var_get_set (6 cases) green"
