# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 32 complete (A, BE, B, C, CX, R, D, 20-32, 22b, 22c, 24.5)
- Coverage: 652 vars done across all namespaces (535/704 core, 44/45 math, 21/21 string, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 32 COMPLETE** — Build System & Startup Optimization (D81)
- **Phase 33 IN PROGRESS** — Namespace & Portability Design (F115)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> ~~30~~ -> ~~31~~ -> ~~32 (build system)~~ -> **33 (namespace design)** -> 34 (server/networking) -> 35 (cross-platform) -> 36 (FFI deep) -> 37 (GC/JIT research)

## Task Queue

Phase 33 — Namespace & Portability Design (F115)

- 33.2 Design namespace naming convention (D## decision) + implement renames
- 33.3 Add clojure.java.io compatibility layer (slurp/spit/reader/writer)
- 33.4 Add System interop routing (System/getenv, System/exit, System/nanoTime)
- 33.5 Portability test suite (code that runs on both JVM Clojure and cljw)

## Current Task

33.2 — Design namespace naming convention (D## decision) + implement renames.

Based on 33.1 audit (.dev/notes/namespace-audit.md):
- Naming convention: clojure.* (JVM compat), cljw.* (CW extensions)
- Rename `wasm` → `cljw.wasm`
- Extract clojure.repl from core.clj to separate namespace
- Fix vars.yaml staleness (done in 33.1 for math/edn)

## Previous Task

33.1 — Namespace audit. Deliverables:
- Created .dev/notes/namespace-audit.md with full comparison
- CW: 10 functional ns + user + wasm
- JVM Clojure: ~46 standard ns, Babashka: ~30 (clojure.* compat + babashka.*)
- Key gaps: clojure.java.io, clojure.java.shell, clojure.pprint, clojure.stacktrace
- Key issues: wasm→cljw.wasm rename, clojure.repl not a real ns
- Fixed vars.yaml: clojure.math 0→44 done, clojure.edn read-string marked done
- Total coverage: 652 vars across all namespaces

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.

## Handover Notes

- **Phase 32 architecture**: D81 in decisions.md
- **Phase 32 results**: 32.1 removed cljw compile, 32.2 build-time cache gen,
  32.3 startup ~3-4ms (was ~12ms), 32.4 multi-file require robustness,
  32.5 source bundling build with require resolution
- **Phase 33 context**: Babashka model researched (see optimization-catalog.md
  Section 7, and F115 in checklist.md). Babashka uses clojure.* for JVM-compat,
  babashka.* for extensions. Key issue: `wasm` ns should be `cljw.wasm`,
  IO/system interop needs clojure.java.io compat layer.
- **Current namespaces**: clojure.core, clojure.string, clojure.edn,
  clojure.math, clojure.walk, clojure.template, clojure.test, clojure.set,
  clojure.data, clojure.repl, wasm, user
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
