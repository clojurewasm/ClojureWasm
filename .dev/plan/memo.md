# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 16 (Test Expansion & Bug Fix)
- Current task: (none)
- Task file: N/A
- Last completed: T16.1 — clojure.set ns, map-as-fn, first/rest on set, in-ns refers
- Blockers: none
- Next: T16.2 (Port string.clj)

## Current Phase: 16

**Background**: Phase 15.5 verified all existing tests on both backends (196 tests,
1046 assertions). 4 new F## items discovered (F76-F79). Test Batch 1 has 5 unported
files. Many F## items from earlier phases remain open.

**Goal**: Expand test coverage via Batch 1 remaining files + fix high-priority bugs.
Continue dual-backend policy from Phase 15.5.

### Rules

Same as Phase 15.5:

1. **Dual-Backend Execution**: Run every test on both backends
2. **SKIP is Last Resort**: Only for JVM-specific features
3. **Use `--dump-bytecode`**: Debug VM failures
4. **Discovery → Implementation**: Tests reveal gaps, fill them

### Task Queue

| Task   | Type    | Description                                     | Notes                                   |
| ------ | ------- | ----------------------------------------------- | --------------------------------------- |
| T16.1  | test    | Port clojure_set.clj + implement clojure.set ns | union, intersection, difference, etc.   |
| T16.2  | test    | Port string.clj (clojure.string tests)          | Already have clojure.string ns          |
| T16.3  | test    | Port keywords.clj                               | keyword ops, find-keyword               |
| T16.4  | test    | Port other_functions.clj                        | identity, fnil, constantly, comp, juxt  |
| T16.5  | test    | Port metadata.clj                               | meta, with-meta, vary-meta              |
| T16.6  | bugfix  | Fix F77: VM user-defined macro expansion        | -> threading with user defmacro         |
| T16.7  | bugfix  | Fix F76: VM stack_depth underflow with recur    | recur inside when-not/cond->            |
| T16.8  | feature | Implement missing predicates (F35-F37)          | sequential?, associative?, ifn?         |
| T16.9  | feature | Implement missing seq fns (F43-F44, F46-F47)    | ffirst, nnext, drop-last, split-at/with |
| T16.10 | feature | Implement swap-vals!/reset-vals! (F38-F39)      | Atom operations returning [old new]     |

### Completion Criteria

- Batch 1 test files all ported and passing dual-backend
- F76, F77 VM bugs fixed
- F35-F39, F43-F44, F46-F47 implemented
- Total test count significantly higher than 196

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
