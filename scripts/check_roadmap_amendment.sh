#!/usr/bin/env bash
# check_roadmap_amendment.sh — PreToolUse: Edit|Write hook.
# Reminds about ROADMAP §17 amendment policy when ROADMAP.md is edited.

set -euo pipefail

TARGET="${CLAUDE_HOOK_TARGET:-}"

case "$TARGET" in
    *"/.dev/ROADMAP.md")
        echo "=== ROADMAP amendment policy reminder ==="
        echo ""
        echo "Per ROADMAP §17, amendments require:"
        echo "  1. Edit in place as if it had always been so"
        echo "  2. Open an ADR (.dev/decisions/NNNN_*.md)"
        echo "  3. Sync .dev/handover.md (same commit)"
        echo "  4. Reference the ADR in the commit message"
        echo ""
        echo "Quiet edits are forbidden."
        ;;
esac

exit 0
