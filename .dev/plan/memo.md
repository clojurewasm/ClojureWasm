# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 35.5 complete (A, BE, B, C, CX, R, D, 20-34, 22b, 22c, 24.5, 35W, 35.5)
- **Phase 35X COMPLETE** — Cross-Platform Build & Verification
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~30~~ -> ~~31~~ -> ~~32~~ -> ~~33~~ -> ~~34~~ -> ~~35W~~ -> ~~35.5~~ -> ~~35X~~ -> **36 (SIMD + FFI deep)** -> 37 (GC/JIT)

## Task Queue

Phase 36 (SIMD + FFI deep). Plan: `.dev/plan/phase36-simd-ffi.md`.

1. ~~**36.1** v128 value stack + SIMD opcode enum (foundation)~~
2. ~~**36.2** SIMD memory + constant ops (~40 opcodes)~~
3. ~~**36.3** SIMD integer arithmetic (~130 opcodes)~~
4. ~~**36.4** SIMD float arithmetic (~50 opcodes)~~
5. ~~**36.5** SIMD shuffle + swizzle + remaining ops (covered by 36.2-36.4)~~
6. ~~**36.6** SIMD benchmark + regression measurement~~
7. **36.7A** VM reuse (WasmModule Vm cache)
8. **36.7B** Branch target precomputation (sidetable)
9. **36.7C** Memory + local optimization
10. **36.7D** Benchmark measurement + recording
11. **36.8** Multi-module linking
12. **36.9** F119 fix — WIT string return marshalling
13. **36.10** Documentation + cleanup

## Current Task

36.7A: VM reuse (WasmModule Vm cache).
- Add Vm pointer field to WasmModule
- Add Vm.reset() method
- Change invoke() to reuse cached Vm instead of creating new one each call
- Expected: 2-5x speedup on wasm_call benchmark

## Previous Task

36.6: SIMD benchmark + regression measurement.
Makefile updated: scalar + SIMD wasm variants. Benchmark script updated
to compare 4 configurations (native, wasmtime, CW-scalar, CW-SIMD).
vector_add: 2.58x speedup from SIMD. No regression in main benchmarks.
Recorded as entry 36.6 in bench/history.yaml.

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.
- F119 OPEN: WIT string return marshalling — returns accumulated memory
  (prior writes included in result string).

## Reference Chain

Session resume procedure: read this file → follow references below.

### Phase 35.5 (completed)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/plan/phase35.5-wasm-hardening.md`           |
| **E2E tests**                | `test/e2e/wasm/*.clj`, `test/e2e/run_e2e.sh`     |
| **Spec docs**                | `docs/wasm-spec-support.md`, `docs/wasi-support.md` |
| **SIMD benchmarks**          | `bench/simd/`, `bench/simd/results.md`            |
| **Wasm benchmarks**          | `bench/benchmarks/21-25_wasm_*/`                  |
| **Conformance tests**        | `src/wasm/testdata/conformance/` (9 WAT+WASM)     |

### Phase 35X (current)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/plan/phase35X-cross-platform.md`            |
| **NaN boxing decision**      | `.dev/notes/decisions.md` D85                     |
| **Checklist entry**          | `.dev/checklist.md` F117                          |
| **Roadmap section**          | `.dev/plan/roadmap.md` Phase 35X                  |

### Phase 35W (completed)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Detailed plan + tasks**    | `.dev/plan/phase35-custom-wasm.md`                |
| **Decision**                 | `.dev/notes/decisions.md` D84                     |
| **Custom runtime**           | `src/wasm/runtime/` (8 files, 5312 LOC)           |
| **Wasm types (rewritten)**   | `src/wasm/types.zig` (725 LOC, custom runtime)    |
| **Wasm builtins**            | `src/wasm/builtins.zig` (504 LOC, Clojure API)    |
| **Wasm test corpus**         | `src/wasm/testdata/` (12 .wasm files)             |
| **WIT parser**               | `src/wasm/wit_parser.zig` (443 LOC)               |

### Phase 36 (current)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/plan/phase36-simd-ffi.md`                   |
| **SIMD opcode reservation**  | `src/wasm/runtime/opcode.zig:271`                 |
| **VM extension point**       | `src/wasm/runtime/vm.zig:639`                     |
| **SIMD benchmarks**          | `bench/simd/` (4 programs + results.md)           |
| **Checklist entries**        | `.dev/checklist.md` F118, F119                    |

