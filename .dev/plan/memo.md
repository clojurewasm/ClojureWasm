# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 16.5 (Test Batch 2 Port)
- Current task: (none)
- Task file: N/A
- Last completed: T16.10 — Implement swap-vals!/reset-vals! (F38-F39)
- Blockers: none
- Next: T16.5.1 (Port multimethods.clj)

## Current Phase: 16.5

**Background**: Phase 16 completed Batch 1 test ports (8 files, 79 tests, 332 assertions),
fixed F76/F77 VM bugs, implemented F35-F39/F43-F47. Total: 290 done vars.
SCI tests: 72 tests, 267 assertions on TreeWalk.

**Goal**: Port Test Batch 2 (core features). Continue dual-backend policy.

### Rules

Same as Phase 15.5/16:

1. **Dual-Backend Execution**: Run every test on both backends
2. **SKIP is Last Resort**: Only for JVM-specific features
3. **Use `--dump-bytecode`**: Debug VM failures
4. **Discovery → Implementation**: Tests reveal gaps, fill them

### Task Queue

| Task    | Type | Description                               | Notes                               |
| ------- | ---- | ----------------------------------------- | ----------------------------------- |
| T16.5.1 | test | Port multimethods.clj                     | defmulti, defmethod (TreeWalk only) |
| T16.5.2 | test | Port vars.clj                             | def, defn, binding, dynamic vars    |
| T16.5.3 | test | Port volatiles.clj                        | volatile!, vreset!, vswap!          |
| T16.5.4 | test | Port delays.clj                           | delay, force, realized?             |
| T16.5.5 | test | Implement core bugfixes found during port | Fix F## items discovered in Batch 2 |

### Completion Criteria

- Batch 2 test files ported and passing dual-backend
- New F## items documented
- Total test count significantly higher than 79 ported tests

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
