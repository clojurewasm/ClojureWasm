#!/usr/bin/env bash
# test/e2e/phase14_binding.sh
#
# Phase 14 §9.16 row 14.13 (3) — the `binding` special form (ADR-0055).
# cw v1's dynamic-binding runtime (env.zig BindingFrame + Var.deref) was
# wired but unreachable; `binding` is the analyzer + dual-backend arm
# that drives it. Happy-path rebind/restore/nest is covered by the
# differential test (src/lang/diff_test.zig — both backends agree); this
# Layer-2 suite covers the CLI error surface, which needs no production
# dynamic var. The happy-path CLI story lands with `cljw.error/with-context`
# (the same row's next deliverable) once *error-context* — cw v1's first
# Zig-registered dynamic var — exists.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_contains() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name -> contains '$want'"
}

# --- Case 1: binding a non-dynamic Var raises (JVM-faithful message) ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(def x 1)
(binding [x 2] x)
EOF
)
assert_contains 'binding_non_dynamic_raises' "$got" 'Can'\''t dynamically bind non-dynamic var: user/x'

# --- Case 2: the error is categorised value_error at eval phase ---
assert_contains 'binding_non_dynamic_kind' "$got" 'Value error'

# --- Case 3: bindings must be a vector ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(binding x x)
EOF
)
assert_contains 'binding_not_vector' "$got" 'binding bindings must be a vector'

# --- Case 4: bindings must have an even number of forms ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(def y 1)
(binding [y] y)
EOF
)
assert_contains 'binding_arity_odd' "$got" 'binding bindings must have an even number of forms'

# --- Case 5: binding name must be a symbol ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(binding [1 2] 1)
EOF
)
assert_contains 'binding_name_not_symbol' "$got" 'binding binding name must be a symbol'

echo
echo "Phase 14 row 14.13 (3) binding special-form e2e: all green."
