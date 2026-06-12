#!/usr/bin/env bash
# test/e2e/phase15_with_local_vars.sh — `with-local-vars` (ADR-0097 / D-237).
# Binds each name to a fresh anonymous dynamic Var thread-bound to its init for
# the body's extent; var-get/var-set/@ operate on them inside; the frame pops in
# a finally. Anon Vars are Env-owned + freed at session end (escape-safe, no
# per-invocation leak surfaced by the DebugAllocator). Also the AD-015 pin: an
# escaped local var deref returns nil (cljw) vs JVM's unreproducible
# #object[Var$Unbound] opaque. clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# basic: var-set + var-get over two locals (clj => 12)
assert_eq 'basic'    "$("$BIN" -e '(with-local-vars [x 1 y 2] (var-set x 10) (+ (var-get x) (var-get y)))' 2>&1 | tail -1)" '12'
# @ deref reads the current binding; var-set updates it (clj => 20)
assert_eq 'deref'    "$("$BIN" -e '(with-local-vars [a 5] (var-set a (* @a 4)) @a)' 2>&1 | tail -1)" '20'
# var-set returns the assigned value (clj => 99)
assert_eq 'set-ret'  "$("$BIN" -e '(with-local-vars [x 1] (var-set x 99))' 2>&1 | tail -1)" '99'
# nested with-local-vars: inner sees both extents (clj => 3)
assert_eq 'nested'   "$("$BIN" -e '(with-local-vars [x 1] (with-local-vars [y 2] (+ (var-get x) (var-get y))))' 2>&1 | tail -1)" '3'
# AD-015 pin: an escaped local var deref'd AFTER its extent returns nil in cljw
# (memory-safe; JVM returns an unreproducible #object[Var$Unbound] opaque).
assert_eq 'escape-nil' "$("$BIN" -e '(prn (var-get (with-local-vars [x 5] x)))' 2>&1 | tail -1)" 'nil'
# many invocations do not leak / crash (Env owns the anon Vars, freed at exit)
assert_eq 'loop-clean' "$("$BIN" -e '(dotimes [_ 50] (with-local-vars [x 1] (var-set x 2))) :done' 2>&1 | tail -1)" ':done'

echo "OK — phase15_with_local_vars (6 cases) green"
