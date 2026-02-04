# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 18.5 (Upstream Alignment + Core Expansion II)
- Current task: T18.5.4
- Task file: N/A
- Last completed: T18.5.3 (10 type predicates + bounded-count)
- Blockers: none
- Next: Seq utilities → coverage expansion

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

| Task    | Type | Description                              | Notes                                      |
| ------- | ---- | ---------------------------------------- | ------------------------------------------ |
| T18.5.1 | done | Fix F95 lazy-seq+cons TypeError          | D61: lazy_seq opcode + collectSeqItems     |
| T18.5.2 | done | Numeric conversions (int, long, etc.)    | 8 builtins, 341 done vars                  |
| T18.5.3 | done | Core expansion II (seqable?, counted?)   | 10 builtins, 351 done vars                 |
| T18.5.4 | impl | Seq utilities (reductions, take-nth etc) | Pure Clojure seq functions                 |
| T18.5.5 | test | Coverage: un-SKIP newly enabled tests    | Tests enabled by F95 fix and new functions |

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
