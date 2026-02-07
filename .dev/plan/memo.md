# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25.R, 25.0, 25.1, 25.2, 25.3, 25.4 complete
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 25.5a, 25.5b, 25.5c, 25.5d complete
- **Phase 25 IN PROGRESS** — Wasm InterOp

## Task Queue

Phase 25 — Wasm InterOp (FFI):
1. ~~25.R: Research prerequisites~~ DONE
2. ~~25.0: Infrastructure setup~~ DONE
3. ~~25.1: wasm/load + wasm/fn~~ DONE
4. ~~25.2: Memory + string interop~~ DONE
5. ~~25.3: WASI Preview 1 + TinyGo~~ DONE
6. ~~25.4: Host function injection~~ DONE
7. ~~25.5: WIT parser + module objects~~ DONE (25.5a-d)

## Current Task

Phase 25.5 complete. Next: plan Phase 26 or advance roadmap.

## Previous Task

25.5d: WIT string auto-marshalling — callWithWitMarshalling,
string→ptr/len via cabi_realloc, result read-back, greet.wat test module.

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
- **FFI examples**: examples/wasm/01-05 (basic, tinygo, host_functions, module_objects, wit)
- **WIT support**: wit_parser.zig, wasm/describe, string auto-marshalling via cabi_realloc
