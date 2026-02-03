# T14.12: Test File Priority List

## Goal

Create a prioritized list of remaining Clojure JVM test files (test/clojure/test_clojure/)
for porting equivalent tests to ClojureWasm.

## Context

- Clojure JVM test suite: 68 files
- Already ported: 7 files (for, control, logic, predicates, atoms, sequences, data_structures)
- Remaining: 61 files

## Categorization Criteria

1. **Java dependency**: How much Java interop code?
2. **Feature coverage**: Does ClojureWasm support the features?
3. **Priority**: High (core functionality), Medium (useful), Low (JVM-specific)

## Plan

1. Review each remaining file's header/imports
2. Categorize by Java dependency level
3. Assign priority based on ClojureWasm feature support
4. Output to .dev/notes/test_file_priority.md

## Log

- Reviewed all 68 test files in Clojure JVM test suite
- Categorized by Java dependency level:
  - High Priority (low Java dep): 12 files
  - Medium Priority (moderate Java): 13 files
  - Low Priority (high Java): 27 files
  - Skip (JVM infrastructure): 9 files
- Created .dev/notes/test_file_priority.md with:
  - Priority tables by category
  - Recommended porting order (3 batches)
  - Feature dependencies
  - Notes for porting
