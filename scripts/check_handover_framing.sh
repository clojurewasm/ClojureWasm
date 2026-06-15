#!/usr/bin/env bash
# scripts/check_handover_framing.sh
#
# PreToolUse:Edit / PreToolUse:Write hook that blocks edits to
# `.dev/handover.md` when the resulting file would contain a
# forbidden phrase or section pattern per
# `.claude/rules/handover_framing.md`.
#
# Discipline source: handover_framing.md "How `/continue` enforces
# this" section. Lifted from manual resume-time grep to deterministic
# hook at Wave 16 (W16-3) per `.claude/rules/framework_completion.md`
# — previously a forbidden phrase could land on the remote before the
# next resume's Step 1 scan caught it.
#
# Behaviour:
#   - On a forbidden phrase / section, prints it + line numbers and
#     exits 2 to BLOCK (both modes).
#   - The 100-line cap is ADVISORY in hook mode (per-edit: warn, never
#     block — the trim-Edit deadlock fix, 2026-06-15) and STRICT in
#     --check mode (audit: over-cap fails). See the line-cap block below.
#
# Modes:
#   default       (hook): runs the check against current
#                          `.dev/handover.md` (= post-edit state, since
#                          Claude Code applies the edit before the
#                          PreToolUse hook fires for Edit/Write tools).
#   --check FILE         : run the check directly against FILE (used
#                          by audit_scaffolding A5b + manual review).
#
# Exit codes:
#   0  pass
#   1  internal error (bad input)
#   2  forbidden phrase / structural issue found; block.

set -u
set -o pipefail
# `set -e` intentionally OFF: forbidden-phrase grep returns 1 on no
# match, which is the success case here. The script uses the FAIL
# accumulator pattern (see L82+) instead of relying on -e.

source "$(dirname "$0")/hook_lib.sh"

# --- Forbidden patterns (synced with handover_framing.md grep) ---------------
# Keep this list verbatim with the rule's recipe. Drift between the
# rule prose and the script regex is itself a smell — refresh both
# together if a new euphemism surfaces.

FORBIDDEN_PHRASES_RE='コンテキスト圧があるため|キリがいい|自然な区切り|natural break|good stopping point|この辺で一旦停止|region boundary stop|task boundary stop|Phase boundary reached AND|If above ~60%|context budget|/compact|user 確認待ち|awaiting user confirmation|awaiting approval|cannot be self-decided|human judgement|human judgment|needs human|user touchpoint|help wanted|awaiting human review|defer to user|ADR-level decision|ADR-phase mode|smell-cluster|smell cluster|patterned smell|goal drift trip|physically blocked|physical block|Stopped — physical block'

FORBIDDEN_SECTIONS_RE='^## Future .* shopping list|^## Notes for the next session'

MAX_LINES=100

# --- Mode dispatch -----------------------------------------------------------
MODE="hook"
TARGET_FILE=".dev/handover.md"
case "${1:-}" in
  --check)
    MODE="check"
    TARGET_FILE="${2:?--check requires a file path}"
    ;;
esac

hook_cd_project_root

# In hook mode, consume stdin to keep the pipe healthy. The actual
# check operates on the post-edit on-disk state (Claude Code applies
# the Edit/Write before firing PreToolUse on those tools).
if [[ "$MODE" == "hook" ]]; then
  # Best-effort: drain stdin without parsing. Edit/Write payload shape
  # is different from Bash, so we do not call hook_read_command here.
  cat >/dev/null 2>&1 || true
  if [[ ! -f "$TARGET_FILE" ]]; then
    exit 0  # handover.md absent; nothing to check
  fi
fi

# --- Run checks --------------------------------------------------------------
if [[ ! -f "$TARGET_FILE" ]]; then
  echo "✗ $TARGET_FILE: file not found" >&2
  exit 1
fi

FAIL=0

