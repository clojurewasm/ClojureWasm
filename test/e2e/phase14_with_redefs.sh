#!/usr/bin/env bash
# test/e2e/phase14_with_redefs.sh — with-redefs (D-225, on alter-var-root).
# Temporarily swaps Var roots for body's extent, restoring in a finally (even on
# throw). cw single-threaded: root swap, not a binding frame. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'rebind'  "$("$BIN" -e '(def c (fn [] 1)) (with-redefs [c (fn [] 9)] (c))' 2>&1 | tail -1)" '9'
assert_eq 'restore' "$("$BIN" -e '(def c (fn [] 1)) (with-redefs [c (fn [] 9)] (c)) (c)' 2>&1 | tail -1)" '1'
assert_eq 'multi'   "$("$BIN" -e '(def a (fn [] 1)) (def b (fn [] 2)) (with-redefs [a (fn [] 10) b (fn [] 20)] [(a) (b)])' 2>&1 | tail -1)" '[10 20]'
assert_eq 'throw_restore' "$("$BIN" -e '(def c (fn [] :orig)) (try (with-redefs [c (fn [] :new)] (throw (ex-info "x" {}))) (catch Throwable e nil)) (c)' 2>&1 | tail -1)" ':orig'
assert_eq 'val_var'  "$("$BIN" -e '(def v 5) (with-redefs [v 99] v)' 2>&1 | tail -1)" '99'
assert_eq 'val_restore' "$("$BIN" -e '(def v 5) (with-redefs [v 99] v) v' 2>&1 | tail -1)" '5'

echo "OK — phase14_with_redefs (6 cases) green"
