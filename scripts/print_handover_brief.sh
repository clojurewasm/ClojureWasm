#!/usr/bin/env bash
# print_handover_brief.sh — SessionStart / PostCompact hook.
# Prints handover.md current state + active task + git log -3 + language policy.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HANDOVER="$REPO_ROOT/.dev/handover.md"

if [[ ! -f "$HANDOVER" ]]; then
    echo "=== handover.md not found ==="
    exit 0
fi

echo "=== handover brief (auto from hook) ==="
echo ""

awk '
    /^## Current state/ { in_section=1; print; next }
    /^## Active task/   { in_section=1; print; next }
    /^## /              { in_section=0 }
    in_section          { print }
' "$HANDOVER"

echo ""
echo "=== git log -3 (current branch) ==="
git -C "$REPO_ROOT" log --oneline -3 2>/dev/null || echo "(git not available)"

echo ""
echo "=== language policy reminder ==="
echo "Chat replies: Japanese (per .claude/output_styles/japanese.md)."
echo "Tracked files (.dev/, .claude/, scripts/, ROADMAP, ADR, compat_tiers.yaml): English."
echo "docs/ja/ and private/: Japanese."
