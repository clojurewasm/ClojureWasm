# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25.R, 25.0, 25.1, 25.2, 25.3, 25.4 complete
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 25 IN PROGRESS** — Wasm InterOp

## Task Queue

Phase 25 — Wasm InterOp (FFI):
1. ~~25.R: Research prerequisites~~ DONE
2. ~~25.0: Infrastructure setup~~ DONE
3. ~~25.1: wasm/load + wasm/fn~~ DONE
4. ~~25.2: Memory + string interop~~ DONE
5. ~~25.3: WASI Preview 1 + TinyGo~~ DONE
6. ~~25.4: Host function injection~~ DONE
7. 25.5: WIT parser + module objects — auto-resolve exports from WIT

## Current Task

25.5b: Module keyword lookup + module-as-function.
((:add mod) 3 4) => keyword dispatch on wasm_module.
(mod :add) => module-as-function. Cached WasmFn pre-generation.

## Previous Task

25.5: WIT parser + module objects (Phase 25.5 planned — 4 sub-tasks:
25.5a auto-export, 25.5b module keyword lookup, 25.5c WIT parser,
25.5d WIT string marshalling).

## Handover Notes

- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Partial (D74 filter chains). General recursion remains. Critical for Phase 26.
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. WASI P1 built-in (19 functions).
- **TinyGo**: 0.40.1 installed. go_math.go compiled to 09_go_math.wasm (20KB).
- **D76**: Wasm Value variants — wasm_module + wasm_fn in Value union
- **D77**: Host function injection — trampoline + context table (256 slots)
- **FFI examples**: examples/wasm/01_basic.clj, 02_tinygo.clj, 03_host_functions.clj
