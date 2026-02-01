# Task 0003: Implement Value.eql (equality)

## Context

- Phase: 1a (Value type foundation)
- Depends on: task_0002 (Value.format)
- References: Clojure = semantics, cross-type numeric equality

## Plan

1. Add Value.eql() with Clojure = semantics
2. Same-type structural comparison for all variants
3. Cross-type numeric equality: (= 1 1.0) => true via f64 conversion
4. Symbol/Keyword: compare both name and ns
5. Collection equality deferred to Task 1.4

## Log

### 2026-02-01

- Added Value.eql() with Clojure = semantics:
  - Same-type structural comparison for all variants
  - Cross-type numeric equality: (= 1 1.0) => true via f64 conversion
  - Symbol/Keyword: compare both name and ns (namespace)
  - String: byte-level comparison via std.mem.eql
  - Different types => false (except int/float cross-comparison)
- Helper: eqlOptionalStr for ?[]const u8 comparison
- 11 new eql tests (31 total). All passing via TDD
- Collection equality deferred to Task 1.4
- Commit: a068687 "Implement Value.eql with Clojure = semantics (Task 1.3)"

## Status: done
