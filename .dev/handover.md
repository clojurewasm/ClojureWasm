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

- **Phase**: Phase 3 IN-PROGRESS (§9.5). 3.1–3.4 done; chapter
  `0017-error-infrastructure-activation.md` paired at `5f7c2fd`.
  Next active task is **3.5** (heap String type — `runtime/collection/string.zig`).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `5f7c2fd` (0017) covering
  37f0c8f..6777c42 (3.1–3.4 — error infrastructure activation).
- **Unpaired source SHAs awaiting chapter**: (none).
- **Build**: `bash test/run_all.sh` all green —
  `zig build test`, `zone_check --gate`,
  `test/e2e/phase2_exit.sh` (3/3),
  `test/e2e/phase3_cli.sh` (6/6).
- **End-to-end error rendering activated**: `cljw -e '(+ 1 :foo)'`
  now prints `<-e>:1:0: type_error [eval]\n  (+ 1 :foo)\n  ^\n+:
  expected number, got keyword`. Reader / Analyzer / TreeWalk +
  primitives all route through `setErrorFmt`. Single-column caret
  + call-site loc — token-width caret + per-arg loc are deferred
  to Phase 9.

## Active task — §9.5 / 3.5

`src/runtime/collection/string.zig` — heap String type (HeapTag.string).
Analyzer lifts string Form atoms into Value via
`runtime.string.alloc(rt, bytes)`; `printValue` renders quoted.

**Retrievable identifiers**:
- ROADMAP §9.5 task 3.5 (table).
- `src/runtime/value.zig` — `HeapTag.string` should already exist
  (Phase 1.5 reserved); confirm before adding.
- `src/eval/analyzer.zig::formToValue` — currently returns
  `Kind.not_implemented` for `.string`; this is the call site to
  replace once `runtime.string.alloc` exists.
- `src/main.zig::printValue` — currently renders heap kinds as
  `#<tag>`; needs `.string` arm with quoted + escape-sequence output.
- `private/notes/phase3-3.4.md` — TODO carries Phase 9 follow-ups
  (token-width caret, per-arg loc) but those are out of scope for 3.5.

**Exit criterion for 3.5**:
`cljw -e '"hello"'` prints `"hello"` on stdout (with quotes).
`cljw -e '(quote "hi")'` also prints `"hi"`. `printValue` round-trips
escape sequences (`\n`, `\"`).

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
