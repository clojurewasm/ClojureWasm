#!/usr/bin/env bash
# scripts/perf_campaign_remind.sh
#
# PostToolUse:Bash hook. Force-injects the perf-campaign LOOKAHEAD essence
# (.dev/perf_campaign_essence.md) at every WAIT-point that is NOT already
# covered by a sibling reminder — so a wait never becomes an idle turn-end.
#
# Wait-points it catches (the gate path is owned by gate_continue_remind.sh,
# git commit by post_commit_remind.sh — excluded here to avoid double-fire):
#   - a bench launch (run_bench.sh / compare_langs.sh / record.sh)
#   - a poll-wait loop (`sleep ` inside a for/while — my "is it done yet" polls)
#   - a backgrounded long-runner (trailing `&`)
#   - the remote Ubuntu gate (also a long wait)
#
# Why: the campaign (ROADMAP §9.2.S) drifts toward idle exactly while waiting
# on background work. CLAUDE.md prose dilutes as context grows; a mechanical
# injection at the wait does not. Sibling of gate_continue_remind.sh /
# post_commit_remind.sh. The injected essence is a *don't-drift* guard, not a
# blocking gate.
#
# Inputs: stdin JSON (PostToolUse payload). stdout: JSON
# hookSpecificOutput.additionalContext fed back to Claude.

set -u

ESSENCE="${CLAUDE_PROJECT_DIR:-.}/.dev/perf_campaign_essence.md"
[ -f "$ESSENCE" ] || exit 0

# Campaign pause switch (2026-06-13): the §9.2.S campaign resumes ONLY by
# explicit user direction (handover Resume contract: "Paused (not
# abandoned)"). While paused this reminder must stay SILENT — firing it
# during non-campaign work injects a stale "current front" block at every
# bench-adjacent Bash call (the false-positive-trigger class
# audit_scaffolding hunts). Reactivate by `touch .dev/.perf_campaign_active`
# when the user re-opens the campaign.
[ -f "${CLAUDE_PROJECT_DIR:-.}/.dev/.perf_campaign_active" ] || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)

# Owned-elsewhere: the full gate (gate_continue_remind) + git commit
# (post_commit_remind). Skip so the reminders stay mutually exclusive.
case "$CMD" in
    *"git commit"*) exit 0 ;;
    *run_all.sh*)   exit 0 ;;
esac

# Fire on a genuine wait-point only.
FIRE=0
case "$CMD" in
    *run_bench.sh*|*compare_langs.sh*|*bench/record.sh*|*run_remote_ubuntu.sh*) FIRE=1 ;;
esac
# A poll-wait (`sleep ` in a loop) or a backgrounded long-runner (trailing `&`).
case "$CMD" in
    *"sleep "*) FIRE=1 ;;
esac
grep -qE '&[[:space:]]*$' <<<"$CMD" && FIRE=1

[ "$FIRE" = 1 ] || exit 0

HEADER='[perf-campaign lookahead — do not idle-wait]

A background wait just started. Per the campaign essence below, this wait is
NOT idle time: pick a LOOKAHEAD task (mine v0 for the next lever, survey the next
Python-target, draft the next change into private/, re-profile) and DO it now.
Acknowledge-and-idle is the drift this guard exists to stop. ACT on it with the
same force you give the commit guards.

'
BODY=$(cat "$ESSENCE")
export REMINDER="${HEADER}${BODY}"

python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": os.environ.get("REMINDER", ""),
    }
}))
'
