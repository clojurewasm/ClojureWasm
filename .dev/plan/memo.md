# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 15.5 (Test Re-port with Dual-Backend Verification)
- Current task: (none)
- Task file: N/A
- Last completed: T15.5.2-11 — All test files pass dual-backend; ns :require/:use added
- Blockers: none
- Next: Phase 15.5 complete — plan Phase 16

## Current Phase: 15.5

**Background**: Phase 14-15 test porting verified TreeWalk only, skipping VM.
This led to SKIP + F## workarounds accumulating instead of root cause fixes.

**Goal**: Re-port Clojure tests from scratch, running both VM and TreeWalk,
fixing issues properly instead of working around them.

### Rules

1. **Dual-Backend Execution**: Run every test on both backends

   ```bash
   ./zig-out/bin/cljw test.clj              # VM
   ./zig-out/bin/cljw --tree-walk test.clj  # TreeWalk
   ```

2. **SKIP is Last Resort**: Only for truly JVM-specific features (threading, reflection)
   - Failure → investigate root cause
   - Missing feature → implement it
   - Bug → fix it

3. **Use `--dump-bytecode`**: Debug VM failures

   ```bash
   echo '(failing-expr)' > /tmp/debug.clj
   ./zig-out/bin/cljw --dump-bytecode /tmp/debug.clj
   ```

4. **Discovery → Implementation**: Tests reveal gaps, fill them
   - Missing function → implement
   - Latent bug → fix
   - Workaround → normalize

### Task Queue

Re-verify tests in original porting order. One file = one task.
Run both VM and TreeWalk, fix issues before moving to next.

| Task     | File                                    | Notes               |
| -------- | --------------------------------------- | ------------------- |
| T15.5.1  | `test/upstream/sci/core_test.clj`       | SCI tests (70/74)   |
| T15.5.2  | `test/upstream/clojure/for.clj`         | for macro           |
| T15.5.3  | `test/upstream/clojure/control.clj`     | if-let, case, cond  |
| T15.5.4  | `test/upstream/clojure/logic.clj`       | and, or, not        |
| T15.5.5  | `test/upstream/clojure/predicates.clj`  | type predicates     |
| T15.5.6  | `test/upstream/clojure/atoms.clj`       | atom, swap!, reset! |
| T15.5.7  | `test/upstream/clojure/sequences.clj`   | seq functions       |
| T15.5.8  | `test/upstream/clojure/data_struct.clj` | destructuring       |
| T15.5.9  | `test/clojure/macros.clj`               | threading macros    |
| T15.5.10 | `test/clojure/special.clj`              | special forms       |
| T15.5.11 | `test/clojure/clojure_walk.clj`         | walk (partial)      |

### Completion Criteria

- All ported tests pass on both VM and TreeWalk
- High priority F## items resolved
- Resolved items struck through in `checklist.md`

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
