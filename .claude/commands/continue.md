---
description: Resume autonomous work on cw-from-scratch — read handover, find next task, summarise, wait for "go".
---

You are resuming work on the long-lived `cw-from-scratch` branch of
ClojureWasm. Follow this procedure exactly:

1. Read `.dev/handover.md`. If it does not exist, note that and continue.
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9 (the table at the top of §9). If
     none is in-progress, take the first PENDING phase.
   - For that phase, locate the expanded task list (§9.3 for Phase 1, §9.4
     for Phase 2, etc.). If the expanded section is empty / missing, the
     phase has not been opened yet — say so.
   - Find the first unchecked task (`[ ]`).
3. Inspect git: `git log --oneline -10`. Identify any unpaired source
   commits since the last `docs/ja/NNNN-*.md` commit (walk back from
   HEAD; commits whose changes match `src/**/*.zig`, `build.zig`,
   `build.zig.zon`, or `.dev/decisions/NNNN-*.md` count as source).
4. Run `bash test/run_all.sh` to confirm the build is green.
5. Summarise to the user in 5–8 lines:
   - Phase (number + name)
   - Last commit (`git log -1 --format='%h %s'`)
   - Test status (green / red — note any failures)
   - Unpaired source SHAs awaiting a doc (if any) — these must be the
     first thing to address, otherwise Rule 2 of the gate will block
     further doc commits with surprises
   - Next task (number + name + exit criterion)
6. **Wait for the user's "go"** before starting any TDD step. The user
   may want to adjust direction, fix a blocker first, or write the
   pending doc. Do not start coding without explicit confirmation.

Keep the summary terse. The user will read the handover for full context
if they want it.
