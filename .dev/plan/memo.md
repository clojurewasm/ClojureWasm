# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 34 complete (A, BE, B, C, CX, R, D, 20-34, 22b, 22c, 24.5)
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 32 COMPLETE** — Build System & Startup Optimization (D81)
- **Phase 33 COMPLETE** — Namespace & Portability Design (F115, D82)
- **Phase 34 COMPLETE** — Server Mode & Networking (F116, D83)
- **Phase 35W NEXT** — Custom Wasm Runtime (replace zware dependency)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> ~~30~~ -> ~~31~~ -> ~~32~~ -> ~~33~~ -> ~~34~~ -> **35W (custom wasm)** -> 35X (cross-platform) -> 36 (FFI deep) -> 37 (GC/JIT)

## Task Queue

Phase 35W — Custom Wasm Runtime (D84)

- 35W.1 Foundation: opcode.zig + leb128.zig (~150 LOC)
- 35W.2 Memory: memory.zig — linear memory with pages, grow, read/write (~200 LOC)
- 35W.3 Store: store.zig — function registry, host functions, tables, globals (~250 LOC)
- 35W.4 Module decoder: module.zig — Wasm binary parser, sections 0-12 (~800 LOC)
- 35W.5 Instance: instance.zig — instantiation, invoke, getMemory (~400 LOC)
- 35W.6 VM: vm.zig — switch-based dispatch, ~200 opcodes (~1500 LOC)
- 35W.7 WASI: wasi.zig — 19 WASI Preview 1 functions (~500 LOC)
- 35W.8 Integration: update types.zig + build.zig, remove zware dep (~200 LOC change)
- 35W.9 Cleanup: verify all tests, D84 decision entry, update docs

## Current Task

(Awaiting approval — Phase 35W plan at `.dev/plan/phase35-custom-wasm.md`)

## Previous Task

34.6 — Fix run-server :background option and add set-handler! for live reload.
- Parse :background from opts map (was module-level only)
- Add set-handler! builtin for live handler replacement
- Per-request handler resolution from __handler Var
- README.md comprehensive rewrite (Phase 34 features)

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.

## Handover Notes

- **Phase 32 architecture**: D81 in decisions.md
- **Phase 32 results**: 32.1 removed cljw compile, 32.2 build-time cache gen,
  32.3 startup ~3-4ms (was ~12ms), 32.4 multi-file require robustness,
  32.5 source bundling build with require resolution
- **Phase 33 COMPLETE** (D82): Namespace naming convention + portability
  - clojure.* for JVM compat, cljw.* for extensions
  - wasm → cljw.wasm rename, clojure.repl extracted to separate ns
  - clojure.java.io compat layer (7 builtins: file, delete-file, make-parents, etc.)
  - System/getProperty with 9 native property mappings
  - Portability test suite: 2/2 PASS (0 diff with JVM Clojure 1.12)
  - vars.yaml audit: 659 vars done (was 535+8, fixed clojure.math/edn staleness)
- **Phase 34 COMPLETE** (D83): Server mode & networking
  - 34.1: --nrepl flag passthrough in built binaries
  - 34.2+34.3: HTTP server (cljw.http/run-server, Ring-compatible)
    - Blocking/background/build modes, thread per connection
    - Live reload via nREPL: HTTP + nREPL simultaneous operation
  - 34.4: HTTP client (get/post/put/delete) using Zig std.http.Client
  - 34.5: Lifecycle management (SIGINT/SIGTERM, shutdown hooks, graceful exit)
  - 34.6: Fix :background opt parsing + set-handler! for live reload
- **Phase 35W plan**: `.dev/plan/phase35-custom-wasm.md`
  - Replace zware with custom Wasm runtime (~3900 LOC)
  - Switch-based dispatch (no .always_tail — cross-compile friendly)
  - Wasm MVP + WASI Preview 1 (19 functions)
  - Same public API as zware (minimal types.zig changes)
- **Cross-platform plan (saved)**: `.claude/plans/phase35-cross-platform-saved.md`
  - After 35W: Linux verification, CI, LICENSE as Phase 35X
- **Current namespaces**: clojure.core, clojure.string, clojure.edn,
  clojure.math, clojure.walk, clojure.template, clojure.test, clojure.set,
  clojure.data, clojure.repl, clojure.java.io, cljw.wasm, cljw.http, user
- **Benchmark (Phase 32)**: bench/history.yaml entry "32". Startup ~3-4ms
  (C/Zig level). Cross-lang comparison in optimization-catalog.md Section 7.5.
- **Phase 31 (AOT)**: serialize.zig (bytecode format), bootstrap.zig
  (generateBootstrapCache/restoreFromBootstrapCache/compileToModule/runBytecodeModule)
- **Roadmap**: .dev/plan/roadmap.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B->8B. 17 commits (27.1-27.4).
- **Single binary**: Binary trailer approach (Deno-style). No Zig needed on user machine.
  Format: [cljw binary] + [bundled source] + [u64 size] + "CLJW" magic.
  Multi-file: deps concatenated in depth-first load order + entry file.
- **nREPL/CIDER**: Phase 30.2 complete. 14 ops. Start: `cljw --nrepl-server --port=0`
- **Bootstrap cache**: cache_gen.zig generates cache at Zig build time,
  embedded via build.zig WriteFile+addAnonymousImport pattern.
  Startup: registerBuiltins (~<1ms) + restoreFromBootstrapCache (~2-3ms).
- **Future design items** (F117):
  - F117: Cross-platform — Zig cross-compile, CI matrix, ELF/PE trailer verify.
    Includes cljw build output binaries on other platforms.
