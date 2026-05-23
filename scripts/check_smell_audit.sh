#!/usr/bin/env bash
# scripts/check_smell_audit.sh
#
# PreToolUse hook on Bash that physically blocks `git push` when any
# unpushed commit including source-bearing files lacks a
# `Smell-audited:` line in its commit message body. Enforces the
# discipline in CLAUDE.md § Autonomous Workflow Step 6: every
# source-bearing commit records that the Step 6 Bad-Smell self-audit
# was performed.
#
# Source-bearing file set (same as scripts/check_learning_doc.sh):
#   - src/**/*.zig
#   - build.zig, build.zig.zon
#   - .dev/decisions/NNNN_<slug>.md (real ADRs; 0000_template excluded)
#
# Required commit body line:
#   Smell-audited: <depth 0-4>: <one-line summary>
#
# Examples:
#   Smell-audited: 0: clean — no smell triggered
#   Smell-audited: 1: minor — added a one-line note in commit body
#   Smell-audited: 3: ADR-0027 amendment 1 landed in commit abc1234
#
# This script is the deterministic enforcement layer behind the
# probabilistic CLAUDE.md rule (per the 2026-05-23 long-context
# investigation: "CLAUDE.md is a suggestion, hooks make it law").
#
# Safe no-op for any non-`git push` Bash invocation.

set -euo pipefail

# --- 1. Read hook payload from stdin -----------------------------------------
INPUT="$(cat)"

COMMAND="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
print((data.get("tool_input") or {}).get("command", "") or "")
' 2>/dev/null || echo "")"

# --- 2. Only enforce on `git push` -------------------------------------------
if ! printf '%s' "$COMMAND" | grep -qE '(^|[ ;&|])git[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# --- 3. Identify unpushed commits --------------------------------------------
# Compare HEAD to its upstream. If no upstream yet (first push), inspect
# all commits on the current branch.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
if [[ -n "$UPSTREAM" ]]; then
  RANGE="$UPSTREAM..HEAD"
else
  RANGE="HEAD"
fi

UNPUSHED="$(git log --format='%H' "$RANGE" 2>/dev/null || true)"
[[ -z "$UNPUSHED" ]] && exit 0

# --- 4. Helpers --------------------------------------------------------------
is_source_path() {
  case "$1" in
    src/*.zig|build.zig|build.zig.zon)        return 0 ;;
    .dev/decisions/0000_*.md)                  return 1 ;;
    .dev/decisions/[0-9][0-9][0-9][0-9]_*.md) return 0 ;;
    *)                                         return 1 ;;
  esac
}

commit_has_source() {
  local sha="$1"
  local files
  files="$(git show --name-only --format= "$sha" 2>/dev/null || true)"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if is_source_path "$f"; then return 0; fi
  done <<< "$files"
  return 1
}

commit_has_smell_audit() {
  local sha="$1"
  git show --format='%B' --no-patch "$sha" 2>/dev/null \
    | grep -qE '^Smell-audited:[[:space:]]*[0-4][[:space:]]*:'
}

# --- 5. Check each unpushed source-bearing commit ---------------------------
missing=()
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  if commit_has_source "$sha"; then
    if ! commit_has_smell_audit "$sha"; then
      missing+=("$sha")
    fi
  fi
done <<< "$UNPUSHED"

if [[ ${#missing[@]} -eq 0 ]]; then
  exit 0
fi

# --- 6. Block + explain -----------------------------------------------------
cat >&2 <<'EOF'
✗ push blocked by scripts/check_smell_audit.sh

One or more unpushed commits that touch source-bearing files
(src/**/*.zig, build.zig, build.zig.zon, .dev/decisions/NNNN_*.md)
do not record a Step 6 Bad-Smell self-audit.

Required line in the commit body:
    Smell-audited: <depth 0-4>: <one-line summary>

Examples:
    Smell-audited: 0: clean — no smell triggered
    Smell-audited: 1: noted Magic-constant smell (256) inline
    Smell-audited: 3: ADR-0027 amendment 1 landed (commit abc1234)

To recover:
  1. Re-read .dev/principle.md Bad Smell catalogue (8 entries
     incl. Smallest-diff bias / Reservation-as-bias /
     Progress-pressure).
  2. Self-audit the staged diff (depth 0 if clean, 1-4 otherwise).
  3. Amend each missing commit:
       git commit --amend           # interactive editor
       # add the Smell-audited line to the message body
  4. Re-attempt the push.

Missing audit lines on:
EOF
printf '  %s — %s\n' "${missing[@]/#/}" "$(git log --format='%s' -1 "${missing[0]}")" >&2
for sha in "${missing[@]:1}"; do
  printf '  %s — %s\n' "$sha" "$(git log --format='%s' -1 "$sha")" >&2
done

cat >&2 <<'EOF'

(Discipline source: CLAUDE.md § Autonomous Workflow Step 6 + the
2026-05-23 long-context investigation under
`private/notes/llm_long_context_research.md` — hook enforcement is
the deterministic layer behind probabilistic CLAUDE.md rules.)
EOF

exit 2
