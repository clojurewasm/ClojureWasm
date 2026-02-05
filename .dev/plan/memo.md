# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22b complete (A, BE, B, C, CX, R, D, 20-23, 22b)
- Coverage: 521/704 clojure.core vars done (0 todo, 182 skip)
- Phase 22b complete. Next: Phase 24 (Optimization)
- Blockers: none

## Task Queue

Phase 24 (Optimization) — not yet planned.
See roadmap.md Phase 24 and Phase Notes for scope.

Deferred from 22b (blocked on protocol/fixture support):
- 22b.4 (test.clj) — needs test-ns-hook/custom report
- 22b.5 (test_fixtures.clj) — needs use-fixtures
- 22b.6 (try_catch.clj) — entirely JVM-specific
- 22b.8 (protocols.clj) — defprotocol VM-only, most tests JVM interop
- 22b.11 (data.clj) — needs clojure.data which requires defprotocol

## Current Task

Plan Phase 24 (Optimization)

## Previous Task

22b.10: Port math.clj (327 lines, 41 tests — implemented clojure.math ns)
- Created src/common/builtin/math.zig: 42 functions + 2 constants (PI, E)
- 41 tests ported (256 assertions), both backends pass

## Handover Notes

- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
