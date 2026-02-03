# T14.4: for.clj 等価テスト作成

## Goal

Create equivalent tests for the Clojure `for` macro based on clojure/test_clojure/for.clj.

## Background

- Original: clojure/test_clojure/for.clj (~130 lines)
- Java dependencies: Integer., Math/abs — will be excluded
- Test coverage: :when, :while, :let, nesting, destructuring

## Plan

1. Create test/upstream/clojure/test_clojure/for.clj
2. Port tests excluding Java-dependent parts:
   - Docstring-Example (uses large range — ok)
   - When tests (pure Clojure)
   - While tests (need to exclude Exception throw)
   - While-and-When tests (exclude Math/abs test)
   - Nesting (pure Clojure)
   - Destructuring (exclude Integer.)
   - Let tests (pure Clojure)
   - Chunked-While (pure Clojure)

3. Run tests with clojure.test

## Exclusions

- `(Integer. ...)` — Java constructor
- `Math/abs` — Java static method
- `(throw (Exception. ...))` — Java Exception class (can use throw directly)

## Log

1. Created test/upstream/clojure/test_clojure/for.clj
   - Ported tests from clojure/test_clojure/for.clj

2. Test results:
   - 4 tests, 12 assertions pass
   - :when tests: 5 assertions
   - Nesting tests: 2 assertions
   - :let tests: 2 assertions (simple only)
   - Basic for tests: 3 assertions

3. Excluded tests (for macro limitations):
   - :while tests — not implemented (F25)
   - :let + :when combination — fails (F26)
   - Java-dependent tests (Integer., Math/abs)

4. Added to checklist.md:
   - F25: for macro :while modifier
   - F26: for macro :let + :when combination
