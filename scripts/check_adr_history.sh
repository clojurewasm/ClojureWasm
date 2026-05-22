#!/usr/bin/env bash
# check_adr_history.sh — pre-commit / merge gate.
# Verifies each ADR file has a Revision history section.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ADR_DIR="$REPO_ROOT/.dev/decisions"

if [[ ! -d "$ADR_DIR" ]]; then
    exit 0
fi

FAIL=0
for f in "$ADR_DIR"/[0-9]*.md; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" =~ ^0000 ]] && continue
    if ! grep -q "^## Revision history" "$f"; then
        echo "[check_adr_history] ADR missing Revision history section: $f"
        FAIL=1
    fi
done

if (( FAIL )); then
    echo ""
    echo "Add a 'Revision history' section. Format:"
    echo "  ## Revision history"
    echo ""
    echo "  - YYYY-MM-DD: Status: Proposed -> Accepted (commit abc1234)"
    exit 1
fi

exit 0
