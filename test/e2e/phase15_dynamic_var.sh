#!/usr/bin/env bash
# test/e2e/phase15_dynamic_var.sh — `^:dynamic` on a .clj def now sets the Var's
# dynamic flag so `binding` can rebind it (analyzeDef reads :dynamic/:private off
# the def-target metadata; previously the meta was lifted into Var.meta but the
# flags stayed false). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'bind'    "$("$BIN" -e '(do (def ^:dynamic *x* 1) (binding [*x* 2] *x*))' 2>&1 | tail -1)" '2'
assert_eq 'restore' "$("$BIN" -e '(do (def ^:dynamic *x* 1) [(binding [*x* 2] *x*) *x*])' 2>&1 | tail -1)" '[2 1]'
assert_eq 'nested'  "$("$BIN" -e '(do (def ^:dynamic *y* 10) (binding [*y* 20] (binding [*y* 30] *y*)))' 2>&1 | tail -1)" '30'
assert_eq 'fn-sees' "$("$BIN" -e '(do (def ^:dynamic *a* :root) (defn pa [] *a*) [(binding [*a* :inner] (pa)) (pa)])' 2>&1 | tail -1)" '[:inner :root]'
# non-dynamic var still rejects binding (the guard still fires)
assert_eq 'guard'   "$("$BIN" -e '(do (def plain 1) (binding [plain 2] plain))' 2>&1 | grep -c 'non-dynamic')" '1'

# --- standard core version / flag vars (cljw targets the 1.12 surface) ---
assert_eq 'cv_minor'  "$("$BIN" -e '(:minor *clojure-version*)' 2>&1 | tail -1)"      '12'
assert_eq 'cv_string' "$("$BIN" -e '(clojure-version)' 2>&1 | tail -1)"               '"1.12.0"'
assert_eq 'unchecked' "$("$BIN" -e '*unchecked-math*' 2>&1 | tail -1)"                'false'
# *unchecked-math* is ^:dynamic — libs set! / binding it (a no-op flag in cljw)
assert_eq 'um_bind'   "$("$BIN" -e '(binding [*unchecked-math* true] *unchecked-math*)' 2>&1 | tail -1)" 'true'

echo "OK — phase15_dynamic_var (9 cases) green"