### Upcoming phases

| Phase | Plan                                              | Key reference                       |
|-------|---------------------------------------------------|-------------------------------------|
| 37    | GC + JIT research                                 | `.dev/plan/roadmap.md`              |

### Global references

| Topic              | Location                                 |
|--------------------|------------------------------------------|
| Roadmap            | `.dev/plan/roadmap.md`                   |
| Deferred items     | `.dev/checklist.md` (F113, F117, F118, F119) |
| Decisions          | `.dev/notes/decisions.md` (D1-D85)       |
| Optimization       | `.dev/notes/optimization-catalog.md`     |
| Benchmarks         | `bench/history.yaml`                     |
| Zig tips           | `.claude/references/zig-tips.md`         |

## Handover Notes

- **Phase 35X COMPLETE** — Cross-Platform Build & Verification
  - 35X.1: Linux x86_64 — NaN boxing redesign (D85), Docker verified
  - 35X.2: Linux aarch64 — Docker verified, 48-bit NaN boxing confirmed
  - 35X.3: macOS x86_64 — Rosetta 2 verified, 2.9MB binary
  - 35X.4: EPL-1.0 LICENSE file added
  - 35X.5: GitHub Actions CI (test-macos, test-linux, cross-compile 4 targets)
  - Binaries: Linux 14MB (static), macOS 2.9MB (dynamic)
- **Phase 35X.2 COMPLETE** — Linux aarch64 cross-compile + Docker verification
  - Zero compilation errors, Docker verification passed on first try
  - Binary: ELF aarch64, statically linked, 14MB
  - 48-bit NaN boxing (D85) confirmed working on real aarch64 Linux
- **Phase 35X.1 COMPLETE** — Linux x86_64 cross-compile + Docker verification
  - NaN boxing redesigned: 1-tag (40-bit) → 4-tag (48-bit) scheme (D85)
  - Tags: 0xFFF8/0xFFFA/0xFFFE/0xFFFF, 3-bit sub-type, 45-bit shifted addr
  - 8-byte alignment shift (universal Zig allocator guarantee)
  - Negative quiet NaN canonicalized in initFloat (top16 >= 0xFFF8 → positive NaN)
  - Docker verified: eval, file exec, build, http, wasm — all pass
  - Binary: ELF x86_64, statically linked, 14MB
- **Phase 35.5 COMPLETE** — Wasm Runtime Hardening
  - 35.5A: E2E test infrastructure (5 tests, run_e2e.sh, Zig integration tests)
  - 35.5B: docs/wasm-spec-support.md, docs/wasi-support.md
  - 35.5C: WASI 19→38/45 (84%), 8 conformance test files, memLoad fix
  - 35.5D: SIMD benchmarks (4 C programs, native/wasmtime/cljw comparison)
  - 35.5E: 5 Wasm benchmarks (21-25), baseline recorded in history.yaml
  - Bug fixes: loop branch label re-push, memLoad signedness (@bitCast)
- **Phase 35W COMPLETE** (D84): Custom Wasm runtime replacing zware
  - 35W.1-35W.2: Foundation (opcode, leb128, memory) — 1028 LOC
  - 35W.3-35W.5: Store, module decoder, instance — 1877 LOC
  - 35W.6: Switch-based VM, ~200 MVP opcodes — 1328 LOC
  - 35W.7: WASI Preview 1 (19 functions) — 1079 LOC
  - 35W.8: types.zig rewrite + build.zig cleanup, zero zware refs
  - 35W.9: All tests pass (80 Zig), end-to-end Clojure wasm verified
- **Phase 34 COMPLETE** (D83): Server mode & networking
- **Current namespaces**: clojure.core, clojure.string, clojure.edn,
  clojure.math, clojure.walk, clojure.template, clojure.test, clojure.set,
  clojure.data, clojure.repl, clojure.java.io, cljw.wasm, cljw.http, user
- **NaN boxing (D72→D85)**: 4-heap-tag scheme, 48-bit address, Value 8B.
- **Single binary**: Binary trailer `[cljw binary][source][u64 size]["CLJW"]`
- **nREPL/CIDER**: 14 ops. Start: `cljw --nrepl-server --port=0`
- **Bootstrap cache**: cache_gen.zig at build time, ~3ms startup.
