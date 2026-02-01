# Task 0007: Create Reader (includes former Task 1.8 edge cases)

## Context

- Phase: 1b (Reader)
- Depends on: task_0006 (Form type)
- References: Beta src/reader/reader.zig (1134L), future.md SS1
- Note: Former Task 1.8 (Reader edge cases) merged into this task

## Plan

1. Create src/common/reader/reader.zig
2. Full reader with read-time macro expansion
3. All edge cases: string escapes, regex, numeric literals, reader conditionals, fn literals, syntax-quote
4. Error module for reader errors

## Log

### 2026-02-01

- Preparation: removed reader-macro variants from FormData, finalized error module
- Commit: 9a0b5f6 "Prepare for Reader: remove reader-macro variants from FormData, finalize error module"
- Created full Reader with read-time macro expansion
- All edge cases covered in single implementation pass:
  - String escapes, regex, numeric literals
  - Reader conditionals, fn literals, syntax-quote
- Former Task 1.8 merged — no separate implementation needed
- Commit: 6dc9bd2 "Add Reader with full read-time macro expansion"
- Plan update: Commit 0538033 "Mark Tasks 1.7 and 1.8 done, update next task to 1.9 (Node/Analyzer)"

## Status: done
