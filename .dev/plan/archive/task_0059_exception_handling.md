# T7.5: Exception Handling — try/catch/throw + ex-info

## Goal

Verify and document try/catch/throw working end-to-end. Add ex-info/ex-data/ex-message.

## Components

1. **Analyzer**: try/catch/throw already analyzed (analyzeTry, analyzeThrow)
2. **TreeWalk**: runTry/runThrow already implemented with UserException error
3. **core.clj**: Added ex-info, ex-data, ex-message helper functions
4. **Bootstrap**: Added 5 integration tests

## Log

- Investigated try/catch/throw: already fully implemented in analyzer + tree_walk
- CLI syntax: (try body (catch Exception e handler) (finally cleanup))
- Added 4 bootstrap tests: basic exception, no-exception, throw-map, finally
- Added ex-info (returns map with \_\_ex_info marker), ex-data, ex-message to core.clj
- Added ex-info integration test
- All tests green (666 total)
- T7.5 complete
