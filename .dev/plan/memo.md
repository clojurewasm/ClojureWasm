# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 31 complete (A, BE, B, C, CX, R, D, 20-31, 22b, 22c, 24.5)
- Coverage: 535/704 clojure.core vars done, 8 clojure.repl vars done
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 31 COMPLETE** — AOT Compilation (serialize.zig, bootstrap cache, bytecode module)
- **Phase 32 IN PROGRESS** — Build System & Startup Optimization (D81)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> ~~30~~ -> ~~31~~ -> **32 (build system)** -> 33 (GC/JIT research) -> 34 (FFI deep)

## Task Queue

Phase 32 — Build System & Startup Optimization (D81)

- 32.1 Remove `cljw compile` subcommand and standalone .cljc execution
- 32.2 Build-time bootstrap cache generation (build.zig cache generator)
- 32.3 Startup path switch to cache restoration + measurement
- 32.4 Multi-file require robustness verification and fixes
- 32.5 `cljw build` overhaul: bytecode embedding + require resolution

## Current Task

32.1 — Remove `cljw compile` subcommand and standalone .cljc execution.

User-facing paths are now two only:
- `cljw file.clj` — run source directly
- `cljw build file.clj -o app` — build single binary

Remove: handleCompileCommand, runBytecodeFile from main.zig.
Keep: compileToModule, runBytecodeModule (internal API for build),
      isBytecodeModule (binary trailer detection),
      runEmbeddedBytecode (built binary execution).

## Previous Task

31.5 — `cljw compile` command + bytecode embedding. Added:
- compileToModule(): compile source -> serialized bytecode Module
- runBytecodeModule(): deserialize + VM.run from bytecode bytes
- Embedded bytecode execution via runEmbeddedBytecode

## Known Issues

- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions. Not a correctness issue.

## Handover Notes

- **Phase 32 architecture**: D81 in decisions.md
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
  Format: [cljw binary] + [payload] + [u64 size] + "CLJW" magic.
- **macOS signing**: Ad-hoc resign with `codesign -s - -f` after build.
- **nREPL/CIDER**: Phase 30.2 complete. 14 ops. Start: `cljw --nrepl-server --port=0`
- **Var metadata**: doc/arglists propagated from defn->analyzer->DefNode->Var.
- **Bootstrap cache**: Phase 31.4 added generateBootstrapCache/restoreFromBootstrapCache.
  vmRecompileAll converts TreeWalk closures to bytecode for serialization.
  registerBuiltins() still required at startup (Zig fn pointers not serializable).
