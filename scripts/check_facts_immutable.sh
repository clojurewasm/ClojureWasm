#!/usr/bin/env bash
# scripts/check_facts_immutable.sh
#
# PreToolUse hook on Bash. Blocks `git commit` when the commit stages
# a modification to `.dev/project_facts.md`'s F-NNN body without
# either:
#
#   (a) a matching `Revision history` update inside the same F-NNN
#       block AND a `Project-facts-amend: F-NNN` line in the commit
#       message body, or
#   (b) the addition of a NEW F-NNN section (= append-only growth, no
#       gate needed for net-new entries).
#
# Rationale: project_facts.md is project law per the file's preamble
# ("This file is project law"). The autonomous loop must NEVER amend
# an F-NNN on its own initiative. This hook is the deterministic
# enforcement behind that probabilistic rule.
#
# Recovery procedure (printed on block):
#   1. Confirm the user actually directed the F-NNN amendment in chat.
#   2. Append a Revision history entry to the affected F-NNN (date +
#      summary + user's verbatim quote).
#   3. Add `Project-facts-amend: F-NNN — <one-line>` to the commit
#      message body.
#   4. Re-stage and re-commit.

set -euo pipefail

# --- 1. Shared helpers (Wave 16) ---------------------------------------------
source "$(dirname "$0")/hook_lib.sh"

# --- 2. Only enforce on `git commit` -----------------------------------------
hook_read_command
hook_is_git_commit || exit 0
hook_cd_project_root

COMMAND="$HOOK_COMMAND"  # used by the commit-message extraction below

# --- 3. Is .dev/project_facts.md staged? -------------------------------------
STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
[[ -z "$STAGED" ]] && exit 0

# here-string (not `printf | grep -q`): grep -q short-circuits on first match
# and closes the pipe, so a still-writing printf hits SIGPIPE and pipefail turns
# the pipeline non-zero — `if !` would then invert a genuine match into a
# phantom "not staged" pass-through.
if ! grep -qx '\.dev/project_facts\.md' <<<"$STAGED"; then
  exit 0  # not touching project_facts; pass through
fi

# --- 4. Detect modified F-NNN sections ---------------------------------------
# Strategy: diff the staged version against HEAD; look for changes inside
# blocks demarcated by `^## F-NNN — …`. New F-NNN sections (lines added that
# start with `## F-NNN`) are append-only growth and OK without amend marker.
#
# Algorithm:
#   - List F-NNN headers in HEAD and in staged.
#   - F-NNN present in both BUT with body diff → "modified" → amend gate.
#   - F-NNN in staged only → "new" → OK.
#   - F-NNN in HEAD only → "removed" → blocked unconditionally (Supersedes
#     is the right path, not deletion).

# Get the F-NNN headers from both sides.
HEAD_HEADERS="$(git show HEAD:.dev/project_facts.md 2>/dev/null | grep -E '^## F-[0-9]+ ' || true)"
STAGED_FILE="$(mktemp)"
trap 'rm -f "$STAGED_FILE"' EXIT
git show ":.dev/project_facts.md" > "$STAGED_FILE" 2>/dev/null || true
STAGED_HEADERS="$(grep -E '^## F-[0-9]+ ' "$STAGED_FILE" || true)"

# F-NNN ids present in each side
head_ids="$(printf '%s\n' "$HEAD_HEADERS"   | grep -oE 'F-[0-9]+' | sort -u || true)"
staged_ids="$(printf '%s\n' "$STAGED_HEADERS" | grep -oE 'F-[0-9]+' | sort -u || true)"

# Removed F-NNN
removed="$(comm -23 <(printf '%s\n' "$head_ids") <(printf '%s\n' "$staged_ids") 2>/dev/null || true)"
if [[ -n "$removed" ]]; then
  cat >&2 <<EOF
✗ commit blocked by scripts/check_facts_immutable.sh
project_facts.md removes an F-NNN entry:
$removed

