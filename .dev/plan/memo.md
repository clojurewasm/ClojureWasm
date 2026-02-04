# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 18.7 (Core Coverage Sprint II)
- Current task: T18.7.3
- Task file: N/A
- Last completed: T18.7.2 (Zig builtins: parse-long/double, special-symbol?; 405 done)
- Blockers: none
- Next: hierarchy → coverage

## Current Phase: 18

**Background**: Phase 18.5 completed: lazy-seq VM opcode (D61), 22 new functions,
8 numeric coercions, 10 type predicates, 4 seq utilities, test expansion.
Total: 14 test files, 394 done clojure.core vars, 210 Zig builtins, 971 assertions.

**Goal**: Continue sprint toward 400+ done vars. Quick-win defs, Zig builtins
(parse-long/double, special-symbol?), hierarchy basics, coverage expansion.

### Rules

1. **TDD**: Failing test first, then implement
2. **Dual-Backend**: All tests pass both VM and TreeWalk
3. **Batch 3 pragmatism**: Only portable tests (no Java deps)
4. **vars.yaml**: Mark implemented vars done

### Task Queue

| Task    | Type | Description                   | Notes                                  |
| ------- | ---- | ----------------------------- | -------------------------------------- |
| T18.7.1 | impl | Quick-win defs + pure Clojure | make-hierarchy, char-\*, version, etc. |
| T18.7.2 | impl | Zig builtins                  | parse-long/double, special-symbol?     |
| T18.7.3 | impl | Hierarchy basics              | parents, descendants, ancestors        |
| T18.7.4 | test | Coverage expansion            | Tests for T18.7.1-3 features           |

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
