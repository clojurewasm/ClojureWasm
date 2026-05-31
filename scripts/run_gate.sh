#!/usr/bin/env bash
# scripts/run_gate.sh — single-gate launcher with orphan reaping.
#
# WHY THIS EXISTS
# Re-running the full Mac gate (`bash test/run_all.sh`) — especially when
# a *premature* task-completion notification leads to starting a new gate
# while an old one is still at its e2e step — stacks `run_all.sh` process
# trees. Each tree forks e2e sub-shells + `cljw -e` large-input probes
# (e.g. `(count (interleave (range 50000) …))`). When a gate is killed or
# times out, its `cljw` children **re-parent to PID 1 and keep running**,
# so the pile drives load to 10–17 and garbles tool output. (Incident
# 2026-05-31; see `.claude/rules/orphan_prevention.md` + memory
# `premature-gate-notification`.) The SessionStart `cleanup_orphans.sh`
# only reaps at etime > 30 min — far too long for a ~50 s gate.
#
# WHAT IT DOES — makes "one gate at a time, no orphans" structural:
#   1. Reap any PRIOR `test/run_all.sh` tree (TERM then KILL).
#   2. Reap `cljw` probes orphaned to PID 1 (re-parented when their gate
#      died) — precise: ppid==1 only, so a live gate's children and any
#      legitimate interactive `cljw` are untouched.
#   3. Run exactly ONE gate under a bounded timeout (default 300 s —
#      generous for a ~50 s gate once nothing contends; a gate that
#      exceeds it is stuck, not slow, so killing it is correct).
#
# USAGE
#   bash scripts/run_gate.sh                 # reap + run one gate
#   bash scripts/run_gate.sh --only foo      # args pass through to run_all.sh
#   bash scripts/run_gate.sh reap            # reap orphans only, no gate
#   GATE_TIMEOUT=420 bash scripts/run_gate.sh   # override the bound
#
# `.dev/.gate_pass` / `.dev/.gate_cadence` are written by run_all.sh
# itself, so `check_gate_cadence.sh` authorises commits exactly as before.

set -uo pipefail
cd "$(dirname "$0")/.."

SELF=$$
TIMEOUT="${GATE_TIMEOUT:-300}"

reap_gates() {
    local pid ppid n
    n=$(pgrep -f 'test/run_all.sh' 2>/dev/null | grep -vxc "$SELF" || true)
    if [ "${n:-0}" -gt 0 ]; then
        echo "run_gate: reaping $n prior gate tree(s)" >&2
        for pid in $(pgrep -f 'test/run_all.sh' 2>/dev/null); do
            [ "$pid" = "$SELF" ] || kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in $(pgrep -f 'test/run_all.sh' 2>/dev/null); do
            [ "$pid" = "$SELF" ] || kill -KILL "$pid" 2>/dev/null || true
        done
    fi
    # `cljw` probes orphaned to PID 1 — from the kill above, or a prior
    # gate that already exited leaving a large-input probe spinning.
    for pid in $(pgrep -f 'zig-out/bin/cljw' 2>/dev/null); do
        [ "$pid" = "$SELF" ] && continue
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ "$ppid" = "1" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            echo "run_gate: reaped orphan cljw $pid (ppid 1)" >&2
        fi
    done
}

reap_gates

if [ "${1:-}" = "reap" ]; then
    echo "run_gate: reap-only complete" >&2
    exit 0
fi

exec timeout "$TIMEOUT" bash test/run_all.sh "$@"
