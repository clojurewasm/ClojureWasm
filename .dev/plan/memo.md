# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 32 complete (A, BE, B, C, CX, R, D, 20-32, 22b, 22c, 24.5)
- Coverage: 535/704 clojure.core vars done, 8 clojure.repl vars done
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 32 COMPLETE** — Build System & Startup Optimization (D81)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> ~~30~~ -> ~~31~~ -> ~~32 (build system)~~ -> 33 (GC/JIT research) -> 34 (FFI deep)

## Task Queue

(empty — plan next phase)

## Current Task

Plan Phase 33.

## Previous Task

32.5 — `cljw build` overhaul: source bundling + require resolution. Changes:
- handleBuildCommand: bootstraps from cache, evaluates entry file to resolve
  all requires, tracks loaded files in depth-first order, concatenates
  deps (in load order) + entry source, embeds in binary trailer
- loadResource: records file content AFTER evaluation (not before) so nested
  deps are recorded first (depth-first: lib.util.math before lib.core)
- Content duped with infrastructure allocator before evaluation for safety
- Verified: multi-file project (4-level chain) and single file both work
- Build output: "Built: myapp (N bytes, 3 deps, source: M bytes)"

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.

## Handover Notes

- **Phase 32 architecture**: D81 in decisions.md
- **Phase 32 results**: 32.1 removed cljw compile, 32.2 build-time cache gen,
  32.3 startup ~3-4ms (was ~12ms), 32.4 multi-file require robustness,
  32.5 source bundling build with require resolution
- **Phase 31 (AOT)**: serialize.zig (bytecode format), bootstrap.zig
  (generateBootstrapCache/restoreFromBootstrapCache/compileToModule/runBytecodeModule)
- **Phase 30 plan**: .dev/plan/phase30-robustness.md
- **Phase 28 plan**: .dev/plan/phase28-single-binary.md
- **Roadmap**: .dev/plan/roadmap.md
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B->8B. 17 commits (27.1-27.4).
- **Single binary**: Binary trailer approach (Deno-style). No Zig needed on user machine.
  Format: [cljw binary] + [bundled source] + [u64 size] + "CLJW" magic.
  Multi-file: deps concatenated in depth-first load order + entry file.
- **macOS signing**: Ad-hoc resign with `codesign -s - -f` after build.
- **nREPL/CIDER**: Phase 30.2 complete. 14 ops. Start: `cljw --nrepl-server --port=0`
- **Var metadata**: doc/arglists propagated from defn->analyzer->DefNode->Var.
- **Bootstrap cache**: Phase 31.4 added generateBootstrapCache/restoreFromBootstrapCache.
  vmRecompileAll converts TreeWalk closures to bytecode for serialization.
  registerBuiltins() still required at startup (Zig fn pointers not serializable).
- **Build-time bootstrap**: cache_gen.zig generates cache at Zig build time,
  embedded via build.zig WriteFile+addAnonymousImport pattern.
  Startup: registerBuiltins (~<1ms) + restoreFromBootstrapCache (~2-3ms).
