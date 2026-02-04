# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 17.5 (Infrastructure Fix)
- Current task: (none — planning needed)
- Task file: N/A
- Last completed: Phase 17 complete (IO/Print/System functions, 306 vars, 184 builtins)
- Blockers: none
- Next: Plan Phase 17.5 Task Queue (try/catch/throw → destructuring → VM defmulti)

## Current Phase: 17.5

**Background**: Phase 17 completed IO/print/system functions (14 new builtins).
Total: 13 test files, 115 tests, 442 assertions on TreeWalk; 106 tests on VM.
306 done vars, 184 Zig builtins.

**Goal**: Fix cross-cutting infrastructure gaps blocking ~35+ test SKIPs.
Three priority areas in order.

### Rules

1. **TDD**: Failing test first, then implement
2. **Dual-Backend**: All fixes must pass both VM and TreeWalk
3. **Test SKIPs**: Un-SKIP tests as infrastructure becomes available
4. **checklist.md**: Resolve F## items, strike from list

### Priority Areas

1. **try/catch/throw** (~15 SKIPs) — Analyzer special forms, VM opcodes,
   TreeWalk handling. Largest single blocker.
2. **Destructuring fixes** (~10 SKIPs) — F58, F67-F74, F79.
   Concentrated in Analyzer destructuring code.
3. **VM defmulti/defmethod opcodes** (F13) — Compiler + VM opcodes.

### Task Queue

| Task    | Type | Description                             | Notes                                   |
| ------- | ---- | --------------------------------------- | --------------------------------------- |
| T17.5.1 | done | VM try/catch body evaluation bug        | D59: stepInstruction + error routing    |
| T17.5.2 | done | Destructuring: F58 nested map           | Recursive expandBindingPattern          |
| T17.5.3 | done | Destructuring: F67 rest args + map      | apply hash-map conversion               |
| T17.5.4 | done | Destructuring: F69 keywords in :keys    | Already working                         |
| T17.5.5 | done | Destructuring: F79 :syms basic          | makeGetSymbolCall in analyzer           |
| T17.5.6 | impl | VM defmulti/defmethod opcodes (F13)     | Compiler + VM opcodes for multimethod   |
| T17.5.7 | impl | clojure.string expansion                | capitalize, split-lines, index-of, etc. |
| T17.5.8 | test | Un-SKIP tests enabled by infrastructure | Re-enable SKIP tests that now pass      |

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
