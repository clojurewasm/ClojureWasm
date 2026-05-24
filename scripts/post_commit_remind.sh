#!/usr/bin/env bash
# scripts/post_commit_remind.sh
#
# PostToolUse hook for Bash. When `git commit` just ran, re-inject the
# autonomous-loop continuation reminder from CLAUDE.md § The only stop
# + § Autonomous Workflow "Loop: Step 0 → 7 → next task's Step 0".
#
# Why this exists: CLAUDE.md is loaded once per session; long sessions
# accumulate momentum drift where the loop's "only stop is user
# explicit stop" rule fades from active recall. Re-injecting the rule
# at every commit lands it at the exact moment the drift is most
# likely (just after Step 6, before the next task's Step 0).
#
# Inputs: stdin JSON from Claude Code (PostToolUse hook payload).
# stdout: reminder text fed back to Claude as tool result feedback.

set -u

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)

case "$CMD" in
    *"git commit"*)
        ;;
    *)
        exit 0
        ;;
esac

cat <<'EOF'
[post-commit reminder per CLAUDE.md § The only stop]

A commit just landed. The autonomous TDD loop continues without
pause:

  - Step 6 commit + push → Step 7 per-task note (from hot context,
    private/notes/<phase>-<task>.md) → next task's Step 0 (general-
    purpose subagent survey unless the task qualifies for skip per
    .claude/rules/textbook_survey.md).
  - Do NOT pause for user direction. The only stop is the user
    explicit stop directive (CLAUDE.md § The only stop). Task /
    region / cluster / commit / Phase boundaries all roll into the
    next unit of work.
  - Smell triggers are interrupts (in-flight surgery), not stops.
    Build / test failures are Active-task items.
  - Status summaries to the user are fine and often useful; what
    is forbidden is using a summary as a stop rationalisation
    (handover_framing.md forbidden-phrase table: "good stopping
    point" / "キリがいい" / etc).
  - Phase boundary chain (audit_scaffolding + simplify + security-
    review + §9.<N+1> open) is itself in-loop work.

Active task lives in .dev/handover.md "Active task" — read it,
then start Step 0 of the next task without pause.
EOF
