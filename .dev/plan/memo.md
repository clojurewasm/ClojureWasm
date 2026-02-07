# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 28.1 complete (A, BE, B, C, CX, R, D, 20-28.1, 22b, 22c, 24.5)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 28.1 COMPLETE** — Single Binary Builder MVP (1.7MB binary)
- **Phase 29 SKIPPED** — File splitting impractical (Zig struct constraint),
  D3 violations require BuiltinFn signature change (500+ functions)
- **Phase 30 IN PROGRESS** — Production Robustness

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> **30 (robustness)** -> 31 (FFI)

## Task Queue

Phase 30 — Production Robustness. Planning needed. Read roadmap Phase 30:
- Error reporting improvements (Babashka-quality stack traces)
- Skip var recovery (re-evaluate 178 skipped vars for Zig equivalents)
- nREPL/cider-nrepl compatibility
- Zero-config project model

## Current Task

Planning Phase 30. Need to create phase30 plan file with task queue.

## Previous Task

Phase 29 analysis: File splitting impractical (Zig struct methods must be
in same file, tests 50-78% of large files). D3 violations require
BuiltinFn signature change (fn(Alloc,[]Value) → fn(Alloc,*Env,[]Value),
500+ function signatures). Both dropped. Proceeding to Phase 30.

## Known Issues from Phase 27

- 9 HeapString/Symbol/Keyword leaks at program exit (bootstrap allocations not freed)
  Root cause: GC does not yet trace NaN-boxed heap pointers.
  Impact: cosmetic (GPA leak warnings at exit). Correctness unaffected.
  Fix: Update gc.zig to trace Value's NanHeapTag pointers. Add as F-item.

## Handover Notes

- **Phase 28 plan**: .dev/plan/phase28-single-binary.md
- **Roadmap**: .dev/plan/roadmap.md — Phases 27-31 defined
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B→8B. 17 commits (27.1-27.4).
- **Single binary**: Binary trailer approach (Deno-style). No Zig needed on user machine.
  Format: [cljw binary] + [.clj source] + [u64 size] + "CLJW" magic.
- **macOS signing**: Ad-hoc resign with `codesign -s - -f` after build.
  Proper section injection deferred.
