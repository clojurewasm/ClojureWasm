---
name: continue
description: Resume fully autonomous work on cw-from-scratch and drive the per-task TDD loop until the user intervenes. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, then immediately enters the TDD loop with no "go" gate, no Phase-boundary stop, and no per-task confirmation. Auto-runs the Phase-boundary review chain inline and continues into the next Phase without prompting.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop fully autonomously**. The user invoked `/continue` precisely so
they would not have to babysit every checkpoint — only stop when
something *requires* the user (push approval, ambiguous bug, hard
block).

## When to stop, when to keep going

Default = keep going. **Keep going** when:

- The next step is mechanical (next TDD task in §9.<N>, doc commit,
  handover update, opening the next Phase).
- A test fails and the fix is local + obvious.
- A pre-approved tool prompts (the permissions allowlist + `defaultMode:
  acceptEdits` should keep these to a minimum).
- A Phase closes — run the review chain inline, report findings briefly,
  then immediately open §9.<N+1> and continue. **Do not ask permission
  to start the next Phase.**
- The initial summary was just produced — **do not wait for "go"**;
  proceed directly into the TDD loop.

**Stop and ask the user** only when:

- A `git push` is needed (always — out of scope for autonomous mode).
- A test failure root cause is unclear or requires an architectural
  choice (i.e., not a one-line obvious fix).
- The audit-scaffolding skill produces a `block` finding.
- An ADR-level decision (tier change, principle deviation, scope cut)
  is needed.
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
6. **Immediately proceed into the TDD loop.** Do not wait for "go" —
   `/continue` itself is the go signal. The summary is informational,
   not a checkpoint.

## Per-task TDD loop (autonomous from invocation through doc commit)

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

## Phase boundary review chain (auto-runs inline when a Phase closes)

A Phase closes when the doc commit's `commits:` list includes the SHA
that flipped the last `[ ]` to `[x]` in §9.<N>. Run this chain inline
and **continue into §9.<N+1> without asking**:

1. **`audit-scaffolding` skill** — staleness / bloat / drift across
   CLAUDE.md, .dev/, .claude/, docs/, scripts/. Only **block-severity**
   findings stop the loop; warn-severity findings are reported and the
   loop continues.
2. **Built-in `simplify` skill** on the Phase's combined diff
   (`git diff <phase-start>..HEAD -- src/`). Apply suggestions that
   don't change behaviour; queue larger ones for the next Phase.
3. **Built-in `security-review` skill** on unpushed commits.
4. **Report findings briefly** (one line per check + severity counts).
   No "shall I proceed?" question — proceed.
5. **Open §9.<N+1> immediately**: flip the §9 phase tracker; expand
   §9.<N+1> inline (mirror §9.<N>'s structure); update handover.md to
   point at §9.<N+1>'s first task; resume the per-task TDD loop on
   §9.<N+1>.1.

## What NOT to invoke during the loop

- `simplify` per source commit — overkill; queue for Phase boundary.
- `review` (PR-style) per commit — overkill; reserve for pre-push or
  pre-tag.
- `audit-scaffolding` per task — runs at Phase boundary only (or
  every ~10 ja docs).
