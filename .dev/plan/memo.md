# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 24 COMPLETE** — CW wins speed 19/20, 1 tied
- Next: Phase 24.5 (Mini-Refactor), then Phase 25 (Wasm InterOp)

## Task Queue

Phase 25 — Wasm InterOp (FFI):
1. 25.R: Research prerequisites — zware 0.15.2 compat, WASI status, Zig target names
2. 25.0: Infrastructure setup — zware dep, WAT test files, src/wasm/types.zig, smoke test
3. 25.1: wasm/load + wasm/fn — load .wasm, call with type hints, both backends
4. 25.2: Memory + string interop — linear memory read/write, UTF-8
5. 25.3: Host function injection — Clojure fns callable from Wasm
6. 25.4: WASI Preview 1 basics — fd_write, proc_exit, args/environ
7. 25.5: WIT parser + module objects — auto-resolve exports from WIT

## Current Task

25.1: wasm/load + wasm/fn — Clojure builtins for loading Wasm modules and
calling exported functions with type hints. Both backends (D6).

## Previous Task

25.0: Infrastructure — zware dep, 8 WAT test modules, WasmModule.load/invoke,
smoke tests pass (add(3,4)=7, fib(10)=55).

## Handover Notes

- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Partial (D74 filter chains). General recursion remains. Critical for Phase 26.
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. Verify 0.15.2 compat at Phase 25 start.
- **WasmResearch**: Investigation repo with docs + WAT/WIT examples
