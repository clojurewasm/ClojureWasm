# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.9 — SCI test port + triage (DONE)
- Task file: .dev/plan/active/task_0106_sci_test_port.md
- Last completed: T12.9 — SCI test port + triage
- Blockers: none
- Next: Check roadmap for Phase 12 completion / Phase 13 planning

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 12 complete — Tier 1 Zig Builtins + SCI Test Port

All 9 tasks in Phase 12 are done:

- T12.1: dissoc, disj, find, peek, pop, empty
- T12.2: subvec, array-map, hash-set, sorted-map
- T12.3: hash, identical?, ==
- T12.4: reduced, reduced?, unreduced, ensure-reduced
- T12.5: eval, macroexpand, macroexpand-1, read-string
- T12.6: all-ns, find-ns, ns-name, create-ns, the-ns
- T12.7: ns-map, ns-publics, ns-interns
- T12.8: gensym, compare-and-set!, format
- T12.9: SCI test port — 70/74 tests pass (248 assertions)

Registry: 152 builtins, 267/702 vars done

### SCI Test Port Results (T12.9)

Test file: `test/upstream/sci/core_test.clj` (820 lines, TreeWalk-only)
Tracking: `.dev/status/compat_test.yaml`

Missing features discovered:

- **Tier 1** (Zig builtin): list?, int?, reduce/2, set-as-function, deref delay, into map from pairs
- **Tier 2** (core.clj): clojure.string namespace, {:keys [:a]} destructuring
- **Behavioral**: named fn self-ref, fn param shadow, var :name meta

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed

### Builtin Count

152 builtins registered
267/702 vars done
