# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 18 (Test Batch 3 + Coverage Expansion)
- Current task: T18.4
- Task file: N/A
- Last completed: T18.3 (Port numbers.clj — 31 tests, 340 assertions)
- Blockers: none
- Next: Core function expansion → coverage expansion

## Current Phase: 18

**Background**: Phase 17.5 completed infrastructure fixes (8 tasks, D59/D60).
Total: 14 test files, 311 done vars (19 clojure.string), 189 Zig builtins.
Phase 17.5 un-SKIPped 7 tests, resolved F13/F58/F67/F69/F79.
T18.1 added 5 bit ops. T18.3 ported numbers.clj (31 tests, 340 assertions).
Fixes: ArithmeticError added to VM/TreeWalk error sets, == multi-arity, NaN div.

**Goal**: Port numbers.clj tests, implement missing bit/numeric functions,
expand test coverage for existing files.

### Rules

1. **TDD**: Failing test first, then implement
2. **Dual-Backend**: All tests pass both VM and TreeWalk
3. **Batch 3 pragmatism**: Only portable tests (no Java deps)
4. **vars.yaml**: Mark implemented vars done

### Task Queue

| Task  | Type | Description                             | Notes                                        |
| ----- | ---- | --------------------------------------- | -------------------------------------------- |
| T18.1 | done | Missing bit ops (bit-set, -clear, etc.) | 5 builtins: set/clear/flip/test/ushiftr      |
| T18.2 | impl | Numeric conversions (int, long, etc.)   | int, long, float, double, num, char          |
| T18.3 | done | Port numbers.clj (31 tests)             | ArithmeticError fix, == multi-arity, NaN div |
| T18.4 | impl | Core function expansion                 | Quick-win todo vars from vars.yaml           |
| T18.5 | test | Coverage expansion in existing tests    | Expand assertions in current 14 files        |

### Phase 17 Summary (completed)

| Task  | Status | Description                              |
| ----- | ------ | ---------------------------------------- |
| T17.1 | done   | print, pr, newline, flush                |
| T17.2 | done   | print-str, prn-str, println-str          |
| T17.3 | done   | slurp, spit                              |
| T17.4 | done   | read-line                                |
| T17.5 | skip   | printer.clj (needs binding F85)          |
| T17.6 | done   | **nano-time, **current-time-millis, etc. |

---

## Permanent Reference

Policies that persist across phases. Do not delete.

### Implementation Policy

1. **Implement in Zig or .clj** — do not skip features that appear "JVM-specific"
2. **Keep .clj files unchanged from upstream** — if modification needed, add `UPSTREAM-DIFF:` comment
3. **Check `.dev/notes/java_interop_todo.md`** before skipping anything Java-like
   - Many Java patterns (`System/`, `Math/`) have Zig equivalents listed there
   - SKIP only if not listed AND truly impossible

### Reference Files

| File                               | Content                     |
| ---------------------------------- | --------------------------- |
| `.dev/notes/test_file_priority.md` | Test file priority list     |
| `.dev/notes/java_interop_todo.md`  | Java interop implementation |
| `.dev/status/vars.yaml`            | Var implementation status   |
| `.dev/checklist.md`                | F## deferred items          |
| `.dev/notes/decisions.md`          | D## design decisions        |
