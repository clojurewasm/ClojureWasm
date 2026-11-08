---
name: continue
description: Resume fully autonomous work on the `staging` branch and drive the per-task TDD loop. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. `/continue` may also be re-invoked automatically (cron / wake hook); treat every invocation as the same go signal. The full step-by-step loop spec (Step 0 → 7) lives in CLAUDE.md § Autonomous Workflow + § The only stop (single condition: user explicit stop) and is loaded into every turn's system prompt; this skill is the invocation trigger and carries the resume procedure, the Phase-boundary review chain, the subagent delegation cheatsheet, and the model-selection guidance.
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

1. Run `project workflow catchup`. It drains the axioms and the
   live kanban cards. There is no handover file: `.dev/handover.md`
   was retired on 2026-09-11 (memory `20260910235746-74389f7f`), so
   any older text that points at it, or at its "First task on
   resume", is stale.
2. Read `CLAUDE.md` § Project spirit (governs all other rules) and
   the smell sensors it indexes in hive memory (the `bad-smell`
   tag, the premises `20260911004145-29ffd52a`, structural
   imagination `20260911004146-720ff81e`). `.dev/principle.md` no
   longer exists. These are the meta layer the per-task loop is
   checked against.
2a. Read `.dev/project_facts.md` (user-declared invariants —
   F-001 … F-007 at 2026-05-24) and `.dev/structure_plan.md`
   (anticipated directory tree Phase 5-20). When a task touches
   any topic these files cover, treat them as fact above
   ROADMAP / ADR text.
3. Read `.dev/ROADMAP.md` **§9.0** (the gap-area model — the
   phase-queue/§9.<N>-placeholder model is RETIRED per ADR-0142):
   the three gap areas' BUILT status + named gaps + draining
   `D-NNN` rows. Next-unit selection is a concrete live kanban
   card if catchup surfaced one, else the `.dev/debt.yaml`
   `active:` list EASIEST-FIRST (memory `20260910001609-5b3ea4d7`).
4. (Dormant cadence per ADR-0025: skip the
   `docs/ja/learn_clojurewasm/` chapter check. `private/notes/`
   per-task notes continue; they are gitignored and local-only.)
5. `git log --oneline -10` — read the recent commit chain so
   the next task starts with the as-pushed reality, not a
   narration of it.
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

## Boundary review chain (auto-runs when a gap-area unit arc closes)

The phase-queue is RETIRED (ADR-0142); the boundary is now a
major work-arc close (a gap-area unit family drained, a release
cut, or ~a full gate-ceiling cycle of related units). Run this
chain in parallel where possible, **continue into the next
self-selected unit without asking**:

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
     closed phase, pulling from `private/notes/` task-notes (local-only; a fresh clone has none).
3. Synthesise in main: 1 line per check + severity counts.
   No "shall I proceed?" question — proceed.
4. (Bench sweep retired 2026-06-11 — the `bench/quick.sh` /
   `bench/quick_baseline.txt` auto-baseline was removed from the gate,
   so no dangling samples accumulate. Perf is measured on demand via
   `bench/compare_langs.sh` / `bench/run_bench.sh`.)
5. Record the next self-selected unit (debt.yaml easiest-first) on
   the kanban board; there is no handover file to update.
6. Proceed to that unit's Step 0. Auto-compaction handles context
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

## Model selection

Default: **a subagent inherits the parent model**, and the parent is
whatever `.claude/settings.json` pins. Do not override per task.

This section used to name specific models (4.6 for long-context
fan-out, 4.7 for the loop) on the strength of a retrieval-degradation
comparison between two releases. Both had been superseded by the
pinned model before anyone noticed, so the advice was steering
subagents toward models older than the one running the loop — and
nothing here could have caught that, because a model name in prose is
not checked against anything.

A model-specific claim belongs where it can be re-measured, not in the
resume procedure. If a long-context subagent underperforms, measure it
on the models available at that moment and record the finding in
a hive memory entry with its date; do not encode a model name here.
