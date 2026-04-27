# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> The `progress.txt` shape is intentional: future-Claude reads this in
> a fresh context window and must understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `.dev/ROADMAP.md` — find the IN-PROGRESS phase in §9, then its
   expanded `§9.<N>` task list; pick up the first `[ ]` task.
3. The chapter file most recently added under `docs/ja/` — to recover
   the conceptual baseline for the active phase.

## Current state

- **Phase**: Phase 2 DONE. Phase 3 task list (§9.5) is expanded but
  3.1 is the next active task.
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: educational materials were rewritten
  from scratch on 2026-04-27; see `docs/ja/` for the new textbook.
  Phase 2 source commits 91feef0..7d9fe5f are covered by the new
  chapters.
- **Build**: 176 tests passing (`zig build test`); `zone_check --gate`
  green; `test/e2e/phase2_exit.sh` green (3/3 CLI cases).
- **Phase-2 exit criterion**: `cljw -e "(let* [x 1] (+ x 2))"` → `3`
  and `cljw -e "((fn* [x] (+ x 1)) 41)"` → `42` ✓.

## Active task — §9.5 / 3.1

`src/runtime/error_print.zig` + `src/main.zig` overhaul.

**Retrievable identifiers**:
- ROADMAP §9.5 task 3.1 (the table at the bottom of §9.5).
- `.claude/rules/cljw-invocation.md` — why `-e` is fragile under zsh.
- `src/runtime/error.zig` (Phase 1.2 — `SourceLocation`,
  threadlocal `last_error`, `setErrorFmt` infrastructure already in place).
- `src/main.zig` — current catch sites print `@errorName(err)`; replace
  with `formatErrorWithContext`.

**Two motivations land together**:

1. **Activate principle P6 (Error quality is non-negotiable)**.
   Phase 1.2 put SourceLocation / threadlocal `last_error` /
   `setErrorFmt` infrastructure in place, but Reader / Analyzer /
   TreeWalk error sites still discard the location and `main.zig`
   just prints `@errorName(err)`. 3.1 builds the rendering side
   (`error_print.zig`) and switches `main.zig`'s catch sites to it;
   3.2–3.4 then re-route the error producers through `setErrorFmt`.
2. **Safer cljw invocation**. `-e "..."` collides with zsh history
   expansion (`!`), `$` substitution, backticks. Add `cljw <file.clj>`
   and `cljw -` (stdin / heredoc) as first-class entry points.
   `-e` stays as a quick path.

**Exit criterion for 3.1**:
- A bad expression like `cljw -e "(+ 1 :foo)"` prints
  `<-e>:1:4: type_error [eval]\n  (+ 1 :foo)\n      ^^^^\n
  +: expected number, got keyword` to stderr.
- `cljw script.clj` reads the file and runs RAEP over each top-level
  form.
- `cljw -` reads stdin (heredoc-friendly).

## Open questions / blockers

(none)

## Strategic notes in `private/` to consider for future phases

The `/continue` resume procedure surfaces these; not all need action
right now, but they should not be lost. Each is one line — read the
file for detail.

- `private/2026-04-27_strategic_review/01_design_insights.md` — v1
  retrospective + Clojure semantics + Wasm/Edge 2026 + Zig 0.16.
- `private/2026-04-27_strategic_review/02_plan_review.md` — five
  strategic gaps (G1: concurrency design doc; G2: Wasm strategy
  decision; G3: decisions.md D1-D20 retroactive entries; G4: Phase 4-7
  bench harness; G5: fused-reduce design doc).
- `private/2026-04-27_strategic_review/03_ecosystem_and_architecture.md`
  — Tier system, InterOp deep module (3-entry interface; case 1+3
  hybrid), Wasm Component pod escape hatch.
- `private/2026-04-27_strategic_review/04_phase2_audit_and_meta_review.md`
  — meta review: educational-doc taste, autonomous-loop best practices,
  the backlog B1–B12 that produced the 2026-04-27 framework rewrite.

Adoption decisions for any of these = ADR-level → escalate to user
before proceeding.

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles
  "続けて" / "/continue" / "resume". It auto-triggers on those phrases
  and now drives a Step 0 (Survey) → Step 7 (per-task note) →
  Step 8 (60% compact gate) loop with multi-agent fan-out at phase
  boundaries.
- Skill `code-learning-doc` is **two-cadence**: per-task notes
  (private, gitignored) and per-concept chapters (`docs/ja/NNNN-*.md`,
  gated). Use `TEMPLATE_TASK_NOTE.md` and `TEMPLATE_PHASE_DOC.md`. Do
  **not** revert to the old "diary per phase" shape.
- Skill `audit-scaffolding` runs at every Phase boundary or every ~10
  chapters. Section F now checks unadopted strategic notes in
  `private/`.
- Rule `.claude/rules/textbook-survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the four anti-pull
  guardrails.
- The 🔒 marker on Phase 4 means a fresh OrbStack x86_64 gate is due
  at the Phase-3 → Phase-4 boundary (re-run the same `orb run -m
  my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` invocation).
