# T14.5: control.clj 等価テスト作成

## Goal

Create equivalent tests for control flow constructs based on clojure/test_clojure/control.clj.

## Background

- Original: clojure/test_clojure/control.clj (~450 lines)
- Java dependencies: Exception classes, Long constructor, sorted-map-by, etc.
- Test coverage: do, loop, when, when-not, if-not, when-let, if-let, cond, condp, case, dotimes, while

## Plan

1. Create test/upstream/clojure/test_clojure/control.clj
2. Port tests excluding Java-dependent parts:
   - test-do (pure Clojure)
   - test-loop (pure Clojure)
   - test-when (exclude exception)
   - test-when-not (exclude exception)
   - test-if-not (exclude exception)
   - test-when-let (exclude exception)
   - test-if-let (exclude exception)
   - test-cond (needs Ratio exclusion)
   - test-condp (exclude thrown?, simplify)
   - test-dotimes (pure Clojure)
   - test-while (exclude Exception)
   - test-case (simplify, exclude Java constructs)

## Exclusions

- `(exception)` helper — not defined, use simple expressions
- Ratio literals `2/3` — not supported
- `0M 1M` BigDecimal — not supported
- `thrown?`, `thrown-with-msg?` — may not work
- Java class tests (IllegalArgumentException, Long., etc.)
- `should-print-err-message`, `should-not-reflect` helpers

## Log

2026-02-03: Created control.clj with 12 tests, 66 assertions

- Tests: do, loop, when, when-not, if-not, when-let, if-let, cond, condp, dotimes, while, case
- Excluded due to ClojureWasm limitations:
  - if-let / if-not 2-arg form (requires else clause) → F30
  - cond with empty list () (treated as falsy) → F29
  - case with symbol matching (evaluation error) → F28
  - case with multiple test values (1 2 3) syntax (evaluation error) → F27
- All 12 tests pass on TreeWalk
