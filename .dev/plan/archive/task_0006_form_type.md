# Task 0006: Create Form type

## Context
- Phase: 1b (Reader)
- Depends on: task_0005 (Tokenizer)
- References: Beta src/reader/form.zig (264L)

## Plan
1. Create src/common/reader/form.zig
2. Form = tagged union wrapping Value + source location info
3. FormData variants for all Clojure syntactic constructs
4. formatPrStr for Clojure print representation

## Log

### 2026-02-01
- Created Form type in src/common/reader/form.zig
- Form = tagged union wrapping Value + source location info
- FormData with variants for all Clojure syntactic constructs
- Added formatPrStr with std.Io.Writer (Zig 0.15 pattern)
- Commit: 2e6419d "Implement Form type for Reader output (Task 1.6)"
- Subsequent refactor: migrated to std.Io.Writer pattern
- Commit: 8fb3e37 "Refactor Form.formatPrStr to use std.Io.Writer instead of anytype"

## Status: done
