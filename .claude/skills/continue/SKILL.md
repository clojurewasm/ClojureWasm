---
name: continue
description: Resume fully autonomous work on cw-from-scratch and drive the per-task TDD loop until the user intervenes. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. The full step-by-step loop spec (Step 0 → 7 + the closed 3-condition stop list) lives in CLAUDE.md § Autonomous Workflow and is loaded into every turn's system prompt; this skill is the invocation trigger and carries the resume procedure, the Phase-boundary review chain, the subagent delegation cheatsheet, and the model-selection guidance.
---

# continue

The `/continue` slash command's job is to start running the
autonomous TDD loop. The loop's full step-by-step spec lives in
`CLAUDE.md § Autonomous Workflow` (Step 0 → 7 + the closed
3-condition stop list) which is loaded into every turn's system
prompt.

This file carries the procedural context that is only needed at
invocation time: the resume procedure, the Phase-boundary review
chain, subagent delegation, and model selection. The per-task loop
spec is not duplicated here — CLAUDE.md is the single source.

## Resume procedure (on every session pickup)

1. Read `.dev/handover.md`. (The `SessionStart` hook already prints
   it; re-read to confirm the current state.)
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9. If none, take the first
     PENDING.
   - In that phase's expanded §9.<N> task list, find the first
     `[ ]` task. If §9.<N> is missing/empty, the phase has not
     been opened yet.
3. `git log --oneline -10` — identify any unpaired source commits
   since the last `docs/ja/learn_clojurewasm/NNNN_*.md` commit.
4. `bash test/run_all.sh` — confirm the build is green. **If the
   test output is large (>200 lines), run via subagent and ask
   only for pass/fail + the first failure.**
5. Summarise to the user in 5-10 lines:
   - Phase (number + name)
   - Last commit
   - Test status
   - Unpaired source SHAs (if any) — address first
   - Next task (number + name + exit criterion)
6. **Immediately proceed into the TDD loop per CLAUDE.md
   § Autonomous Workflow.** Do not wait for "go" — `/continue`
   itself is the go signal.

## Phase boundary review chain (auto-runs at phase close)

A Phase closes when the chapter commit's `commits:` list includes
the SHA that flipped the last `[ ]` to `[x]` in §9.<N>. Run this
chain in parallel where possible, **continue into §9.<N+1>
without asking**:

1. Run `audit_scaffolding`. Only block-severity findings stop the
   loop.
2. In parallel (multi-agent fan-out, single message with multiple
   Agent tool calls):
   - **Subagent A**: built-in `simplify` on
     `git diff <phase-start>..HEAD -- src/` — apply
     behaviour-preserving suggestions, queue larger ones.
   - **Subagent B**: built-in `security-review` on unpushed
     commits.
   - **Subagent C**: write any outstanding chapter(s) for the
     closed phase, pulling from `private/notes/` task-notes.
3. Synthesise in main: 1 line per check + severity counts.
   No "shall I proceed?" question — proceed.
4. Open §9.<N+1>: flip the §9 phase tracker; expand §9.<N+1>
   inline (mirror §9.<N>'s structure); update `handover.md` to
   point at §9.<N+1>'s first task.
5. Proceed to Step 0 of §9.<N+1>.1. Auto-compaction handles context
   size transparently — no agent action needed.

## Subagent delegation cheatsheet

| Trigger                                  | Action                                                                                       |
|------------------------------------------|----------------------------------------------------------------------------------------------|
| Survey ≥ 1 reference codebase / OSS     | Step 0 — `general-purpose` subagent (writes the survey note itself; `Explore` is read-only) |
| Test output > 200 lines                  | Step 5 — Bash subagent (run_in_background if long)                                          |
| Search across > 5 files                  | `Explore` subagent (read-only — search only)                                                |
| Phase boundary audit / simplify / review | Multi-agent fan-out (parallel)                                                               |
| Outstanding chapters at phase close      | general-purpose subagent                                                                     |
| Single-file edit, < 200 lines context    | Stay in main                                                                                 |

Default rule: **subagent fork on context isolation, not on
importance**.

## What NOT to invoke during the loop

- `simplify` per source commit — overkill; queue for Phase
  boundary.
- `review` (PR-style) per commit — overkill; reserve for pre-push
  or pre-tag.
- `audit_scaffolding` per task — runs at Phase boundary only (or
  every ~10 chapters).

## Model selection (dual-model)

- **Per-task TDD loop (Step 0 → 7)**: current session's model —
  Opus 4.7 is fine.
- **Phase boundary chain (multi-agent fan-out)**: prefer **Opus 4.6**
  for the long-context audit / simplify / chapter-write subagents —
  Opus 4.7's MRCR v2 retrieval is known to degrade above ~100k
  tokens versus 4.6. Sonnet 4.6 is a viable cost-efficient
  alternative.

When unsure, default to subagent inheriting the parent model; flip
to Opus 4.6 only if a long-context task underperforms.
