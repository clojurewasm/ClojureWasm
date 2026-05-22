#!/usr/bin/env bash
# check_tier_d_error_msg.sh — pre-commit gate.
# Verifies Tier D forms / fns produce structured error messages
# referencing the rationale ADR.
#
# Phase 5+ activation by design. Phase 4 entry: informational only.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
YAML="$REPO_ROOT/compat_tiers.yaml"

# Phase 4 entry: skeleton; full grep against actual implementation
# activates at Phase 5 when error messages exist in src/.
# Expected format: "Tier D: <reason>, see ADR-NNNN"
echo "[check_tier_d_error_msg] informational mode (Phase 4 entry); activates at Phase 5."
exit 0
