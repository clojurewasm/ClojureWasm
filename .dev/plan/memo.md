# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 32 complete (A, BE, B, C, CX, R, D, 20-32, 22b, 22c, 24.5)
- Coverage: 659 vars done across all namespaces (535/704 core, 44/45 math, 7/19 java.io, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 32 COMPLETE** — Build System & Startup Optimization (D81)
- **Phase 33 COMPLETE** — Namespace & Portability Design (F115, D82)
- **Phase 34 IN PROGRESS** — Server Mode & Networking (F116)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> ~~30~~ -> ~~31~~ -> ~~32 (build system)~~ -> ~~33 (namespace design)~~ -> **34 (server/networking)** -> 35 (cross-platform) -> 36 (FFI deep) -> 37 (GC/JIT research)

## Task Queue

Phase 33 — Namespace & Portability Design (F115)

  (Task Queue empty — Phase 33 complete)

## Task Queue

Phase 34 — Server Mode & Networking (F116)

- ~~34.1 nREPL flag passthrough in built binaries (./myapp --nrepl 7888)~~
- 34.2 TCP server foundation (Zig std.net, accept loop)
- 34.3 HTTP server (basic request/response, ring-compatible handler model)
- 34.4 HTTP client (cljw.http/get, cljw.http/post)
- 34.5 Stateful long-running process lifecycle (signal handling, graceful shutdown)

## Current Task

34.2 — TCP server foundation (Zig std.net, accept loop).

## Previous Task

34.1 — nREPL flag passthrough in built binaries.
- Built binaries accept `--nrepl [port]` flag
- Refactored nrepl.zig: startServer + startServerWithEnv + shared runServerLoop
- main.zig: parse --nrepl, filter from *command-line-args*, evalEmbeddedWithNrepl
- Verified: user namespaces accessible via nREPL, args filtered correctly

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
- **Current namespaces**: clojure.core, clojure.string, clojure.edn,
  clojure.math, clojure.walk, clojure.template, clojure.test, clojure.set,
  clojure.data, clojure.repl, clojure.java.io, cljw.wasm, user
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
- **Future design items** (F115-F117):
  - F115: Namespace naming strategy — clojure.* (JVM compat) vs cljw.* (unique).
  - F116: Long-running server + networking — nREPL in built binaries,
    HTTP server/client, stateful process support.
  - F117: Cross-platform — Zig cross-compile, CI matrix, ELF/PE trailer verify.
    Includes cljw build output binaries on other platforms.
