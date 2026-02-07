# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25.R, 25.0, 25.1 complete
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 25 IN PROGRESS** — Wasm InterOp

## Task Queue

Phase 25 — Wasm InterOp (FFI):
1. ~~25.R: Research prerequisites~~ DONE
2. ~~25.0: Infrastructure setup~~ DONE
3. ~~25.1: wasm/load + wasm/fn~~ DONE
4. 25.2: Memory + string interop — linear memory read/write, UTF-8
5. 25.3: Host function injection — Clojure fns callable from Wasm
6. 25.4: WASI Preview 1 basics — fd_write, proc_exit, args/environ
7. 25.5: WIT parser + module objects — auto-resolve exports from WIT

## Current Task

25.2: Memory + string interop — wasm/memory-write, wasm/memory-read for
linear memory access. UTF-8 string round-tripping through Wasm memory.

## Previous Task

25.1: wasm/load + wasm/fn — D76. Two new Value variants (wasm_module, wasm_fn).
wasm namespace with load/fn builtins. Both VM + TreeWalk dispatch.
Integration tests pass: add(3,4)=7, fib(10)=55.

## Handover Notes

- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Partial (D74 filter chains). General recursion remains. Critical for Phase 26.
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. Confirmed 0.15.2 compatible.
- **WasmResearch**: Investigation repo with docs + WAT/WIT examples
- **D76**: Wasm Value variants — wasm_module + wasm_fn in Value union