LINES=$(wc -l < "$TARGET_FILE" | tr -d ' ')
if (( LINES > MAX_LINES )); then
  # Line-cap policy (2026-06-15, user-directed — the trim-Edit deadlock fix):
  #
  #   - hook mode (per-edit): ADVISORY only, NEVER blocks. Blocking here
  #     created a deadlock the user hit repeatedly — an Edit that REDUCES the
  #     file toward the cap was itself rejected for the file being over cap, so
  #     the only way to trim was a Bash rewrite that bypasses this hook. The
  #     prior git-HEAD-based "trim-Edit exemption" did not cover the common case
  #     (the over-cap state was introduced by THIS session's own uncommitted
  #     edits, so HEAD was still ≤ cap → exemption never granted). Per-edit we
  #     now only WARN so a trim chain lands freely via the Edit tool.
  #   - --check mode (audit, audit_scaffolding A5b): STRICT — any over-cap
  #     snapshot fails, so the 100-line cap is still enforced, just at the audit
  #     boundary rather than as a per-edit block.
  #
  # The forbidden-phrase / section checks below STAY blocking in both modes —
  # those (surrender framing etc.) are the load-bearing gate; the line cap is a
  # soft quality bound. (Mirrors the md-table-align hook → advisory, 2026-06-11.)
  if [[ "$MODE" == "check" ]]; then
    echo "" >&2
    echo "✗ handover.md exceeds the $MAX_LINES-line cap (= $LINES lines)" >&2
    echo "  Trim per handover_framing.md before commit." >&2
    FAIL=1
  else
    echo "" >&2
    echo "⚠ handover.md is over the $MAX_LINES-line cap ($LINES lines) — advisory" >&2
    echo "  only (the audit enforces it); keep trimming toward ≤ $MAX_LINES." >&2
  fi
fi

PHRASE_HITS=$(grep -nE "$FORBIDDEN_PHRASES_RE" "$TARGET_FILE" 2>/dev/null || true)
if [[ -n "$PHRASE_HITS" ]]; then
  echo "" >&2
  echo "✗ handover.md contains forbidden phrase(s) per .claude/rules/handover_framing.md:" >&2
  echo "$PHRASE_HITS" | sed 's/^/  /' >&2
  FAIL=1
fi

SECTION_HITS=$(grep -nE "$FORBIDDEN_SECTIONS_RE" "$TARGET_FILE" 2>/dev/null || true)
if [[ -n "$SECTION_HITS" ]]; then
  echo "" >&2
  echo "✗ handover.md contains forbidden section heading(s):" >&2
  echo "$SECTION_HITS" | sed 's/^/  /' >&2
  FAIL=1
fi

# grep -c returns 0 with exit 1 when no matches, and `|| echo 0` then
# appends another "0" → multi-line value breaks arithmetic. Use a
# direct line-count via wc instead.
JUST_LANDED_COUNT=$(grep -c '^## Just landed' "$TARGET_FILE" 2>/dev/null | head -1)
JUST_LANDED_COUNT=${JUST_LANDED_COUNT:-0}
if (( JUST_LANDED_COUNT > 1 )); then
  echo "" >&2
  echo "✗ handover.md has $JUST_LANDED_COUNT \"## Just landed\" sections; the rule allows at most one." >&2
  FAIL=1
fi

if [[ $FAIL -eq 0 ]]; then
  [[ "$MODE" == "check" ]] && echo "OK $TARGET_FILE clean ($LINES lines, no forbidden phrases)"
  exit 0
fi

cat >&2 <<'EOF'

To recover:
  1. Re-read .claude/rules/handover_framing.md (forbidden-phrase table
     + length cap + section rules).
  2. Replace the forbidden phrase with the suggested alternative
     wording (the rule lists each phrase + its replacement).
  3. Trim to ≤ 100 lines if length exceeded — `git log` and ROADMAP
     are the SSOTs for history and forecast respectively.

(Discipline source: .claude/rules/handover_framing.md.)
EOF
exit 2
