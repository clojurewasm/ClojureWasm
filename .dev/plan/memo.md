# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 27 complete (A, BE, B, C, CX, R, D, 20-27, 22b, 22c, 24.5)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 28 IN PROGRESS** — Single Binary Builder

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27 (NaN boxing)~~ -> **28 (single binary)** -> 29 (restructure)
-> 30 (robustness/nREPL) -> 31 (Wasm FFI deep)

## Task Queue

Phase 28.1 — Source Embedding (MVP):

1. **28.1a**: Embedded source detection at startup
2. **28.1b**: `build` subcommand implementation
3. **28.1c**: Built binary CLI args as `*command-line-args*`
4. **28.1d**: Integration test (build + run + verify)

## Current Task

28.1a: Add readEmbeddedSource() to main.zig. Uses std.fs.selfExePath() to
read own binary, checks last 12 bytes for "CLJW" magic trailer. If found,
extracts .clj source payload and evaluates it (embedded mode).

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
