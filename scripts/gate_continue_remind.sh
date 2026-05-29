#!/usr/bin/env bash
# scripts/gate_continue_remind.sh
#
# PostToolUse hook for Bash. When a test gate just launched
# (`test/run_all.sh` or the remote `scripts/run_remote_ubuntu.sh`),
# re-inject the autonomous-loop "do not idle-wait on the gate" rule.
#
# Why this exists: the gate is the single point where the loop drifts
# into a de-facto stall — an "awaiting the gate result" turn-end with
# nothing pending. CLAUDE.md prose dilutes as context grows; a
# mechanical injection at the exact stall point does not. Sibling of
# scripts/post_commit_remind.sh (the commit-boundary backstop).
#
# Inputs: stdin JSON from Claude Code (PostToolUse hook payload).
# stdout: JSON hookSpecificOutput.additionalContext fed back to Claude.

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
    # A `git commit` whose message merely mentions the gate path is NOT a
    # gate run — the post-commit hook owns that boundary. Exclude it so the
    # two reminders stay mutually exclusive (no double-fire).
    *"git commit"*)
        exit 0
        ;;
    *run_all.sh*|*run_remote_ubuntu.sh*)
        ;;
    *)
        exit 0
        ;;
esac

REMINDER=$(cat <<'EOF'
[gate reminder — do not stop]

A test gate just launched. The loop's only stop is the user's
explicit directive (CLAUDE.md § The only stop) — an "awaiting the
gate" turn-end with nothing pending is the de-facto stall to avoid.
While the gate runs, prep the NEXT task with READS + notes (working
tree untouched until the gate is green and the prior commit lands);
on completion, commit and roll into the next unit. CAUTION: do NOT
dispatch a CPU-heavy subagent (a Step-0 survey) concurrently with the
gate — it contends with the perf-threshold steps (e.g. cold_start)
and causes FALSE failures; dispatch surveys AFTER the gate completes.
End a turn only with a still-running harness task OR a
ScheduleWakeup(prompt:"continue") long backstop — never a bare
recap. Auto-compaction is transparent; size is never a reason to stop.
EOF
)

export REMINDER
python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": os.environ.get("REMINDER", ""),
    }
}))
'
