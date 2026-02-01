# Task 0002: Implement Value.format (print representation)

## Context
- Phase: 1a (Value type foundation)
- Depends on: task_0001 (Value tagged union)
- References: Beta src/runtime/value.zig, Clojure pr-str semantics

## Plan
1. Add Value.format() using Zig 0.15 `{f}` format spec
2. Clojure pr-str semantics for all current variants
3. Special char names (\newline, \space, \tab, \return)
4. Float decimal guarantee (0.0 not 0)
5. Test helper: expectFormat

## Log

### 2026-02-01
- Added Value.format() using Zig 0.15 `{f}` format spec (1-arg signature)
- Clojure pr-str semantics for all current variants:
  - nil -> "nil", boolean -> "true"/"false"
  - integer -> decimal, float -> decimal with guaranteed decimal point (0.0 not 0)
  - char -> special names (\newline, \space, \tab, \return) + UTF-8 for others
  - string -> quoted with double quotes
  - symbol -> ns/name or name, keyword -> :ns/name or :name
- Test helper `expectFormat` for concise format assertions
- 9 new format tests (20 total). All passing via TDD
- Commit: 2a236ae "Implement Value.format with Clojure pr-str semantics (Task 1.2)"

## Status: done
