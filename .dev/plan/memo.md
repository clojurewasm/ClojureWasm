# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 18.5 (Upstream Alignment + Core Expansion II)
- Current task: T18.5.1
- Task file: N/A
- Last completed: Phase 18 (4 tasks done, T18.2 deferred)
- Blockers: none
- Next: Fix F95 lazy-seq+cons → more core functions → numeric conversions

## Current Phase: 18

**Background**: Phase 18 completed: 5 bit ops, numbers.clj (37 tests/376 assertions),
23 core/walk functions, test coverage expansion (+120 assertions across 4 files).
Total: 14 test files, 332 done clojure.core vars, 189 Zig builtins.
F95 (lazy-seq+cons TypeError) blocks tree-seq and other lazy functions.

**Goal**: Fix infrastructure gaps (F95), continue core function expansion,
numeric conversions (deferred T18.2), upstream macro alignment.

### Rules

1. **TDD**: Failing test first, then implement
2. **Dual-Backend**: All tests pass both VM and TreeWalk
3. **Batch 3 pragmatism**: Only portable tests (no Java deps)
4. **vars.yaml**: Mark implemented vars done

### Task Queue

| Task    | Type | Description                              | Notes                                       |
| ------- | ---- | ---------------------------------------- | ------------------------------------------- |
| T18.5.1 | fix  | Fix F95 lazy-seq+cons TypeError          | Blocks tree-seq, reductions, other lazy fns |
| T18.5.2 | impl | Numeric conversions (int, long, etc.)    | int, long, float, double, num (deferred)    |
| T18.5.3 | impl | Core expansion II (seqable?, counted?)   | Zig builtins for type predicates            |
| T18.5.4 | impl | Seq utilities (reductions, take-nth etc) | Pure Clojure seq functions                  |
| T18.5.5 | test | Coverage: un-SKIP newly enabled tests    | Tests enabled by F95 fix and new functions  |

### Phase 18 Summary (completed)

| Task  | Status | Description                            |
| ----- | ------ | -------------------------------------- |
| T18.1 | done   | 5 bit ops builtins                     |
| T18.3 | done   | Port numbers.clj + ArithmeticError/NaN |
| T18.4 | done   | 23 core/walk functions                 |
| T18.5 | done   | Test coverage expansion (+120)         |

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
