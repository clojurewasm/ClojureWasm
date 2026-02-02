# T10.3: VM Benchmark Re-run + Recording

## Goal

Re-run all 11 benchmarks with both backends (TreeWalk + VM) after T10.1 loop/recur fix
and T10.2 reverse dispatch. Record VM baseline in bench.yaml.

## Plan

1. Build ClojureWasm (Debug)
2. Run all 11 benchmarks with default backend (TreeWalk) — verify no regressions vs Phase 5
3. Run all 11 benchmarks with `--backend=vm` — verify all pass (no segfaults)
4. Record VM baseline: `bash bench/run_bench.sh --backend=vm --record --version="Phase 10 VM baseline"`
5. Compare VM vs TreeWalk performance, note findings in Log
6. Update bench.yaml if needed, update status files

## Context

- T10.1 fixed VM loop/recur (pop_under bug)
- T10.2 added TreeWalk→VM reverse dispatch (bytecodeCallBridge)
- Phase 5 baseline (TreeWalk) already recorded in bench.yaml
- All 11 benchmarks should now work with VM backend

## Log

### Bug Found: Use-after-free in nested fn compilation

When running VM benchmarks, sieve (09) crashed with "switch on corrupt value".

**Root cause**: `compileArity` in compiler.zig creates a child `fn_compiler` for
each function body. If the body contains nested fns (e.g., `(fn [x] ...)`), those
nested fns' FnProto and Fn objects are allocated by the child compiler. When
`fn_compiler.deinit()` runs, it frees those objects — but the parent's constants
table still holds `.fn_val` pointers to them. Use-after-free.

**Fix**: Before `fn_compiler.deinit()`, call `detachFnAllocations()` on the child
compiler and transfer all nested fn_protos/fn_objects to the parent compiler.
This ensures they survive until the top-level compiler (or `evalStringVM`) manages
their lifetime.

File: `src/common/bytecode/compiler.zig` (compileArity)

### Benchmark Results

All 11 benchmarks pass on both backends.

#### VM vs TreeWalk Comparison (Debug build, Apple M4 Pro)

| Benchmark         | TreeWalk | VM     | Speedup |
| ----------------- | -------- | ------ | ------- |
| fib_recursive     | 494 ms   | 54 ms  | 9.1x    |
| fib_loop          | 11 ms    | 10 ms  | 1.1x    |
| tak               | 124 ms   | 22 ms  | 5.6x    |
| arith_loop        | 840 ms   | 213 ms | 3.9x    |
| map_filter_reduce | 381 ms   | 623 ms | 0.6x    |
| vector_ops        | 145 ms   | 133 ms | 1.1x    |
| map_ops           | 27 ms    | 26 ms  | 1.0x    |
| list_build        | 135 ms   | 129 ms | 1.0x    |
| sieve             | 86 ms    | 299 ms | 0.3x    |
| nqueens           | 214 ms   | 78 ms  | 2.7x    |
| atom_swap         | 28 ms    | 19 ms  | 1.5x    |

**Analysis**:

- VM is significantly faster for pure computation (fib: 9x, tak: 5.6x, arith: 3.9x)
- VM is slower for HOF-heavy benchmarks (sieve: 0.3x, map_filter_reduce: 0.6x)
  because core.clj HOFs (filter, map, reduce) run in TreeWalk, requiring cross-backend
  dispatch (VM->TW->VM) for each callback invocation
- Collection-heavy benchmarks are roughly equal (operations happen in Zig builtins)
- nqueens (2.7x) benefits from heavy fn-call overhead reduction despite using some HOFs
