---
name: continue
description: Resume autonomous work on cw-from-scratch. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", or starts a fresh session expecting prior context. Reads handover, finds next task, summarises, waits for go.
---

# continue

Pick up where the previous session left off. Authoritative resume
procedure for cw-from-scratch.

## Resume procedure (run on every session pickup)

1. Read `.dev/handover.md`. If it does not exist, note that and continue.
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9 (the table at the top). If none is
     in-progress, take the first PENDING phase.
   - In that phase's expanded task list (§9.3 for Phase 1, §9.4 for
     Phase 2, etc.), find the first `[ ]` task. If the section is empty,
     the phase has not been opened yet — say so and stop.
3. `git log --oneline -10` — identify any unpaired source commits since
   the last `docs/ja/NNNN-*.md` commit (walk back; commits whose
   diff includes `src/**/*.zig`, `build.zig`, `build.zig.zon`, or
   `.dev/decisions/NNNN-*.md` count as source).
4. `bash test/run_all.sh` — confirm the build is green.
5. Summarise to the user in 5–8 lines:
   - Phase (number + name)
   - Last commit (`git log -1 --format='%h %s'`)
   - Test status
   - Unpaired source SHAs (if any) — these must be addressed first
   - Next task (number + name + exit criterion)
6. **Wait for the user's "go"** before starting any TDD step. Do not
   start coding without confirmation.

Keep the summary terse; the user will read the handover for full context.

## Per-task TDD loop (after "go")

1. **Plan** the smallest red test (1 sentence in chat).
2. **Red**: write the failing test.
3. **Green**: minimal code to pass.
4. **Refactor** while green.
5. `bash test/run_all.sh` must be green at every step.
6. **Source commit**: stage only source files; `git commit -m "<type>(<scope>): <one line>"`.
7. Repeat 1–6 as the unit of work needs (the gate does not block
   multiple source commits in a row).
8. **Doc commit**: when the story is ready, write
   `docs/ja/NNNN-<slug>.md` per the `code-learning-doc` skill; commit
   with `commits: [...]` listing every source SHA since the last doc.
9. **Update** `.dev/handover.md` with 1–2 lines (current task + blocker
   if any).

## Periodic scaffolding audit

Every Phase boundary (or every ~10 ja docs), invoke `/audit-scaffolding`
to detect staleness, bloat, dead references, and false-positive triggers
across `.dev/`, `docs/`, `.claude/`, `CLAUDE.md`, and `scripts/`. The
audit is non-destructive — it produces a report; you decide what to fix.
