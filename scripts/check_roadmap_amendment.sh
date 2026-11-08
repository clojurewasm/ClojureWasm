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
        echo "  2. Record the decision in memory (type decision, tagged adr-NNNN)"
        echo "  3. Update the active kanban card (memory 20260910235746-74389f7f retired handover.md)"
        echo "  4. Reference the ADR in the commit message"
        echo ""
        echo "Quiet edits are forbidden."
        ;;
esac

exit 0
