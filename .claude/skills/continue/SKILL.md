---
name: continue
description: Resume autonomous work on cw-from-scratch and drive the per-task TDD loop without stopping unnecessarily. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, summarises, and (after the user's go) executes the TDD loop autonomously through to the doc commit. Auto-runs the Phase-boundary review chain when a Phase closes.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop autonomously to its natural stop**, which is the next user
checkpoint (Phase boundary, blocker, or completion).

## When to stop, when to keep going

The point of this skill is to minimise unnecessary stops. **Keep
going** when:

- The next step is mechanical (next TDD task in §9.<N>, doc commit,
  handover update).
- A test fails and the fix is local + obvious.
- A pre-approved tool prompts (the permissions allowlist + `defaultMode:
  acceptEdits` should keep these to a minimum).

**Stop and ask the user** when:

- The user has not yet said "go" after the initial summary.
- A Phase closes (run the review chain first; report findings; ask
  before opening the next Phase).
- A test failure root cause is unclear or requires architectural choice.
- A `git push` is needed (always).
- The audit-scaffolding skill produces a `block` finding.
- The user is named in a question that genuinely needs their input.

## Resume procedure (run on every session pickup)

1. Read `.dev/handover.md`. (The `SessionStart` hook in
   `.claude/settings.json` already prints it; if absent, read manually.)
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9. If none, take the first PENDING.
   - In that phase's expanded §9.<N> task list, find the first `[ ]`
     task. If §9.<N> is missing/empty, the phase has not been opened yet.
3. `git log --oneline -10` — identify any unpaired source commits since
   the last `docs/ja/NNNN-*.md` commit.
4. `bash test/run_all.sh` — confirm the build is green.
5. Summarise to the user in 5–8 lines:
   - Phase (number + name)
   - Last commit (`git log -1 --format='%h %s'`)
   - Test status
   - Unpaired source SHAs (if any) — must be addressed first
   - Next task (number + name + exit criterion)
6. **Wait for the user's "go"** before any TDD step.

## Per-task TDD loop (after "go", autonomous through doc commit)

For each `[ ]` task in §9.<N>:

1. **Plan** the smallest red test (1 sentence in chat, no permission needed).
2. **Red**: write the failing test (Edit / Write — auto-accepted).
3. **Green**: minimal code to pass.
4. **Refactor** while green.
5. `bash test/run_all.sh` must be green.
6. **Source commit**: `git add` only the source files; `git commit -m
   "<type>(<scope>): <one line>"`. The pre-commit gate runs.
7. Repeat 1–6 for the next task in §9.<N>. Multiple source commits in a
   row are fine — the gate does not block.
8. **Doc commit**: when the unit of work is told-able (typically every
   3–7 source commits, or at the end of a Phase), copy
   `.claude/skills/code-learning-doc/TEMPLATE.md` to
   `docs/ja/NNNN-<slug>.md`, fill it in, commit it alone.
9. **Update handover**: 1–2 lines (next task + blocker).
10. **Mark progress in §9.<N>**: flip `[ ]` → `[x]` for completed
    task(s), append the SHA in the Status column.

Throughout this loop, do not pause to ask the user unless one of the
"stop and ask" conditions above is met.

## Phase boundary review chain (auto-runs when a Phase closes)

A Phase closes when the doc commit's `commits:` list includes the SHA
that flipped the last `[ ]` to `[x]` in §9.<N>. **Do not open §9.<N+1>
immediately.** Run this chain (auto, no user prompt needed):

1. **`audit-scaffolding` skill** — staleness / bloat / drift across
   CLAUDE.md, .dev/, .claude/, docs/, scripts/. Block-severity findings
   pause the chain.
2. **Built-in `simplify` skill** on the Phase's combined diff
   (`git diff <phase-start>..HEAD -- src/`). Apply suggestions that
   don't change behaviour; queue larger ones for the next Phase.
3. **Built-in `security-review` skill** on unpushed commits.
4. **Report findings** to the user with severity counts. If all clean,
   suggest opening §9.<N+1>. If block-severity, list them and stop.
5. **Open §9.<N+1>**: flip the §9 phase tracker; expand §9.<N+1>
   inline (mirror §9.<N>'s structure); update handover.md to point at
   §9.<N+1>'s first task.

## What NOT to invoke during the loop

- `simplify` per source commit — overkill; queue for Phase boundary.
- `review` (PR-style) per commit — overkill; reserve for pre-push or
  pre-tag.
- `audit-scaffolding` per task — runs at Phase boundary only (or
  every ~10 ja docs).
