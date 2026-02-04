# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: A (Audit & Document)
- Next task: Batch A1 (Special Forms audit)
- Coverage: 405/712 clojure.core vars done (269 without notes)
- Blockers: none

## Task Queue

| Task | Description                  | Notes                              |
|------|------------------------------|------------------------------------|
| A1   | Special Forms audit          | 16 vars, analyzer.zig handlers     |
| A2   | Arithmetic & Comparison      | 20 vars, arithmetic/numeric.zig    |
| A3   | Collection Operations        | 80 vars, sequences/collections.zig |
| A4   | String Operations            | 15 vars, strings/clj_string.zig    |
| A5   | Predicates                   | 30 vars, predicates.zig            |
| A6   | Macros (core.clj)            | 17 vars, core.clj vs upstream      |
| A7   | HOF & Lazy Sequences         | 40 vars, core.clj + sequences.zig  |
| A8   | State & Concurrency          | 10 vars, atom.zig + volatile       |
| A9   | Remaining                    | 50 vars, various builtins          |

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
