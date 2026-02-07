# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25 complete (Wasm InterOp FFI)
- Phase 26.R complete (wasm_rt Research — archived, implementation deferred)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction pivot**: Native production track. wasm_rt deferred.
- **Phase 27 COMPLETE** — NaN Boxing (Value 48B -> 8B, avg 33% faster, 53% less mem)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: 27 (NaN boxing) -> 28 (single binary) -> 29 (restructure)
-> 30 (robustness/nREPL) -> 31 (Wasm FFI deep)

## Task Queue

Phase 27 COMPLETE. Next: Phase 28 — Single Binary.

## Current Task

Phase 27 complete. Planning Phase 28.

## Previous Task

27.4 DONE: Benchmarked NaN boxing results — 17-44% faster, 44-57% less memory.
19/20 benchmarks faster (avg -33%). All 20 benchmarks reduced memory (avg -53%).
Only regression: string_ops +7% (HeapString indirection).

## Known Issues from Phase 27

- 9 HeapString/Symbol/Keyword leaks at program exit (bootstrap allocations not freed)
  Root cause: GC does not yet trace NaN-boxed heap pointers.
  Impact: cosmetic (GPA leak warnings at exit). Correctness unaffected.
  Fix: Update gc.zig to trace Value's NanHeapTag pointers. Add as F-item.

## Handover Notes

- **Roadmap**: .dev/plan/roadmap.md — Phases 27-31 defined
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B→8B. 17 commits (27.1-27.4).
  API layer → call site migration → internal switch → benchmark.
  Known issue: 9 heap leaks at exit (GC not tracing NaN-boxed ptrs).
- **Single binary**: @embedFile for user .clj + .wasm. F7 (macro serialization) for AOT.
- **nREPL**: cider-nrepl op compatibility target. Modular middleware approach.
- **Skip vars**: 178 skipped — re-evaluate for Zig equivalents (threading, IO, etc.)
- **Directory restructure**: common/native/ -> core/eval/cli/ (Phase 29)
- **zware**: Pure Zig Wasm runtime. Phase 25 FFI uses it.
- **D76/D77**: Wasm Value variants + host function injection (Phase 25)
