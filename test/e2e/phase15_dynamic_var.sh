#!/usr/bin/env bash
# test/e2e/phase15_dynamic_var.sh — `^:dynamic` on a .clj def now sets the Var's
# dynamic flag so `binding` can rebind it (analyzeDef reads :dynamic/:private off
# the def-target metadata; previously the meta was lifted into Var.meta but the
# flags stayed false). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'bind'    "$("$BIN" -e '(do (def ^:dynamic *x* 1) (binding [*x* 2] *x*))' 2>&1 | tail -1)" '2'
assert_eq 'restore' "$("$BIN" -e '(do (def ^:dynamic *x* 1) [(binding [*x* 2] *x*) *x*])' 2>&1 | tail -1)" '[2 1]'
assert_eq 'nested'  "$("$BIN" -e '(do (def ^:dynamic *y* 10) (binding [*y* 20] (binding [*y* 30] *y*)))' 2>&1 | tail -1)" '30'
assert_eq 'fn-sees' "$("$BIN" -e '(do (def ^:dynamic *a* :root) (defn pa [] *a*) [(binding [*a* :inner] (pa)) (pa)])' 2>&1 | tail -1)" '[:inner :root]'
# non-dynamic var still rejects binding (the guard still fires)
assert_eq 'guard'   "$("$BIN" -e '(do (def plain 1) (binding [plain 2] plain))' 2>&1 | grep -c 'non-dynamic')" '1'

echo "OK — phase15_dynamic_var (5 cases) green"
