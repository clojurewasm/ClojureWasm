#!/usr/bin/env bash
# test/e2e/phase7_method_dispatch.sh
#
# Phase 7 §9.9 row 7.6 cycle 1 — (.method instance args) general-arity
# dispatch via the row 7.3 dispatch ABI.
#
# Validates:
#   - (.method rec arg) routes through InteropCallNode .instance_member
#   - Works on .typed_instance (defrecord) receivers
#   - Works on .reified_instance (reify) receivers
#   - (.field rec) field-reads via the field-first resolver (ADR-0050 am1
#     unified the former arity-1-field / arity-≥2-method split)
#   - Method not found raises protocol_no_satisfies
#
# Both backends land this dispatch (VM op_method_call; ADR-0036 parity).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: (.method rec arg) on defrecord routes through dispatch ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IShift (shift-by [this n]))
(defrecord Box [x] IShift (shift-by [this n] (+ (get this :x) n)))
(.shift-by (->Box 10) 5)
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_dot_method_dispatch' "$(last_line "$got")" '15'

# --- Case 2: (.method reified arg) on reify routes through dispatch ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IShift (shift-by [this n]))
(.shift-by (reify IShift (shift-by [this n] (* n 3))) 7)
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'reify_dot_method_dispatch' "$(last_line "$got")" '21'

# --- Case 3: arity-2 (.field rec) still field-reads (row 7.6 §4 A) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(.x (->Point 99 100))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'defrecord_arity2_stays_field_read' "$(last_line "$got")" '99'

# --- Case 4: (.method rec arg) raises when method unknown ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(defrecord Box [x])
(.unknown-method (->Box 1) 2)
EOF
)
if [[ "$diag" != *"unknown-method"* ]] && [[ "$diag" != *"satisfies"* ]] && [[ "$diag" != *"protocol_no_satisfies"* ]]; then
    fail "case4: expected method-not-found diagnostic, got '$diag'"
fi
echo "PASS method_unknown_raises"

# --- Case 5: closure capture across .method dispatch on reify ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol IAdd (add-it [this n]))
(let* [outer 1000]
  (.add-it (reify IAdd (add-it [this n] (+ outer n))) 23))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'reify_dot_method_closure_capture' "$(last_line "$got")" '1023'

echo "OK — phase7_method_dispatch smoke (5 cases) green"
