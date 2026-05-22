# continue skill — LOOP policies

> Loaded together with SKILL.md. Stable policies (rare changes) sit
> here, separate from per-task steps (frequent changes).

## Self-perpetuation

After completing a per-task TDD cycle, `/continue` re-arms via:

```
ScheduleWakeup(delaySeconds=60, prompt="<original /continue input>",
               reason="awaiting cw v1 next task <task-id>")
```

### Why 60 seconds

1. Quick handoff in active sessions.
2. Stays within the Anthropic prompt cache TTL (5 min).
3. Aligns with handover.md update cadence (commit -> next task).
4. Buffers `git push` confirmation lag.
5. Short enough that idle re-arm wastes minimal compute.

## Git operations are serial

`.git/index.lock` race defense:

1. Before any git command, `scripts/check_stale_git_lock.sh` runs
   (PreToolUse Bash hook).
2. If the lock is >60s old and no `git` process holds it, remove it.
3. Otherwise the hook backs off; caller retries.

## Stop conditions

`/continue` stops (does NOT re-arm) under exactly these conditions:

1. **`git push` permission required**: cw v1 ROADMAP forbids push
   without user approval.
2. **Ambiguous test failure**: not a known false positive; root cause
   unclear.
3. **Audit `block` finding**: `audit_scaffolding` returned a blocker.
4. **ADR-level decision**: e.g., tier classification change, scope
   shift.
5. **Phase boundary**: at Phase close, after handover.md update review.

In all other cases, re-arm.

## Step 0.5: Debt sweep

Before Step 1 (Read handover.md), execute:

1. Read `.dev/debt.md`.
2. For each row where Last reviewed > 14 days ago:
   - Re-evaluate the Barrier predicate (grep / test / git log).
   - If the barrier dissolved: flip Status from `blocked-by: X` to
     `now`.
   - If not: update Last reviewed to today.
3. If any row flipped to `now`, surface it in Step 1a (handover rewrite).

Per `.claude/rules/debt_dedup.md` and `.claude/rules/no_handover_predictions.md`.

## Phase 4 reading list

Phase 4 entry and onward, per-task Step 0 reads (in order):

1. `.dev/handover.md` — current state.
2. `.dev/ROADMAP.md` §9.6 — Phase 4 task list, especially the active
   row.
3. `.dev/decisions/0004.md` and later ADRs — design decisions
   referenced by the active task.
4. `compat_tiers.yaml` — tier classification for the function being
   implemented.
5. JVM Clojure source (`~/Documents/OSS/clojure/`) — canonical
   semantics for the function.

The five sources are self-contained for Phase 4 task execution. Working
notes outside this set are not part of the canonical reading.

## Multi-host pivot strategy

Currently: Mac host + OrbStack Ubuntu x86_64.

- Phase 4-5: status quo (OrbStack as gate).
- Phase 6+ (re-evaluate): OrbStack as scratch host, remote Linux x86_64
  SSH host as gate. Rationale: long-running JIT cycles encounter
  Rosetta translation races on OrbStack; native SSH host eliminates
  this class of flake.
- Phase 13+: Windows track is separate (per ROADMAP §3 scope).

## ScheduleWakeup reasons

The `reason` field is specific:

- OK: "awaiting cw v1 next task §9.6 / 4.0"
- OK: "watching CI build cw v1 §9.6 / 4.2 errdefer"
- NG: "waiting"
- NG: "continue loop"

The reason goes to telemetry and is shown to the user.
