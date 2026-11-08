#!/usr/bin/env bash
# test/e2e/phase14_deftype_object.sh
#
# D-275/D-280a: what a deftype/reify does with an UNWIRED host-marker method.
#
# This is the PROCESS half of the deftype/reify host-marker surface. The
# unwired-method raise is `feature_not_supported`, whose Kind is
# `.not_implemented`, and that Kind is DELIBERATELY uncatchable
# (src/runtime/error/catalog.zig) so an unsupported feature can never be
# swallowed by a `try`. A suite running inside cljw therefore cannot observe
# it: the abort takes the process down before any assertion runs. Verified
# 2026-09-09, `(try (eval (read-string "(reify Object (clone [this] this))"))
# (catch Throwable e ...))` does not catch, while every other analyzer error
# tried (unresolved symbol, odd let* bindings, misplaced recur) does.
#
# Everything else this file used to cover (30 value assertions across
# Object/toString, the clojure.lang.* protocol_remap family, IFn/IObj/Sorted/
# IHashEq, host_inert java.* families, MapEntry and multi-section extend-type)
# is now test/clj/suites/deftype_host_marker_test.clj, one process instead of
# thirty.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1: reify with an unwired Object method (clone) ---
# (equals/hashCode ARE wired by D-280d1 and are asserted in the native suite;
# clone is still unwired, so it must raise rather than register a no-op.)
diag=$("$BIN" - <<'EOF' 2>&1 || true
(reify Object (clone [this] this))
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case1: expected Object-method-not-wired diagnostic for clone, got '$diag'"
fi
echo "PASS reify_object_unwired_method_explicit_error"

# --- Case 2: deftype with an unwired Object method (clone) ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(deftype Bar [a] Object (clone [this] this))
(Bar. 1)
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case2: expected Object-method-not-wired diagnostic for clone, got '$diag'"
fi
echo "PASS deftype_object_unwired_method_explicit_error"

# --- Case 3: a stray method on a zero-method marker ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(deftype T [] clojure.lang.MapEquivalence (bogus [this] 1))
(T.)
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case3: expected marker-method-not-wired diagnostic, got '$diag'"
fi
echo "PASS marker_stray_method_explicit_error"

# --- Case 4: the raise is an ABORT, not a catchable exception ---
# This is the property that keeps the three cases above in bash. If a future
# change made `.not_implemented` catchable, this case fails and the whole
# file becomes migratable to the native suite.
# Read stdout only: the diagnostic goes to stderr and echoes the source, so a
# substring probe over the merged streams would match the echoed `:caught`.
# What decides the case is whether `prn` ever ran, plus a non-zero exit.
rc=0
out=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (eval (read-string "(reify Object (clone [this] this))"))
          :swallowed
          (catch Throwable e :caught)))
EOF
) || rc=$?
if [[ -n "$out" || "$rc" -eq 0 ]]; then
    fail "case4: feature_not_supported became catchable (exit $rc, stdout '$out'); migrate this file to the native suite"
fi
echo "PASS unwired_marker_raise_is_uncatchable"

echo "OK: phase14_deftype_object (4 process cases) green"
