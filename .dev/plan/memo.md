# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: B (Fix Known Issues)
- Next task: B0 (test.clj enhancement)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description                  | Notes                              |
|------|------------------------------|------------------------------------|
| B0   | test.clj enhancement         | is pattern dispatch, thrown?        |
| B1   | Core Semantics fixes         | F29/F33, F34, F30, F31, F32        |
| B2   | Macro Enhancement            | F27/F28, F93, F92, F25/F26         |
| B3   | Seq/String Operations        | F41, F45, F48, F49                 |
| B4   | defn/ns Enhancement          | F90, F85                           |

## Current Task

Write task design here at iteration start.
On next task, move this content to Previous Task below.

## Previous Task

Phase 18.7 completed. 405/712 vars done. Transitioned to Foundation Reset.

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D)
- Phase A: Audit all 405 done vars against upstream, annotate notes
- Phase B: Fix F## items (test.clj, core semantics, macros, seq/string)
- Phase C: Faithful upstream test porting with CLJW markers
- Phase D: Parallel expansion (new vars + test porting)
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
