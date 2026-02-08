# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 36.7 complete
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Wasm interpreter**: 7.9x FFI improvement (D86), 236 SIMD opcodes

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 36 (SIMD + FFI deep). Plan: `.dev/plan/phase36-simd-ffi.md`.

1. ~~**36.1-36.6** SIMD implementation + benchmarks (236 opcodes)~~
2. ~~**36.7** Wasm interpreter optimization (D86: VM reuse + sidetable)~~
3. **36.8** Multi-module linking
4. **36.9** F119 fix — WIT string return marshalling
5. **36.10** Documentation + cleanup

## Current Task

36.8: Multi-module linking.

## Previous Task

36.7D: Benchmark measurement + recording.
D86 decision recorded. Final results: wasm_call 7.9x, wasm_fib 1.44x, wasm_memory 7.4x.

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA.
- F119 OPEN: WIT string return marshalling — returns accumulated memory.

## Reference Chain

Session resume procedure: read this file → follow references below.

### Phase 36 (current)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/plan/phase36-simd-ffi.md`                   |
| **Optimization decision**    | `.dev/notes/decisions.md` D86                     |
| **SIMD benchmarks**          | `bench/simd/` (4 programs + results.md)           |
| **Wasm benchmarks**          | `bench/benchmarks/21-25_wasm_*/`                  |
| **Conformance tests**        | `src/wasm/testdata/conformance/` (9 WAT+WASM)     |
| **E2E tests**                | `test/e2e/wasm/*.clj`, `test/e2e/run_e2e.sh`     |

### Global references

| Topic               | Location                                  |
|----------------------|-------------------------------------------|
| Roadmap              | `.dev/plan/roadmap.md`                    |
| Deferred items       | `.dev/checklist.md` (F3-F120)             |
| Decisions            | `.dev/notes/decisions.md` (D1-D86)        |
| Optimizations        | `.dev/notes/optimizations.md`             |
| Benchmarks           | `bench/history.yaml`                      |
| Zig tips             | `.claude/references/zig-tips.md`          |
| Archived plans       | `.dev/plan/archive/` (Phase 24-30, CX, A) |

## Handover Notes

- **Phase 36.7 COMPLETE** (D86): Wasm interpreter optimization
  - 36.7A: VM reuse — cached Vm in WasmModule, 7.9x wasm_call
  - 36.7B: Sidetable — lazy branch table in WasmFunction, 1.44x wasm_fib
  - 36.7C: Abandoned (cached_memory + @memset ROI < 1%)
  - 36.7D: Benchmark recorded, D86 decision
- **Phase 36.1-36.6 COMPLETE**: SIMD full implementation
  - 236 SIMD opcodes (v128 type, integer/float arithmetic, memory, shuffle)
  - vector_add 2.58x speedup over non-SIMD Wasm
- **Phase 35X COMPLETE**: Cross-platform build (D85 NaN boxing, CI)
- **Phase 35W COMPLETE** (D84): Custom Wasm runtime (8 files, switch dispatch)
- **Phase 35.5 COMPLETE**: Wasm runtime hardening (WASI 84%, conformance tests)
- **Architecture**: NaN boxing 4-tag 48-bit (D85), single binary trailer, ~3ms startup
- **nREPL/CIDER**: 14 ops. `cljw --nrepl-server --port=0`
