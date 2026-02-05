# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22b complete (A, BE, B, C, CX, R, D, 20-23, 22b)
- Coverage: 523/704 clojure.core vars done (0 todo, 180 skip)
- Next task: 22c.12
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
- ~~22c.11: Implement eduction + sort-by/compare fix (transducers)~~
- 22c.12: Implement iteration function (sequences)
- 22c.13: Port test.clj + test_fixtures.clj (use-fixtures impl)
- 22c.14: Port ns_libs.clj
- 22c.15: Port data.clj (implement clojure.data/diff)
- 22c.16: Port protocols.clj (portable subset)

Stop after 22c.16 — Phase 22c complete, loop ends.

## Current Task

22c.12: Implement iteration function (sequences)

## Previous Task

22c.11: Implement eduction + sort-by/compare fix (transducers)
- eduction: eager sequence wrapper (UPSTREAM-DIFF: no deftype, uses sequence)
- sort-by fix: support fn_val/multi_fn/keyword as keyfn (was builtin_fn only)
- compareValues fix: add char comparison support (was missing → silent sort failure)
- Revived test-eduction and test-eduction-completion in transducers.clj
- 16 tests, 100 assertions, both backends pass

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
