#!/usr/bin/env bash
# cleanup_orphans.sh — reap this repo's long-lived orphaned test processes.
#
#   bash scripts/cleanup_orphans.sh          # reap, print what was killed
#   bash scripts/cleanup_orphans.sh --dry-run
#
# Wired as a SessionStart hook so a session that was interrupted mid-gate does
# not leave a core spinning until the machine is noticed (the 2026-05-28
# incident in ADR-0049 § Context: an orphaned REPL pipeline spun ~1h50m).
# `scripts/run_gate.sh reap` covers the same ground WITHIN a session; this is
# the ACROSS-session backstop.
#
# History: `memory 20260909234832-598b7c16 (orphan_prevention)` and `.dev/reference_clones.md`
# both cited `~/.claude/hooks/cleanup_orphans.sh` as the live reaper. That file
# did not exist on the maintainer machine and could not exist on anyone else's
# — it was outside the repo, so cloning never brought it. An orphan guarantee
# nothing implements is worse than no guarantee, because the disciplines
# elsewhere ("background long-runners are backstopped") were written assuming
# it. Shipping it in-repo makes the claim true for every clone (D-565 item 3).
#
# Safety: a process is eligible only when it is orphaned (PPID 1) AND older
# than AGE_MIN minutes AND matches one of the test-machinery shapes below. An
# interactive `cljw` REPL the user is typing into has a real parent, so it is
# never touched.
#
# Scope, stated honestly: `bash test/run_all.sh` appears in `ps` with a
# RELATIVE path, so a sibling checkout's orphaned gate is indistinguishable
# from ours and would also be reaped. That is deliberate and matches the
# precedent — in the 2026-05-28 incident it was the sibling zwasm session that
# reaped this repo's orphan (ADR-0049 § Context). A `cljw` binary is matched by
# absolute path, so that one IS repo-scoped.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd -P)"

AGE_MIN="${CLEANUP_ORPHANS_AGE_MIN:-30}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# etime is [[dd-]hh:]mm:ss — normalise to minutes so the age test is one number.
etime_minutes() {
    printf '%s\n' "$1" | awk -F'[-:]' '{
        if (NF == 4)      { print $1*1440 + $2*60 + $3 }
        else if (NF == 3) { print $1*60 + $2 }
        else              { print $1 }
    }'
}

# The eligible command shapes. Each is a process this repo's own tooling
# starts and that has been observed (or could plausibly be) left behind:
#   run_all.sh / run_gate.sh — the gate tree itself
#   cljw                     — a probe or REPL pipe the gate spawned
#   clojure.main -e          — a `clj` differential-oracle JVM (these are the
#                              memory hazard, not just CPU: see
#                              orphan_prevention.md rule 3)
is_eligible() {
    case "$1" in
        *run_all.sh*|*run_gate.sh*) return 0 ;;
        *clojure.main*-e*) return 0 ;;
        *) [[ "$1" == "$REPO"/zig-out/bin/cljw* ]] && return 0 ;;
    esac
    return 1
}

killed=0
scanned=0
while read -r pid ppid etime cmd; do
    [[ "$pid" == "PID" ]] && continue
    scanned=$((scanned + 1))
    [[ "$ppid" == "1" ]] || continue
    is_eligible "$cmd" || continue
    mins=$(etime_minutes "$etime")
    [[ "$mins" -ge "$AGE_MIN" ]] || continue
    if [[ "$DRY" == "1" ]]; then
        echo "cleanup_orphans: WOULD kill pid=$pid (${mins}m, orphaned) $cmd"
    else
        # TERM first: the gate tree traps it and removes its stamp files. A
        # KILL straight away would leave `.dev/.gate_pass` claiming a pass that
        # never finished.
        kill -TERM "$pid" 2>/dev/null || true
        echo "cleanup_orphans: killed pid=$pid (${mins}m, orphaned) $cmd"
    fi
    killed=$((killed + 1))
done < <(ps -eo pid=,ppid=,etime=,command= 2>/dev/null || true)

if [[ "$killed" -eq 0 ]]; then
    # Silent on the common path: a SessionStart hook that prints on every clean
    # start trains the reader to skip its output, which is when it stops working
    # as a warning.
    exit 0
fi
echo "cleanup_orphans: $killed orphan(s) reaped of $scanned process(es) scanned (threshold ${AGE_MIN}m)."
echo "  An orphan here means a background long-runner outlived its session — check that its"
echo "  launch site wraps with 'timeout' per memory 20260909234832-598b7c16 (orphan_prevention)."
