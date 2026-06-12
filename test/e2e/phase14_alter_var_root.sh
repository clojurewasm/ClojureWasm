#!/usr/bin/env bash
# test/e2e/phase14_alter_var_root.sh — alter-var-root (D-225 foundation).
# Atomically applies a fn to a Var's mutable root (the cell `def` writes), the
# foundation `with-redefs` will build on. Single-threaded: no CAS loop. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'ret'    "$("$BIN" -e '(do (def a 10) (alter-var-root (var a) inc))')" '11'
assert_eq 'effect' "$("$BIN" -e '(do (def a 10) (alter-var-root (var a) + 5) a)')" '15'
assert_eq 'const'  "$("$BIN" -e '(do (def a 1) (alter-var-root (var a) (constantly 99)) a)')" '99'
assert_eq 'conj'   "$("$BIN" -e '(do (def a [1 2]) (alter-var-root (var a) conj 3))')" '[1 2 3]'
assert_eq 'twice'  "$("$BIN" -e '(do (def a 0) (alter-var-root (var a) inc) (alter-var-root (var a) inc) a)')" '2'
# non-var arg errors
if "$BIN" -e '(alter-var-root 5 inc)' >/dev/null 2>&1; then fail 'nonvar: should error'; fi
echo 'PASS nonvar -> errors'

# add-watch on a var (IRef generalization): fires (fn key var old new) on each
# alter-var-root only — a dynamic-binding set! does NOT notify (JVM Var).
assert_eq 'add_watch'    "$("$BIN" -e '(do (def x 0) (def log (atom [])) (add-watch (var x) :k (fn [k r o n] (swap! log conj [o n]))) (alter-var-root (var x) inc) (alter-var-root (var x) inc) @log)')" '[[0 1] [1 2]]'
assert_eq 'remove_watch' "$("$BIN" -e '(do (def x 0) (def log (atom [])) (add-watch (var x) :k (fn [k r o n] (swap! log conj n))) (alter-var-root (var x) inc) (remove-watch (var x) :k) (alter-var-root (var x) inc) @log)')" '[1]'
# add-watch alone does not fire — only an alter-var-root does.
assert_eq 'no_alter_silent' "$("$BIN" -e '(do (def x 0) (def log (atom [])) (add-watch (var x) :k (fn [k r o n] (swap! log conj n))) @log)')" '[]'

echo "OK — phase14_alter_var_root (9 cases) green"
