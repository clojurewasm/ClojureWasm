# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25 complete (Wasm InterOp FFI)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 26.R IN PROGRESS** — wasm_rt Research

## Task Queue

Phase 26.R — wasm_rt Research:
1. ~~26.R.1: Compile Probe~~ DONE
2. ~~26.R.2: Code Organization Strategy~~ DONE
3. ~~26.R.3: Allocator and GC Strategy~~ DONE
4. 26.R.4: Stack Depth and F99 Assessment
5. 26.R.5: Backend Selection
6. 26.R.6: Modern Wasm Spec Assessment
7. 26.R.7: MVP Definition and Full Plan

## Current Task

26.R.4: Stack Depth and F99 Assessment — is iterative lazy-seq a prerequisite?

## Previous Task

26.R.3: Allocator and GC Strategy — MarkSweepGc works on wasm32-wasi as-is.
GPA→WasmPageAllocator validated. WasmGC deferred (Zig can't emit).

## Handover Notes

- **Phase 26 plan**: .dev/plan/phase26-wasm-rt.md (building incrementally)
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Partial (D74 filter chains). General recursion remains. Critical for Phase 26.
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. WASI P1 built-in (19 functions).
- **D76**: Wasm Value variants — wasm_module + wasm_fn in Value union
- **D77**: Host function injection — trampoline + context table (256 slots)
- **Compile probe PoC**: GPA, fs.cwd(), time, process.args all work on wasm32-wasi
- **WASI fd convention**: stdout=1, stderr=2 (same as POSIX, no std.posix needed)
