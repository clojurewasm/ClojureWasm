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

### T10.2 Investigation (done in pre-planning)

**Current state of fn_val dispatch (already implemented)**:

- `Fn.kind: FnKind` already distinguishes `.bytecode` / `.treewalk`
- VM `performCall` already checks `fn_obj.kind == .treewalk` and dispatches
  to `fn_val_dispatcher` (= `macroEvalBridge` in bootstrap.zig)
- So VM calling TreeWalk closures already works (e.g. `(map inc [1 2 3])` works)

**The real problem — reverse direction**:
When VM calls a TreeWalk closure (like `map` from core.clj), that TreeWalk
closure receives a VM-compiled callback (like `(fn [x] (* x x))`). TreeWalk
then tries to call this bytecode fn via `callClosure`, which interprets the
FnProto pointer as a TreeWalk Closure pointer → **segfault**.

**Stack trace** (from `bench/benchmarks/05_map_filter_reduce/bench.clj`):

```
vm.performCall → macroEvalBridge → tw.callValue → tw.callClosure
  → findArity(fn_n.arities, ...) — segfault (FnProto != Closure)
```

**What needs to happen**:
TreeWalk's `callClosure` (or `callValue`) must check `fn_obj.kind` and,
when it encounters a `.bytecode` fn, dispatch back to VM for execution.
This creates a VM↔TreeWalk call bridge in both directions:

- VM → TreeWalk: already done (fn_val_dispatcher / macroEvalBridge)
- TreeWalk → VM: **missing** — need a bytecode_fn_dispatcher or similar

**Key files**:

- `src/native/evaluator/tree_walk.zig:228-240` — callClosure, needs kind check
- `src/native/evaluator/tree_walk.zig:160-170` — callValue, fn_val dispatch
- `src/native/vm/vm.zig:458-489` — performCall (reference for the VM→TW bridge)
- `src/common/bootstrap.zig:179` — fn_val_dispatcher wiring
- `src/common/bootstrap.zig:187-200` — macroEvalBridge

**Approach options**:

1. Add a `bytecode_dispatcher` callback to TreeWalk (symmetric to VM's fn_val_dispatcher)
2. Have TreeWalk spin up a temporary VM to run bytecode fns
3. Compile core.clj with VM compiler so everything is bytecode (bigger change)

Option 1 is most consistent with the existing pattern and smallest change.
