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
# 2026-05-31; see `memory 20260909234832-598b7c16 (orphan_prevention)` + memory
# `premature-gate-notification`.) The SessionStart `cleanup_orphans.sh`
# only reaps at etime > 30 min — far too long for a ~50 s gate.
#
# WHAT IT DOES — makes "one gate at a time, no orphans" structural:
#   1. Reap any PRIOR `test/run_all.sh` tree (TERM then KILL).
#   2. Reap `cljw` probes orphaned to PID 1 (re-parented when their gate
#      died) — precise: ppid==1 only, so a live gate's children and any
#      legitimate interactive `cljw` are untouched.
#   3. Run exactly ONE gate under a bounded timeout (default 2700 s). The
#      bound exists to kill a STUCK gate, so it must sit above what a healthy
#      one costs — "a bound that kills a healthy gate is worse than no bound:
#      it exits 0 through a pipeline and reads as a pass."
#
#      That is not hypothetical. The bound was 900 s, sized against a
#      "~350 s serial gate"; the suite has since grown past it, and 900 s
#      SIGTERMed healthy gates mid-e2e. Measured 2026-08-19 on the CI runners
#      — the same `--serial-e2e` configuration this launcher runs — the full
#      gate takes **1009 s (macOS) / 1491 s (Linux)** COLD. So the old default
#      could not complete a full gate on any host, and the kill presented as a
#      log that simply stopped. 2700 s is ~1.8x the slowest measured cold run:
#      above every healthy gate, still far below "wait forever".
#
#      Re-derive this number whenever the gate's cost changes materially; a
#      stale bound here fails silently, which is the worst way to fail.
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
TIMEOUT="${GATE_TIMEOUT:-2700}"

# CO-TENANCY: this reap must only ever touch processes belonging to THIS
# checkout. `pgrep -f 'test/run_all.sh'` matches every gate on the machine, and
# the command line is relative (`bash test/run_all.sh --serial-e2e`), so the
# pattern alone cannot tell one worktree from another. It used to kill them all.
#
# Measured 2026-08-19: a peer session's `--smoke`, running in a sibling git
# worktree of this repo, was TERMed then KILLed the moment a gate started here.
# It died with zero bytes of output — a signal death flushes nothing — and read
# as a mysterious `exit 144`. The peer attributed it to CPU contention and to
# having broken the "the full gate runs ALONE" rule. It was neither: that rule
# is about load, and no amount of obeying it protects you from another
# checkout's `pkill`.
#
# So every candidate is filtered by its working directory. Same for the orphan
# `cljw` sweep: that one is additionally guarded by ppid==1, which spared the
# peer's long-running MCP servers — but by luck, not by design. A daemonized
# process is one `nohup` away from matching, and killing a teammate's server is
# not something to leave to luck.
REPO_ROOT=$(pwd -P)

# The working directory of a pid, or empty when it cannot be determined.
# /proc on Linux; lsof on macOS, where /proc does not exist.
proc_cwd() {
    if [ -r "/proc/$1/cwd" ]; then
        readlink -f "/proc/$1/cwd" 2>/dev/null
    else
        lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n 1p
    fi
}

# The executable behind a pid, resolved absolute, or empty.
proc_exe() {
    if [ -r "/proc/$1/exe" ]; then
        readlink -f "/proc/$1/exe" 2>/dev/null
    else
        lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n 1p
    fi
}

# True when the pid RUNS THIS CHECKOUT'S BINARY. The right test for an orphaned
# `cljw`: several e2e `cd` into a temp working directory, so a probe left behind
# by this gate can have a cwd nowhere near the repo, and a cwd-only filter would
# refuse to reap the very orphans this function exists for. The binary path does
# not move.
ours_binary() {
    local exe
    exe=$(proc_exe "$1")
    [ -n "$exe" ] || return 1
    case "$exe" in
        "$REPO_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# True when the pid is running inside this checkout. UNKNOWN COUNTS AS FOREIGN:
# a process whose cwd cannot be read (another user's, already exited, lsof
# absent) is left alone. Failing closed costs at most one stale gate surviving —
# failing open costs a teammate their work, which is the bug being fixed.
ours() {
    local cwd
    cwd=$(proc_cwd "$1")
    [ -n "$cwd" ] || return 1
    case "$cwd" in
        "$REPO_ROOT"|"$REPO_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

reap_gates() {
    local pid ppid n foreign
    n=0; foreign=0
    for pid in $(pgrep -f 'test/run_all.sh' 2>/dev/null); do
        [ "$pid" = "$SELF" ] && continue
        if ours "$pid"; then n=$((n + 1)); else foreign=$((foreign + 1)); fi
    done
    [ "$foreign" -gt 0 ] && \
        echo "run_gate: leaving $foreign gate tree(s) from another checkout alone" >&2
    if [ "$n" -gt 0 ]; then
        echo "run_gate: reaping $n prior gate tree(s) in $REPO_ROOT" >&2
        for pid in $(pgrep -f 'test/run_all.sh' 2>/dev/null); do
            [ "$pid" = "$SELF" ] && continue
            ours "$pid" && { kill -TERM "$pid" 2>/dev/null || true; }
        done
        sleep 1
        for pid in $(pgrep -f 'test/run_all.sh' 2>/dev/null); do
            [ "$pid" = "$SELF" ] && continue
            ours "$pid" && { kill -KILL "$pid" 2>/dev/null || true; }
        done
    fi
    # `cljw` probes orphaned to PID 1 — from the kill above, or a prior
    # gate that already exited leaving a large-input probe spinning.
    for pid in $(pgrep -f 'zig-out/bin/cljw' 2>/dev/null); do
        [ "$pid" = "$SELF" ] && continue
        ours_binary "$pid" || ours "$pid" || continue
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

# `--serial-e2e` unless the caller already picked a mode. THE LOCAL FULL GATE
# MUST RUN WHAT CI RUNS. `scripts/ci_gate.sh` passes `--serial-e2e`; this script
# passed nothing, so `run_all.sh` defaulted to `PARALLEL_E2E=1` and the local
# "full gate green" validated a DIFFERENT configuration from the one that
# gates a push. That divergence is how a serial-only failure reached CI green-
# locally (2026-08-04: an EPIPE race in an e2e, invisible in the parallel path
# because each parallel job's output is captured to a file rather than piped).
# CLAUDE.md and handover have both said "the FULL gate MUST run --serial-e2e"
# for months; nothing made it true.
#
# Pass `--jobs N` or `--smoke` explicitly to opt out.
MODE=(--serial-e2e)
for a in "$@"; do
    case "$a" in
        --serial-e2e | --jobs | --smoke) MODE=() ;;
    esac
done

# NOT `exec`: the timeout's own verdict has to be reported. A gate killed by
# the bound otherwise looks exactly like a gate that stopped printing — the
# summary line is simply absent, and a caller reading the tail of the log sees
# the last passing step and infers a pass. Say it out loud instead.
timeout "$TIMEOUT" bash test/run_all.sh "${MODE[@]}" "$@"
rc=$?
if [ "$rc" -eq 124 ]; then
    cat >&2 <<EOF

run_gate: TIMED OUT after ${TIMEOUT}s — the gate was KILLED, not failed.
  No summary line was printed, so nothing here is a verdict on the code.
  If the gate is merely slow (the suite grew), raise the bound:
      GATE_TIMEOUT=$((TIMEOUT * 2)) bash scripts/run_gate.sh
  and re-derive the default in this script's header from the new measurement.
EOF
fi
exit "$rc"
