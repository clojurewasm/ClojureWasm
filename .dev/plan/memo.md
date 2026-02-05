# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22b complete (A, BE, B, C, CX, R, D, 20-23, 22b)
- Coverage: 523/704 clojure.core vars done (0 todo, 180 skip)
- Next task: 22c.11
- Blockers: none

## Task Queue

Phase 22c — Test Gap Resolution (gap analysis: `.dev/plan/test-gap-analysis.md`)

Tier 1: Revive skipped tests (features already implemented)
- ~~22c.2: done in 22c.1~~
- ~~22c.3: Revive with-redefs tests (vars — non-threaded subset)~~
- ~~22c.4: Revive eval-based tests (special — non-JVM-exception subset)~~

Tier 2: Small implementation + new file ports
- ~~22c.5: Implement find-keyword (F80) + revive keywords.clj test~~
- ~~22c.6: Implement parse-uuid + revive parse.clj test~~
- ~~22c.7: Port edn.clj (clojure.edn thin wrapper)~~
- ~~22c.8: Port try_catch.clj (basic portable subset)~~
- ~~22c.9: Fix ##Inf/##NaN pr-str + float literal precision (printer, math)~~
- ~~22c.10: Implement with-var-roots + heap-allocate VM + revive multimethods tests~~

Tier 3: Medium implementation + new file ports
- 22c.11: Implement eduction + IReduceInit (transducers)
- 22c.12: Implement iteration function (sequences)
- 22c.13: Port test.clj + test_fixtures.clj (use-fixtures impl)
- 22c.14: Port ns_libs.clj
- 22c.15: Port data.clj (implement clojure.data/diff)
- 22c.16: Port protocols.clj (portable subset)

Stop after 22c.16 — Phase 22c complete, loop ends.

## Current Task

22c.11: Implement eduction + IReduceInit (transducers)

## Previous Task

22c.10: Implement with-var-roots + heap-allocate VM + revive multimethods tests
- with-var-roots: inline in multimethods.clj (set-var-roots, with-var-roots*, with-var-roots macro)
- Fixed #'ns/name var resolution (analyzer: direct namespace lookup via env.findNamespace)
- Fixed VM C stack overflow: heap-allocate VM struct (~1.5MB) in evalStringVM, bytecodeCallBridge
- 9 tests, 123 assertions, both backends pass

## Handover Notes

- **Gap analysis**: `.dev/plan/test-gap-analysis.md` (full inventory of skips + unported files)
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
