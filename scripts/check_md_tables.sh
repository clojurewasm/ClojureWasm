#!/usr/bin/env bash
# scripts/check_md_tables.sh
#
# Pre-commit gate: every staged *.md file must already be aligned by
# `md-table-align`. Behaviour was originally check-only and required
# a separate fix-and-re-stage round-trip whenever the agent (or a
# human) staged before aligning. That two-cycle pattern was wasteful,
# so the hook now **auto-fixes and re-stages** misaligned files
# before letting the commit through. The commit then contains the
# realigned content automatically; no second round-trip needed.
#
# Hook contract: invoked as a Claude Code PreToolUse hook on Bash
# (.claude/settings.json). Reads the JSON payload from stdin, no-ops
# unless the command being run is `git commit`.
#
# Failure modes:
#   - md-table-align not installed → block with install guide (exit 1).
#   - md-table-align cannot fix a file (genuine syntax issue) → block
#     with the filename (exit 2). No-op for that file; commit blocked.
#
# md-table-align is shipped via bbin from
# https://github.com/chaploud/babashka-utilities.

set -euo pipefail

# --- 1. Shared helpers (Wave 16) ---------------------------------------------
source "$(dirname "$0")/hook_lib.sh"

# --- 2. Only enforce on `git commit` -----------------------------------------
hook_read_command
hook_is_git_commit || exit 0
hook_cd_project_root

# --- 3. Collect staged *.md files (added or modified, not deleted) -----------
STAGED_MD="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
             | grep -E '\.md$' || true)"

[[ -z "$STAGED_MD" ]] && exit 0

# --- 4. Tool availability (advisory only) ------------------------------------
# User-directed 2026-06-11: this hook no longer auto-formats / re-stages / blocks.
# The silent in-place reformat drifted the gate fingerprint mid-commit (forcing a
# re-smoke), so it is now a non-mutating advisory ("努力目標"). Run
# `md-table-align <file>` yourself when you want tables tidied.
if ! command -v md-table-align >/dev/null 2>&1; then
  exit 0
fi

# --- 5. Check-only advisory (non-mutating, non-blocking) ---------------------
DRIFTED=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$f" ]] || continue
  md-table-align --check "$f" >/dev/null 2>&1 || DRIFTED+=("$f")
done <<< "$STAGED_MD"

if (( ${#DRIFTED[@]} > 0 )); then
  echo "[md-table-gate] (advisory, non-blocking) ${#DRIFTED[@]} staged .md file(s) have unaligned tables — run \`md-table-align <file>\` if you want them tidied (NOT auto-applied):" >&2
  for f in "${DRIFTED[@]}"; do echo "  - $f" >&2; done
fi

exit 0
