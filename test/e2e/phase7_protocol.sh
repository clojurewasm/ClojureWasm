#!/usr/bin/env bash
# test/e2e/phase7_protocol.sh
#
# Phase 7 §9.9 row 7.3 cycle 8 — defprotocol/satisfies smoke.
# Validates the cycle 6 + cycle 6.6 + cycle 7 surface end-to-end:
#   - (defprotocol P (m [x])) binds P as a `.protocol`-tagged Var.
#   - rt/__satisfies? returns false on a non-typed_instance receiver.
#   - defprotocol with 0 methods raises defprotocol_form_incomplete.
#
# Cycle 7.1 limitation: defprotocol does NOT emit per-method-Var
# defs — the macro lowering hits an analyzer pre-register gap on
# `(do (def P ...) (def m ... P ...))` (forward ref). Method-Var
# binding lands when analyzeDef pre-registers (debt D-082b).
#
# OUT OF SCOPE for cycle 8: extend-type / extend-protocol against
# native types — needs per-Tag descriptor registry (cycle 8.5
# candidate). User types via deftype land at row 7.4. Stderr is
# NOT redirected onto stdout — the DebugAllocator emits the
# documented intentional-leak diagnostic for infra-allocated
# protocol descriptors at process exit (cycles 1+4+6 policy);
# e2e captures stdout only.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: defprotocol lowers + satisfies? false on integer ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPing (ping [this]))
(rt/__satisfies? IPing 42)
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defprotocol_satisfies_false_on_integer' "$(last_line "$got")" 'false'

# --- Case 2: defprotocol with multi-method form ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPair (first-of [p]) (second-of [p]))
(rt/__satisfies? IPair "hello")
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defprotocol_multi_method_satisfies_false' "$(last_line "$got")" 'false'

# --- Case 3: defprotocol with 0 methods is a syntax error ---
diag=$("$BIN" -e '(defprotocol Empty)' 2>&1 || true)
if [[ "$diag" != *"defprotocol requires"* ]]; then
    fail "case3: expected defprotocol_form_incomplete diagnostic, got '$diag'"
fi
echo "PASS defprotocol_zero_methods_diagnostic"

# --- Case 4 (ADR-0038): defprotocol binds per-method-Var ---
# Post-cycle 8.1 defprotocol emits `(do (def P ...) (def m P ...))`;
# the second def relies on analyzer pre-register (ADR-0038). Verify
# that the method-fn Var lands as a .protocol_fn-tagged Value.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPing (ping [this]))
ping
EOF
) || fail "case4: non-zero exit ($got)"
last=$(last_line "$got")
if [[ "$last" != *"protocol_fn"* ]]; then
    fail "case4: expected protocol_fn-tagged value, got '$last'"
fi
echo "PASS defprotocol_per_method_var_binding -> protocol_fn"

# --- Case 5 (ADR-0038): recursive defn works ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn fact [n] (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 5)
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'recursive_defn_factorial' "$(last_line "$got")" '120'

# --- Case 6 (cycle 8.5): extend-type Long round-trip via __native-type ---
# Native types reach extend-type via the per-Tag descriptor registry.
# rt/__native-type returns the .type_descriptor Value for a given Tag
# keyword. cycle 8.5 + cycle 8.2 together let (m receiver) dispatch
# on integer Tag receivers through the registered method.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(inc-one 41)
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'extend_type_long_native_dispatch' "$(last_line "$got")" '42'

# --- Case 7 (cycle 8.5): satisfies? recognises native extension ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(rt/__satisfies? IInc 7)
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'extend_type_satisfies_native_receiver' "$(last_line "$got")" 'true'

echo "OK — phase7_protocol smoke (7 cases) green"
