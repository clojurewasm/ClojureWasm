#!/usr/bin/env bash
# test/e2e/phase7_reify.sh
#
# Phase 7 §9.9 row 7.5 cycle 1 — reify macro skeleton smoke.
# Validates the cycle-1 surface:
#   - `(reify P (m [this] body))` parses cleanly (no
#     STAGED_UNSUPPORTED_FORMS raise; row 7.5 cycle 1 retired the
#     wedge).
#   - The macro lowers to `(rt/__reify! ...)` which is the
#     stubbed primitive — raising `feature_not_supported` with the
#     "impl pending row 7.5 cycle 3" hint.
#   - Syntactic-error diagnostics (missing impl list / bad method form).
#
# Cycle 3 lands the happy path; cycle 4 wires the dispatch arm.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1 (cycle 3): basic reify returns a reified_instance Value ---
# Just verify (reify P (m [this] 42)) parses + macro-expands + __reify!
# runs without runtime error. Detailed dispatch in cases 5-7.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [this]))
(reify P (m [this] 42))
EOF
) || fail "case1: non-zero exit ($got)"
echo "PASS reify_basic_construction"

# --- Case 2: reify with empty form raises reify_form_incomplete ---
diag=$("$BIN" -e '(reify)' 2>&1 || true)
if [[ "$diag" != *"reify requires"* ]]; then
    fail "case2: expected reify_form_incomplete diagnostic, got '$diag'"
fi
echo "PASS reify_form_incomplete_diagnostic"

# --- Case 3: reify with no method-impl section raises section_invalid ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(defprotocol P (m [this]))
(reify P)
EOF
)
if [[ "$diag" != *"reify section"* ]]; then
    fail "case3: expected reify_section_invalid diagnostic, got '$diag'"
fi
echo "PASS reify_section_invalid_diagnostic"

# --- Case 4: reify with malformed method-impl raises method_invalid ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(defprotocol P (m [this]))
(reify P (m))
EOF
)
if [[ "$diag" != *"reify method"* ]]; then
    fail "case4: expected reify_method_invalid diagnostic, got '$diag'"
fi
echo "PASS reify_method_invalid_diagnostic"

# --- Case 5 (cycle 3): reify happy path — method body returns 42 ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [x]))
(prn (m (reify P (m [this] 42))))
EOF
) || fail "case5: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "42" ]]; then
    fail "case5: got '$last', want '42'"
fi
echo "PASS reify_happy_path_dispatch -> 42"

# --- Case 6 (cycle 3): closure capture across reify body ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [x]))
(prn (let* [outer 100]
  (m (reify P (m [this] (+ outer 7))))))
EOF
) || fail "case6: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "107" ]]; then
    fail "case6: got '$last', want '107'"
fi
echo "PASS reify_closure_capture -> 107"

# --- Case 7 (cycle 3): satisfies? returns true on reified instance ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [x]))
(prn (rt/__satisfies? P (reify P (m [this] 42))))
EOF
) || fail "case7: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "true" ]]; then
    fail "case7: got '$last', want 'true'"
fi
echo "PASS reify_satisfies_true"

echo "OK — phase7_reify smoke (7 cases) green"
