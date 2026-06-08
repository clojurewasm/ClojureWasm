#!/usr/bin/env bash
# test/e2e/phase15_set_bang.sh — the `set!` special form on dynamic vars.
# ADR-0096: `set!` is a runtime thread-bound gate (JVM Var.set parity) — it
# updates the innermost active thread binding for v, and raises when v is NOT
# thread-bound (dynamic-unbound OR non-dynamic alike — JVM gives one error).
# A clojure.main-style baseline binding frame thread-binds the standard config
# vars (*warn-on-reflection* etc.) at top level, so set! on them works there.
# clj-grounded (oracle-confirmed). Validation-campaign: string.clj opens with
# `(set! *warn-on-reflection* true)`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# set! within a binding mutates the current thread binding
assert_eq 'bind-set'   "$("$BIN" -e '(def ^:dynamic *x* 1) (binding [*x* 10] (set! *x* 99) *x*)' 2>&1 | tail -1)" '99'
# set! returns the assigned value
assert_eq 'set-ret'    "$("$BIN" -e '(def ^:dynamic *x* 1) (binding [*x* 0] (set! *x* 5))' 2>&1 | tail -1)" '5'
# after the binding pops, the root is restored (set! touched the frame only)
assert_eq 'frame-only' "$("$BIN" -e '(def ^:dynamic *x* 1) (do (binding [*x* 0] (set! *x* 5)) *x*)' 2>&1 | tail -1)" '1'
# top-level set! on an UNBOUND user dynamic var raises (JVM: "Can't change/
# establish root binding") — set! never mutates a root (ADR-0096).
assert_eq 'unbound-errs' "$("$BIN" -e '(def ^:dynamic *x* 1) (set! *x* 8)' 2>&1 | sed -n '2s/^  //p')" "Can't set! var that is not thread-bound: user/*x*"
# *warn-on-reflection* (compiler-flag dynamic var) is set!-able at top level —
# it is thread-bound by the baseline frame (ADR-0096), so set! succeeds.
assert_eq 'warn-refl'  "$("$BIN" -e '(set! *warn-on-reflection* true)' 2>&1 | tail -1)" 'true'
# same compilation unit: def a dynamic var then binding+set! it. The flag is
# honoured at eval time, not analyze time (ADR-0096 — was a false error).
assert_eq 'same-unit'  "$("$BIN" -e '(do (def ^:dynamic zz 0) (binding [zz 1] (set! zz 9)))' 2>&1 | tail -1)" '9'
# error: set! on a non-dynamic var (never thread-bound → same error as unbound)
assert_eq 'not-dyn'    "$("$BIN" -e '(def y 1) (set! y 2)' 2>&1 | sed -n '2s/^  //p')" "Can't set! var that is not thread-bound: user/y"
# error: wrong arity
assert_eq 'arity'      "$("$BIN" -e '(set! *warn-on-reflection*)' 2>&1 | sed -n '2s/^  //p')" 'set! expects 2 args, got 1'

echo "OK — phase15_set_bang (8 cases) green"
