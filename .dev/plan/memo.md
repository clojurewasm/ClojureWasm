# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 35W complete (A, BE, B, C, CX, R, D, 20-34, 22b, 22c, 24.5, 35W)
- **Phase 35.5 IN PROGRESS** — Wasm Runtime Hardening, Testing & Benchmarking
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~30~~ -> ~~31~~ -> ~~32~~ -> ~~33~~ -> ~~34~~ -> ~~35W~~ -> **35.5 (wasm hardening)** -> 35X (cross-platform) -> 36 (SIMD + FFI deep) -> 37 (GC/JIT)

## Task Queue

Phase 35.5 plan: `.dev/plan/phase35.5-wasm-hardening.md`

- 35.5A.2: Add e2e regression check to CLAUDE.md iteration loop
- 35.5A.3: Add wasm-specific Zig integration tests
- 35.5C.1: Implement high-priority WASI functions (8 functions)
- 35.5C.2: Implement medium-priority WASI functions (~11 functions)
- 35.5C.3: Add Wasm 2.0 conformance tests
- 35.5C.4: Update documentation with expanded coverage
- 35.5D.1: Install toolchain and create C benchmark programs
- 35.5D.2: Compile variants and create benchmark runner
- 35.5D.3: Run benchmarks and document results
- 35.5E.1: Create wasm runtime micro-benchmarks
- 35.5E.2: Create wasm compute benchmarks
- 35.5E.3: Record baseline and document

## Current Task

35.5A.1 COMPLETE + B.1 COMPLETE + B.2 COMPLETE.
Created e2e test infrastructure (5 tests, run_e2e.sh script).
Fixed Wasm VM loop branch bug (branchTo didn't re-push loop label).
Created docs/wasm-spec-support.md and docs/wasi-support.md.
Next: 35.5A.2 (CLAUDE.md update) + 35.5A.3 (Zig integration tests).

## Previous Task

35W.9 — Cleanup: verify all tests (80 pass), update docs (phase35-custom-wasm.md,
roadmap.md, checklist.md, memo.md). End-to-end Clojure-level wasm verification:
add(3+4=7), fib(10=55, 20=6765), memory store/load — all work.
Phase 35W summary: 8 runtime files (5312 LOC), types.zig rewrite (725 LOC),
zero zware references, all tests pass.

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.
- F119 OPEN: WIT string return marshalling — returns accumulated memory
  (prior writes included in result string).

## Reference Chain

Session resume procedure: read this file → follow references below.

### Phase 35.5 (in progress)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/plan/phase35.5-wasm-hardening.md`           |
| **E2E tests**                | `test/e2e/wasm/*.clj`, `test/e2e/run_e2e.sh`     |
| **Spec docs**                | `docs/wasm-spec-support.md`, `docs/wasi-support.md` |

### Phase 35X (after 35.5)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Saved plan**               | `.claude/plans/phase35-cross-platform-saved.md`   |
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

### Upcoming phases

| Phase | Plan                                              | Key reference                       |
|-------|---------------------------------------------------|-------------------------------------|
| 35X   | Cross-platform (Linux/Mac)                        | `.claude/plans/phase35-cross-platform-saved.md` |
| 36    | SIMD + FFI deep + multi-module                    | phase35-custom-wasm.md "Phase 36" + F118 |
| 37    | GC + JIT research                                 | `.dev/plan/roadmap.md`              |

### Global references

| Topic              | Location                                 |
|--------------------|------------------------------------------|
| Roadmap            | `.dev/plan/roadmap.md`                   |
| Deferred items     | `.dev/checklist.md` (F113, F117, F118, F119) |
| Decisions          | `.dev/notes/decisions.md` (D1-D84)       |
| Optimization       | `.dev/notes/optimization-catalog.md`     |
| Benchmarks         | `bench/history.yaml`                     |
| Zig tips           | `.claude/references/zig-tips.md`         |

## Handover Notes

- **Phase 35.5 IN PROGRESS** — Wasm Runtime Hardening
  - 35.5A.1: E2E test infrastructure (5 tests, run_e2e.sh, VM+TreeWalk pass)
  - 35.5B.1: docs/wasm-spec-support.md (Wasm 2.0 partial, 225 opcodes)
  - 35.5B.2: docs/wasi-support.md (19/45, prioritized not-implemented)
  - Bug fix: Wasm VM loop branch — branchTo must re-push loop label
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
- **NaN boxing (D72)**: COMPLETE. Value 48B->8B.
- **Single binary**: Binary trailer `[cljw binary][source][u64 size]["CLJW"]`
- **nREPL/CIDER**: 14 ops. Start: `cljw --nrepl-server --port=0`
- **Bootstrap cache**: cache_gen.zig at build time, ~3ms startup.
