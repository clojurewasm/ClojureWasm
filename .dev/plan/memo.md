# ClojureWasm Development Memo

## Current State

- Phase: 10 (VM Correctness + VM-CoreClj Interop)
- Roadmap: .dev/plan/roadmap.md
- Current task: **T10.2 — Unified fn_val proto (F8)**
- Task file: (none — create on start)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T10.2 Context

**Problem**: VM can't call core.clj higher-order functions (map, filter, reduce).
8/11 VM benchmarks fail because VM dispatch doesn't handle TreeWalk closures.

**Background** (from F8/D22):

- core.clj functions are loaded via TreeWalk eval at startup
- They produce fn_val with TreeWalk-style proto (captured env, body node)
- VM dispatch only handles VM-compiled fn_val (with FnProto bytecode)
- Need to unify so VM can call TreeWalk closures and vice versa

**Key files to investigate**:

- `src/common/value.zig` — fn_val / Fn type definition
- `src/native/vm/vm.zig` — VM call dispatch
- `src/native/evaluator/tree_walk.zig` — TreeWalk fn_val creation
- `src/common/bootstrap.zig` — evalStringVM pipeline
