# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 18.5 (Upstream Alignment + Core Expansion II)
- Phase: 18.6 (Core Coverage Sprint)
- Current task: T18.6.4
- Task file: N/A
- Last completed: T18.6.3 (13 pure Clojure additions: random-sample, replicate, comparator, xml-seq, printf, test, mapv, time, lazy-cat, when-first, assert, _assert_, map/filter xf)
- Blockers: none
- Next: Coverage expansion tests

## Current Phase: 18

**Background**: Phase 18.5 completed: lazy-seq VM opcode (D61), 22 new functions,
8 numeric coercions, 10 type predicates, 4 seq utilities, test expansion.
Total: 14 test files, 394 done clojure.core vars, 210 Zig builtins, 971 assertions.

**Goal**: Sprint to 380+ done vars. Quick-win functions, transducer basics,
collection utilities (rseq, shuffle), and bit-and-not.

### Rules

1. **TDD**: Failing test first, then implement
2. **Dual-Backend**: All tests pass both VM and TreeWalk
3. **Batch 3 pragmatism**: Only portable tests (no Java deps)
4. **vars.yaml**: Mark implemented vars done

### Task Queue

| Task    | Type | Description                              | Notes                                  |
| ------- | ---- | ---------------------------------------- | -------------------------------------- |
| T18.6.1 | done | Quick-win Zig builtins + aliases         | 3 builtins + 17 aliases, 375 done vars |
| T18.6.2 | done | Transducer basics (transduce, cat, etc.) | +map/filter xf, conj arity, 383 vars   |
| T18.6.3 | done | Pure Clojure additions                   | 13 functions/macros, 394 done vars     |
| T18.6.4 | test | Coverage expansion                       | Tests for T18.6.1-3 features           |

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
