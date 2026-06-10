---
name: continue
description: Resume fully autonomous work on cw-from-scratch and drive the per-task TDD loop. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. `/continue` may also be re-invoked automatically (cron / wake hook); treat every invocation as the same go signal. The full step-by-step loop spec (Step 0 → 7) lives in CLAUDE.md § Autonomous Workflow + § The only stop (single condition: user explicit stop) and is loaded into every turn's system prompt; this skill is the invocation trigger and carries the resume procedure, the Phase-boundary review chain, the subagent delegation cheatsheet, and the model-selection guidance.
---

# continue

The `/continue` slash command's job is to start running the
autonomous TDD loop. The loop's full step-by-step spec lives in
`CLAUDE.md § Autonomous Workflow` (Step 0 → 7) + `§ The only stop`
(single condition: user explicit stop), loaded into every turn's
system prompt.

The loop never stops itself. Region / cluster / task / commit /
Phase boundaries all roll into the next unit of work. Bad-Smell
triggers are interrupts (see CLAUDE.md § Smell triggers are
interrupts, not stops) — the surgery lands at the right depth,
then the loop continues. Test failures are diagnosed and fixed
in-flight, not handed off. `/continue` may also be re-invoked
automatically (cron / wake hook); each invocation is the same go
signal.

This file carries the procedural context that is only needed at
invocation time: the resume procedure, the Phase-boundary review
chain, subagent delegation, and model selection. The per-task loop
spec is not duplicated here — CLAUDE.md is the single source.

## Resume procedure (on every session pickup)

1. Read `.dev/handover.md` (SessionStart hook already prints it;
   re-read). Pay attention to any "Guardrail refresh" section —
   it points at recent principle.md / CLAUDE.md spirit edits the
   loop must honour.
2. Read `CLAUDE.md` § Project spirit (top section, governs all
   other rules) and `.dev/principle.md` (Bad Smell catalogue +
   Structural imagination phase). These two are the meta layer
   the per-task loop is checked against.
2a. Read `.dev/project_facts.md` (user-declared invariants —
   F-001 … F-007 at 2026-05-24) and `.dev/structure_plan.md`
   (anticipated directory tree Phase 5-20). When a task touches
   any topic these files cover, treat them as fact above
   ROADMAP / ADR text.
3. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9. If none, take the first
     PENDING.
   - In that phase's expanded §9.<N> task list, find the first
     `[ ]` task. If §9.<N> is missing/empty, the phase has not
     been opened yet — load the §9.<N> placeholder including
     its **Entry ADRs / Entry debts / Reference / Skeletons /
     Deliverables / Final activation step** lines. The Entry
     debts list points at `.dev/debt.yaml` rows the Phase owner
     must resolve.
4. (Dormant cadence per ADR-0025: skip the
   `docs/ja/learn_clojurewasm/` chapter check. `private/notes/`
   per-task notes continue.)
5. `git log --oneline -10` — read the recent commit chain so
   the next task starts with the as-pushed reality, not the
   handover's narration of it.
6. Confirm HEAD is green **without re-running the full gate** — the
   pushed HEAD was already gated when it landed. Check the
   `.dev/.gate_pass` / `.dev/.smoke_pass` fingerprint (or run a quick
   `bash test/run_all.sh --smoke`); only run the full gate at resume if
   the fingerprint is stale or the tree is dirty (ADR-0107 — full e2e is
   heavy, so resume does not pay for it by default). **If a check's
   output is large (>200 lines), run via subagent and ask only for
   pass/fail + the first failure.**
7. Summarise to the user in 5-10 lines:
   - Phase (number + name)
   - Last commit
   - Test status
   - Active task (number + name + exit criterion)
   - Any **Entry debts** owed at this Phase (D-NNN list) so the
     loop's Step 1 picks them up before touching structure
8. **Immediately proceed into the TDD loop per CLAUDE.md
   § Autonomous Workflow.** Do not wait for "go" — `/continue`
   itself is the go signal.

## Phase boundary review chain (auto-runs at phase close)

A Phase closes when the chapter commit's `commits:` list includes
the SHA that flipped the last `[ ]` to `[x]` in §9.<N>. Run this
chain in parallel where possible, **continue into §9.<N+1>
without asking**:

1. Run `audit_scaffolding`. Findings of any severity feed the
   loop's next interrupt (block-severity ones become an immediate
   surgery before the next Phase opens); the loop never halts on
   them.
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
4. **Bench sweep**: if `bench/quick_baseline.txt` carries
   uncommitted samples that doc-only / chore commits left dangling
   (per CLAUDE.md Step 6 bench policy), commit them now as a
   single `bench: accumulated samples through Phase <N>` commit
   so the next Phase opens with a clean working tree.
5. Open §9.<N+1>: flip the §9 phase tracker; expand §9.<N+1>
   inline (mirror §9.<N>'s structure); update `handover.md` to
   point at §9.<N+1>'s first task.
6. Proceed to Step 0 of §9.<N+1>.1. Auto-compaction handles context
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
