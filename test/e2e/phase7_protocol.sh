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
zig build >/dev/null

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

echo "OK — phase7_protocol smoke (3 cases) green"
