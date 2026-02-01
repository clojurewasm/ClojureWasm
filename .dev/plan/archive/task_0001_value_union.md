# Task 0001: Define Value tagged union

## Context
- Phase: 1a (Value type foundation)
- Depends on: Phase 0 (project bootstrap)
- References: Beta src/runtime/value.zig, future.md SS1

## Plan
1. Create src/common/value.zig with Value tagged union
2. Minimal variants: nil, bool, int, float, char, string, symbol, keyword
3. Helper types: Symbol (ns + name), Keyword (ns + name)
4. Helper methods: isNil(), isTruthy() (Clojure semantics)
5. Collections deferred to Task 1.4

## Log

### 2026-02-01
- Created src/common/value.zig with Value tagged union
- Variants: nil, boolean, integer, float, char, string, symbol, keyword
- Collections deferred to Task 1.4
- Helper types: Symbol (ns + name), Keyword (ns + name)
- Helper methods: isNil(), isTruthy() (Clojure semantics: nil and false are falsy)
- 11 tests covering creation of all variants, namespaced symbols/keywords, and truthiness semantics
- All passing via TDD (Red -> Green -> Refactor)
- Commit: f049620 "Define Value tagged union with minimal variants (Task 1.1)"

## Status: done
