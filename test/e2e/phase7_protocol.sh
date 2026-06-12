#!/usr/bin/env bash
# test/e2e/phase7_protocol.sh
#
# Phase 7 §9.9 row 7.3 cycle 8 — defprotocol/satisfies smoke.
# Validates the cycle 6 + cycle 6.6 + cycle 7 surface end-to-end:
#   - (defprotocol P (m [x])) binds P as a `.protocol`-tagged Var.
#   - rt/__satisfies? returns false on a non-typed_instance receiver.
#   - defprotocol with 0 methods is a MARKER protocol (D-190/ADR-0068).
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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

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
(prn (rt/__satisfies? IPing 42))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defprotocol_satisfies_false_on_integer' "$(last_line "$got")" 'false'

# --- Case 2: defprotocol with multi-method form ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPair (first-of [p]) (second-of [p]))
(prn (rt/__satisfies? IPair "hello"))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defprotocol_multi_method_satisfies_false' "$(last_line "$got")" 'false'

# --- Case 3 (D-190/ADR-0068): defprotocol with 0 methods is a MARKER protocol ---
# A name-only `(defprotocol Empty)` is now accepted (JVM-faithful) and a
# deftype can extend the marker without error.
diag=$("$BIN" -e '(defprotocol Empty)' 2>&1 || true)
if [[ "$diag" != *"user/Empty"* ]]; then
    fail "case3: marker defprotocol should define Empty, got '$diag'"
fi
ext=$("$BIN" - <<'EOF' 2>&1
(defprotocol Mark)
(deftype T [a] Mark)
(prn (vector? [(->T 1)]))
EOF
)
if [[ "$ext" != *"true"* ]]; then
    fail "case3b: deftype extending a marker protocol failed, got '$ext'"
fi
echo "PASS defprotocol_zero_method_marker"

# --- Case 4 (ADR-0038): defprotocol binds per-method-Var ---
# Post-cycle 8.1 defprotocol emits `(do (def P ...) (def m P ...))`;
# the second def relies on analyzer pre-register (ADR-0038). Verify
# that the method-fn Var lands as a .protocol_fn-tagged Value. Since
# ADR-0121/AD-025 a protocol-fn prints `#<IPing/ping>` (its qualified
# name) rather than the leaked internal `#<protocol_fn>` tag — the name
# form proves the tag just as precisely.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPing (ping [this]))
(prn ping)
EOF
) || fail "case4: non-zero exit ($got)"
last=$(last_line "$got")
if [[ "$last" != *"#<IPing/ping>"* ]]; then
    fail "case4: expected protocol_fn name form #<IPing/ping>, got '$last'"
fi
echo "PASS defprotocol_per_method_var_binding -> #<IPing/ping>"

# --- Case 5 (ADR-0038): recursive defn works ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn fact [n] (if (= n 0) 1 (* n (fact (- n 1)))))
(prn (fact 5))
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
(prn (inc-one 41))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'extend_type_long_native_dispatch' "$(last_line "$got")" '42'

# --- Case 7 (cycle 8.5): satisfies? recognises native extension ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(prn (rt/__satisfies? IInc 7))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'extend_type_satisfies_native_receiver' "$(last_line "$got")" 'true'

# --- Case 8: public satisfies? wrapper false on unextended receiver ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IPing (ping [this]))
(prn (satisfies? IPing 42))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'satisfies_wrapper_false_on_integer' "$(last_line "$got")" 'false'

# --- Case 9: public satisfies? wrapper true after native extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(prn (satisfies? IInc 7))
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'satisfies_wrapper_true_native_receiver' "$(last_line "$got")" 'true'

# --- Case 10: extends? true when the type carries the protocol ---
# extends? takes a type (a .type_descriptor Value), unlike satisfies?
# which takes an instance. Long extends IInc here, so (extends? IInc Long).
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(prn (extends? IInc Long))
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'extends_wrapper_true_for_extended_type' "$(last_line "$got")" 'true'

# --- Case 11: extends? false for a protocol the type does not carry ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IInc (inc-one [x]))
(defprotocol IPing (ping [this]))
(def Long (rt/__native-type :integer))
(extend-type Long IInc (inc-one [x] (+ x 1)))
(prn (extends? IPing Long))
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'extends_wrapper_false_for_unextended_protocol' "$(last_line "$got")" 'false'

echo "OK — phase7_protocol smoke (11 cases) green"
