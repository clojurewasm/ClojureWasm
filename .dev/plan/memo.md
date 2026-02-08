# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 34 complete (A, BE, B, C, CX, R, D, 20-34, 22b, 22c, 24.5)
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 32 COMPLETE** — Build System & Startup Optimization (D81)
- **Phase 33 COMPLETE** — Namespace & Portability Design (D82)
- **Phase 34 COMPLETE** — Server Mode & Networking (D83)
- **Phase 35W IN PROGRESS** — Custom Wasm Runtime (D84)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~30~~ -> ~~31~~ -> ~~32~~ -> ~~33~~ -> ~~34~~ -> **35W (custom wasm)** -> 35X (cross-platform) -> 36 (SIMD + FFI deep) -> 37 (GC/JIT)

## Task Queue

Phase 35W — Custom Wasm Runtime (D84)

- ~~35W.1 Foundation: opcode.zig + leb128.zig (~150 LOC)~~ DONE
- ~~35W.2 Memory: memory.zig — linear memory with pages, grow, read/write (~200 LOC)~~ DONE
- ~~35W.3 Store: store.zig — function registry, host functions, tables, globals (~250 LOC)~~ DONE
- 35W.4 Module decoder: module.zig — Wasm binary parser, sections 0-12 (~800 LOC)
- 35W.5 Instance: instance.zig — instantiation, invoke, getMemory (~400 LOC)
- 35W.6 VM: vm.zig — switch-based dispatch, ~200 opcodes (~1500 LOC)
- 35W.7 WASI: wasi.zig — 19 WASI Preview 1 functions (~500 LOC)
- 35W.8 Integration: update types.zig + build.zig, remove zware dep (~200 LOC change)
- 35W.9 Cleanup: verify all tests, update docs

## Current Task

35W.4 — Module decoder: module.zig — Wasm binary parser, sections 0-12.

## Previous Task

35W.3 — Store: store.zig — Function (wasm/host), Table, Global, Elem, Data,
Store with add/get/lookup/export. 12 store tests + 16 memory + 7 opcode pass.

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.

## Reference Chain

Session resume procedure: read this file → follow references below.

### Phase 35W (current)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Detailed plan + tasks**    | `.dev/plan/phase35-custom-wasm.md`                |
| **Decision**                 | `.dev/notes/decisions.md` D84                     |
| **Design principles**        | phase35-custom-wasm.md "Design Principles" section|
| **zware source (reference)** | add-dir: `Documents/OSS/zware/`                   |
| **Current Wasm types**       | `src/wasm/types.zig` (820 LOC, zware wrapper)     |
| **Current Wasm builtins**    | `src/wasm/builtins.zig` (504 LOC, Clojure API)    |
| **Wasm test corpus**         | `src/wasm/testdata/` (12 .wasm files)             |
| **WIT parser (no zware)**    | `src/wasm/wit_parser.zig` (443 LOC)               |

### Upcoming phases

| Phase | Plan                                              | Key reference                       |
|-------|---------------------------------------------------|-------------------------------------|
| 35X   | Cross-platform (Linux/Mac)                        | `.claude/plans/phase35-cross-platform-saved.md` |
| 36    | SIMD + FFI deep + multi-module                    | phase35-custom-wasm.md "Phase 36" + F118 |
| 37    | GC + JIT research                                 | `.dev/plan/roadmap.md`              |

### Key design decisions for 35W

1. **Switch-based dispatch** (not `.always_tail`) — cross-compile friendly
2. **External API zware-compatible** — minimal types.zig changes
3. **Internal ClojureWasm affinity** — host call optimization, error propagation,
   u64 stack compat, SIMD enum reservations
4. **Direct bytecode execution** (no IR) — simpler than zware's Rr
5. **SIMD deferred to Phase 36** — opcode enum reservations only in 35W

### Global references

| Topic              | Location                                 |
|--------------------|------------------------------------------|
| Roadmap            | `.dev/plan/roadmap.md`                   |
| Deferred items     | `.dev/checklist.md` (F113, F117, F118)   |
| Decisions          | `.dev/notes/decisions.md` (D1-D84)       |
| Optimization       | `.dev/notes/optimization-catalog.md`     |
| Benchmarks         | `bench/history.yaml`                     |
| Zig tips           | `.claude/references/zig-tips.md`         |

## Handover Notes

- **Phase 34 COMPLETE** (D83): Server mode & networking
  - 34.1: --nrepl flag passthrough in built binaries
  - 34.2+34.3: HTTP server (cljw.http/run-server, Ring-compatible)
  - 34.4: HTTP client (get/post/put/delete) using Zig std.http.Client
  - 34.5: Lifecycle management (SIGINT/SIGTERM, shutdown hooks, graceful exit)
  - 34.6: Fix :background opt parsing + set-handler! for live reload
- **Current namespaces**: clojure.core, clojure.string, clojure.edn,
  clojure.math, clojure.walk, clojure.template, clojure.test, clojure.set,
  clojure.data, clojure.repl, clojure.java.io, cljw.wasm, cljw.http, user
- **NaN boxing (D72)**: COMPLETE. Value 48B->8B.
- **Single binary**: Binary trailer `[cljw binary][source][u64 size]["CLJW"]`
- **nREPL/CIDER**: 14 ops. Start: `cljw --nrepl-server --port=0`
- **Bootstrap cache**: cache_gen.zig at build time, ~3ms startup.
