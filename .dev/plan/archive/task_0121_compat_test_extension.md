# T14.11: compat_test.yaml Extension

## Goal

Extend `.dev/status/compat_test.yaml` to track the Clojure upstream equivalent tests
created during Phase 14 (test/upstream/clojure/test_clojure/\*).

## Context

- Phase 14 created 7 equivalent test files based on Clojure JVM test suite
- Currently `compat_test.yaml` only tracks SCI tests (72 tests, 267 assertions)
- Need to add a new section for Clojure upstream tests

## Test Files to Track

| File                | Tests | Assertions | Excluded Features            |
| ------------------- | ----- | ---------- | ---------------------------- |
| for.clj             | 4     | 12         | F25/F26 (:while, :let+:when) |
| control.clj         | 12    | ~53        | F27/F28/F29/F30              |
| logic.clj           | 6     | ~55        | F31/F32                      |
| predicates.clj      | 18    | ~82        | F33-F37                      |
| atoms.clj           | 14    | ~39        | F38/F39                      |
| sequences.clj       | 33    | ~188       | F40-F51                      |
| data_structures.clj | 17    | ~60        | F58                          |

## Plan

1. Run each test file to count exact tests/assertions
2. Add `clojure_test_clojure:` section to compat_test.yaml
3. Document excluded features with F## references
4. Verify all tests pass

## Log

- Ran all 7 test files to get exact counts:
  - for.clj: 4 tests, 12 assertions
  - control.clj: 12 tests, 66 assertions
  - logic.clj: 6 tests, 80 assertions
  - predicates.clj: 20 tests, 143 assertions
  - atoms.clj: 14 tests, 39 assertions
  - sequences.clj: 33 tests, 188 assertions
  - data_structures.clj: 17 tests, 203 assertions
- Total: 106 tests, 731 assertions
- Added `clojure_test_clojure:` section to compat_test.yaml
- Documented all excluded features with F## references
- Updated overall summary (178 tests, 998 assertions total)
- All tests pass
