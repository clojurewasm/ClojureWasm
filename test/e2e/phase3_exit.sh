#!/usr/bin/env bash
# test/e2e/phase3_exit.sh
#
# Pin Phase-3's exit criteria as a focused end-to-end gate. ROADMAP
# §9.5 task 3.14 promises:
#
#   (defn f [x] (+ x 1)) (f 2)                                       → 3
#   (try (throw (ex-info "boom" 0))
#        (catch ExceptionInfo e (ex-message e)))                     → "boom"
#
# The `data` argument to `ex-info` is an integer placeholder rather
# than the canonical empty map literal `{}` — see ADR 0002
# (`.dev/decisions/0002-phase3-exit-no-map-literal.md`): map literals
# are scoped to Phase 5 alongside HAMT / persistent collections, so
# the smoke uses any non-nil Value to verify the try/throw/catch +
# ex-info round-trip without dragging Phase-5 work into Phase 3.
#
# Both forms also appear in `phase3_cli.sh` alongside many plumbing
# cases. This script is **only** the two exit-form assertions, kept
# narrow so a Phase-3 regression is unambiguous about which gate
# slipped.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"

echo "==> Building (Debug)"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
    echo "✗ binary missing: $BIN" >&2
    exit 1
fi

run_case() {
    local label="$1"
    local expr="$2"
    local want="$3"
    local got
    got=$("$BIN" -e "$expr" 2>&1) || {
        echo "✗ $label: cljw exited non-zero" >&2
        echo "  output: $got" >&2
        exit 1
    }
    if [[ "$got" != "$want" ]]; then
        echo "✗ $label" >&2
        echo "  expr: $expr" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        exit 1
    fi
    echo "    ✓ $label"
}

echo "==> Phase-3 exit criteria"

# --- Exit 1: `defn` lowering + top-level fn call ---
# Two top-level forms; `def` evaluates to the var_ref, then the call
# yields the integer.
got=$("$BIN" - <<'EOF' 2>&1
(defn f [x] (+ x 1))
(f 2)
EOF
) || { echo "✗ defn exit: cljw exited non-zero" >&2; echo "  output: $got" >&2; exit 1; }
if [[ "$got" != $'#<var_ref>\n3' ]]; then
    echo "✗ defn exit form" >&2
    echo "  want: '#<var_ref>\\n3'" >&2
    echo "  got:  '$got'" >&2
    exit 1
fi
echo "    ✓ (defn f [x] (+ x 1)) (f 2) → 3"

# --- Exit 2: try / throw / ex-info / catch ExceptionInfo round-trip ---
run_case "try/throw/catch ex-info round-trip" \
    '(try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e)))' \
    '"boom"'

echo
echo "Phase-3 exit-criterion e2e: all green."
