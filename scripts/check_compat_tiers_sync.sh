#!/usr/bin/env bash
# check_compat_tiers_sync.sh — pre-commit gate.
# Verifies compat_tiers.yaml entries match actual implementation in
# src/lang/primitive/ and src/runtime/host/.
#
# Phase 5+ activation by design. Phase 4 entry: informational only.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
YAML="$REPO_ROOT/compat_tiers.yaml"

if [[ ! -f "$YAML" ]]; then
    echo "[check_compat_tiers_sync] compat_tiers.yaml not found; skipping"
    exit 0
fi

# Phase 4 entry: skeleton only; sync check is informational (always exit 0).
# Phase 5+: this script becomes a hard gate after actual implementation
# files exist in src/.
echo "[check_compat_tiers_sync] informational mode (Phase 4 entry); sync check activates at Phase 5."
exit 0
