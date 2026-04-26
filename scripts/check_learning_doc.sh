#!/usr/bin/env bash
# scripts/check_learning_doc.sh
#
# Pre-commit gate that requires a `docs/ja/NNNN-<slug>.md` for every commit
# whose staged changes touch the source tree. Wired as a Claude Code
# PreToolUse hook on `Bash`; safely no-ops for any non-`git commit` Bash call.
#
# See .claude/skills/code-learning-doc/SKILL.md for the full workflow.

set -euo pipefail

# --- 1. Read the Claude Code hook payload from stdin -------------------------
INPUT="$(cat)"

# Extract the actual shell command being invoked. The PreToolUse hook payload
# carries `tool_input.command` for `Bash`. Use python3 (always present on
# macOS/Linux) so we don't depend on jq/yq being on PATH.
COMMAND="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command", "") or ""
print(cmd)
' 2>/dev/null || echo "")"

# --- 2. Only enforce on `git commit` -----------------------------------------
# Match `git commit ...` but not `git commit-tree`, etc. Allow leading env
# vars (e.g. `FOO=bar git commit ...`).
if ! printf '%s' "$COMMAND" | grep -qE '(^|[ ;&|])git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# --- 3. Identify staged files ------------------------------------------------
# Run from the project root (Claude Code provides $CLAUDE_PROJECT_DIR).
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"

if [[ -z "$STAGED" ]]; then
  exit 0
fi

# --- 4. Decide whether the commit needs a learning doc ----------------------
needs_doc=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    src/*.zig|build.zig|build.zig.zon|.dev/decisions/*.md)
      needs_doc=1
      break
      ;;
  esac
done <<< "$STAGED"

if [[ $needs_doc -eq 0 ]]; then
  exit 0
fi

# --- 5. Verify a new docs/ja/NNNN-*.md is staged in the same commit --------
new_doc="$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
            | grep -E '^docs/ja/[0-9]{4}-.+\.md$' || true)"

if [[ -n "$new_doc" ]]; then
  exit 0
fi

# --- 6. Block with a helpful message ----------------------------------------
last="$(ls docs/ja/ 2>/dev/null | grep -oE '^[0-9]{4}' | sort -n | tail -1 || echo "0000")"
next="$(printf '%04d' $((10#$last + 1)))"

cat >&2 <<EOF
✗ commit blocked by scripts/check_learning_doc.sh

Source-bearing files are staged but no new docs/ja/NNNN-<slug>.md was added.

Next index to use: ${next}-<slug>.md
Skill / template:  .claude/skills/code-learning-doc/SKILL.md

Either add the learning doc and stage it, or split the commit so the
source changes ride with their doc.
EOF
exit 1
