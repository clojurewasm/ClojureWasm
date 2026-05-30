#!/usr/bin/env bash
# test/e2e/phase14_atom.sh — atoms (basic single-threaded box, Phase-15
# pull-forward): atom / deref / @ / swap! / reset! / compare-and-set!.
# Watches / validators / real CAS-atomicity stay Phase 15 (D-157).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# deref via (deref a) and via @ reader
assert_eq 'deref_fn'  "$("$BIN" -e '(deref (atom 10))')"                  '10'
assert_eq 'deref_at'  "$("$BIN" -e '@(atom 7)')"                          '7'
assert_eq 'deref_let' "$("$BIN" -e '(let [a (atom 1)] @a)')"              '1'
# reset!
assert_eq 'reset'     "$("$BIN" -e '(let [a (atom 0)] (reset! a 5) @a)')" '5'
assert_eq 'reset_ret' "$("$BIN" -e '(reset! (atom 0) 9)')"               '9'
# swap! — 1-fn, extra args, fn returning a collection
assert_eq 'swap_inc'  "$("$BIN" -e '(let [a (atom 0)] (swap! a inc) @a)')" '1'
assert_eq 'swap_ret'  "$("$BIN" -e '(swap! (atom 0) + 1 2 3)')"          '6'
assert_eq 'swap_args' "$("$BIN" -e '(let [a (atom 1)] (swap! a + 10 100) @a)')" '111'
assert_eq 'swap_map'  "$("$BIN" -e '(let [a (atom {:n 0})] (swap! a update :n inc) (:n @a))')" '1'
assert_eq 'swap_many' "$("$BIN" -e '(let [a (atom 0)] (dotimes [_ 5] (swap! a inc)) @a)')" '5'
# compare-and-set! — identity (JVM-faithful)
assert_eq 'cas_ok'    "$("$BIN" -e '(let [a (atom 5)] [(compare-and-set! a 5 6) @a])')" '[true 6]'
assert_eq 'cas_no'    "$("$BIN" -e '(let [a (atom 5)] [(compare-and-set! a 99 6) @a])')" '[false 5]'
# identity preserved across swaps (same atom object)
assert_eq 'identity'  "$("$BIN" -e '(let [a (atom 0)] (swap! a inc) (identical? a a))')" 'true'
echo "OK — phase14_atom smoke (13 cases) green"
