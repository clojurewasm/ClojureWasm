# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.

## Current state

- **Phase**: Phase 1 DONE; Phase 2 next (§9.4 to be expanded).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired commit**: `docs(ja): 0007 — phase-1-runtime-foundations`
  (covers Phase-1 source commits 8b487f9..04476ac).
- **Build**: 94 tests passing (`zig build test`); `zone_check --gate` green;
  x86_64 gate (1.12) verified on `my-ubuntu-amd64` via OrbStack.
- **Phase-1 exit criterion**: `cljw -e "(+ 1 2)"` → `(+ 1 2)` ✓.

## Unpaired source commits awaiting a doc

(none — 0007 closes Phase 1)

## Next task

Open Phase 2 (`TreeWalk + Analyzer + Bootstrap Stage 0`). First step:
expand §9.4 inline in `.dev/ROADMAP.md` mirroring the §9.3 structure
(task table with one row per `[ ]` step), then resume the per-task TDD
loop on §9.4.1.

Phase-2 exit criterion (from §9 phase tracker):
  `(let [x 1] (+ x 2))` → 3 and `((fn* [x] (+ x 1)) 41)` → 42.

## Open questions / blockers

(none)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles "続けて"
  / "/continue" / "resume". It auto-triggers on those phrases.
- Skill `code-learning-doc` defines the doc-commit pairing; the gate
  `scripts/check_learning_doc.sh` enforces it.
- Skill `audit-scaffolding` runs at every Phase boundary or every ~10
  ja docs to catch staleness / bloat / drift.
- After 1.1 lands as a source commit, **do not write the doc immediately**
  — keep going with 1.2, 1.3, … as small commits, then one
  `docs/ja/00NN-phase-1-runtime-foundations.md` (next available index)
  covering all of Phase 1 Layer-0 work when it makes a coherent story.
