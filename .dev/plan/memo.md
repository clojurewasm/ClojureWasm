# ClojureWasm Development Memo

## Current State

- Phase: 10 (VM Correctness + VM-CoreClj Interop)
- Roadmap: .dev/plan/roadmap.md
- Current task: **T10.4 — Unify fn_val dispatch into single callFnVal**
- Task file: (none — create on start)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T10.3 Completed — VM Benchmark + Nested Fn Fix

Found and fixed use-after-free bug (D35/F18) in `compileArity`: nested fn
allocations (FnProto/Fn) were freed by child compiler's deinit, but parent's
constants table still held pointers. Fix: detach nested fn allocations and
transfer to parent compiler.

VM benchmark baseline recorded. Key findings:

- VM is 4-9x faster for pure computation (fib, tak, arith)
- VM is slower for HOF-heavy workloads (sieve 0.3x, map_filter_reduce 0.6x)
  due to cross-backend dispatch (VM->TW->VM) for each callback
- Collection ops are roughly equal (Zig builtins dominate)

### T10.4 Background — fn_val Dispatch Unification

T10.2 review revealed: fn_val invocation is scattered across 5 sites, each with
its own dispatch mechanism. All perform the same operation: call fn_val with args.

Current 5 dispatch mechanisms:

1. `vm.zig` — `fn_val_dispatcher` callback (VM->TW)
2. `tree_walk.zig` — `bytecode_dispatcher` callback (TW->VM)
3. `atom.zig` — `call_fn` module var (no kind check)
4. `value.zig` — `realize_fn` module var (no kind check)
5. `analyzer.zig` — `macroEvalBridge` passed directly

Target: unify into `callFnVal(allocator, env, fn_val, args)`.
See roadmap.md Phase 10c, decisions.md D34 follow-up.