F-NNN entries are append-only. A fact that no longer holds must be
superseded (add a new F-NNN with \`Supersedes: F-<old>\` and mark the
old entry \`Superseded by: F-<new>\`), not deleted.
EOF
  exit 2
fi

# Common F-NNN ids (present in both) — check for body diff
common_ids="$(comm -12 <(printf '%s\n' "$head_ids") <(printf '%s\n' "$staged_ids") 2>/dev/null || true)"

modified_ids=()
for fid in $common_ids; do
  # Extract the F-NNN body from HEAD and staged. Body = from "## F-NNN" up to
  # the next "## F-NNN" header (exclusive) or EOF.
  head_body="$(git show HEAD:.dev/project_facts.md 2>/dev/null | awk -v id="^## $fid " '
    $0 ~ id {grab=1; print; next}
    grab && /^## F-[0-9]+ / {grab=0; exit}
    grab {print}
  ')"
  staged_body="$(awk -v id="^## $fid " '
    $0 ~ id {grab=1; print; next}
    grab && /^## F-[0-9]+ / {grab=0; exit}
    grab {print}
  ' "$STAGED_FILE")"

  if [[ "$head_body" != "$staged_body" ]]; then
    modified_ids+=("$fid")
  fi
done

[[ ${#modified_ids[@]} -eq 0 ]] && exit 0

# --- 5. For each modified F-NNN, check the gate -------------------------------
# Gate: (a) the staged F-NNN body contains a NEW Revision history entry
# (= an entry not present in HEAD), AND (b) the commit message contains a
# `Project-facts-amend: F-NNN` line for each modified id.

# Read the proposed commit message.
COMMIT_MSG=""
if [[ -f .git/COMMIT_EDITMSG ]]; then
  COMMIT_MSG="$(cat .git/COMMIT_EDITMSG 2>/dev/null || true)"
fi

# Fallback: the `git commit -m "..."` form embeds the message in the
# command line. Extract from the captured COMMAND if .git/COMMIT_EDITMSG is
# absent or empty.
if [[ -z "$COMMIT_MSG" ]]; then
  # Best-effort extract -m argument(s). Multiple -m flags concatenate.
  COMMIT_MSG="$(printf '%s' "$COMMAND" | python3 -c '
import re, sys
cmd = sys.stdin.read()
# Find -m "..." or -m '"'"'...'"'"'
msgs = re.findall(r"""-m\s+(["\x27])((?:(?!\1).|\\.)*?)\1""", cmd, re.DOTALL)
print("\n\n".join(m[1] for m in msgs))
' 2>/dev/null || echo "")"
fi

missing_amend=()
missing_revhist=()
for fid in "${modified_ids[@]}"; do
  # (b) commit message must contain `Project-facts-amend: F-NNN`
  # here-string, not `printf | grep -q` (broken-pipe/pipefail race — see L43).
  if ! grep -qE "^Project-facts-amend:[[:space:]]*$fid([[:space:]]|—|-|:|$)" <<<"$COMMIT_MSG"; then
    missing_amend+=("$fid")
  fi
  # (a) staged body must contain a Revision history mention
  head_revhist="$(git show HEAD:.dev/project_facts.md 2>/dev/null | awk -v id="^## $fid " '
    $0 ~ id {grab=1; next}
    grab && /^## F-[0-9]+ / {exit}
    grab && /^\*\*Revision history\*\*/ {found=1}
    grab && found {print}
    END {exit !found}
  ' || true)"
  staged_revhist="$(awk -v id="^## $fid " '
    $0 ~ id {grab=1; next}
    grab && /^## F-[0-9]+ / {exit}
    grab && /^\*\*Revision history\*\*/ {found=1}
    grab && found {print}
    END {exit !found}
  ' "$STAGED_FILE" || true)"
  if [[ "$head_revhist" == "$staged_revhist" ]]; then
    missing_revhist+=("$fid")
  fi
done

if [[ ${#missing_amend[@]} -eq 0 && ${#missing_revhist[@]} -eq 0 ]]; then
  exit 0
fi

cat >&2 <<'EOF'
✗ commit blocked by scripts/check_facts_immutable.sh

project_facts.md amends one or more F-NNN entries, but the
required guard is missing. F-NNN entries are project law
(autonomous loop must never amend on its own initiative).

Required for each modified F-NNN:
  (a) The F-NNN block must contain a NEW Revision history entry
      (date + summary + user's verbatim quote).
  (b) The commit message body must contain a line:
        Project-facts-amend: F-NNN — <one-line summary>

EOF

if [[ ${#missing_amend[@]} -gt 0 ]]; then
  printf 'Missing `Project-facts-amend:` line in commit message for:\n' >&2
  for fid in "${missing_amend[@]}"; do
    printf '  - %s\n' "$fid" >&2
  done
  echo >&2
fi

if [[ ${#missing_revhist[@]} -gt 0 ]]; then
  printf 'No new Revision history entry detected in:\n' >&2
  for fid in "${missing_revhist[@]}"; do
    printf '  - %s\n' "$fid" >&2
  done
  echo >&2
fi

cat >&2 <<'EOF'
Recovery:
  1. Confirm the user directed the F-NNN amendment in chat
     (re-read recent messages). If no user direction was given,
     UNDO the F-NNN edit — the loop is not allowed to amend on
     its own initiative.
  2. Append a Revision history entry to the affected F-NNN
     block (date + summary + user's verbatim quote).
  3. Add `Project-facts-amend: F-NNN — <one-line>` line to the
     commit message body.
  4. Re-stage and re-commit.
EOF

exit 2
