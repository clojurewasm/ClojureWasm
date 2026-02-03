# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.9 — SCI test port + triage
- Task file: (none — create on start)
- Last completed: T12.8 — gensym, compare-and-set!, format
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 12a complete — Tier 1 Zig Builtins

All 8 tasks in Phase 12a are done:

- T12.1: dissoc, disj, find, peek, pop, empty
- T12.2: subvec, array-map, hash-set, sorted-map
- T12.3: hash, identical?, ==
- T12.4: reduced, reduced?, unreduced, ensure-reduced
- T12.5: eval, macroexpand, macroexpand-1, read-string
- T12.6: all-ns, find-ns, ns-name, create-ns, the-ns
- T12.7: ns-map, ns-publics, ns-interns
- T12.8: gensym, compare-and-set!, format

Registry: 152 builtins, 267/702 vars done

### T12.9 scope — SCI Test Port

Run SCI tests, categorize failures into:

- Missing Tier 1 (Zig builtin needed)
- Missing Tier 2 (core.clj needed)
- JVM-specific (skip)

**F22 trigger**: introduce compat_test.yaml for test tracking
**F24 trigger**: refine vars.yaml status values (stub/defer/partial)

Reference: roadmap.md Phase 12b, Future Considerations section

### Deferred items to watch

- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

152 builtins registered
267/702 vars done
