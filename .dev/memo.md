# ClojureWasm Development Memo

Session handover document. Read at session start.

## Note: Architecture v2 Plan (2026-02-20)

Major roadmap restructuring. Phases 83A-83E inserted before Phase 84.
Read `.dev/interop-v2-design.md` for full design rationale and approach.
Decision: D105. Roadmap: `.dev/roadmap.md` Phase Tracker.

Key changes:
- 83A: Exception System Unification (Exception. returns map, hierarchy, .getMessage)
- 83B: InterOp Architecture v2 (ClassDef registry, protocol dispatch)
- 83C: UTF-8 Codepoint Correctness (string ops use codepoints, not bytes)
- 83D: Handle Memory Safety (use-after-close detection, GC finalization)
- 83E: Core All-Zig Migration (all std-lib → Zig builtins, eliminate .clj bootstrap)

Phase 84 (Testing Expansion) now active. def/defn return var fixed.
compilation.clj 8/8 pass. 50 upstream test files, 41 pass.

## Note: zwasm v1.1.0 API Change (APPLIED)

zwasm `loadWasi()` default changed to `Capabilities.cli_default`.
CW updated to use `loadWasiWithOptions(..., .{ .caps = .all })` in `src/wasm/types.zig:82`.

## Note: Roadmap Restructured (2026-02-19)

- Phase 83 reduced to "Essential Documentation" (no book, no README enrichment)
- Phase 86 (Distribution/Homebrew) deferred to Tier 4
- Phase 91 (wasm_rt) marked DEFERRED
- v0.2.0 scope: GitHub Release with binaries (no Homebrew)

## Current State

- **All phases through 83 COMPLETE** (Essential Documentation)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 63 upstream test files (63/63 passing). 6/6 e2e. 14/14 deps e2e.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.25MB (wasm=true) / 3.68MB (wasm=false) ReleaseSafe. See `.dev/binary-size-audit.md`.
- Startup: 4.6ms (wasm=true) / 4.3ms (wasm=false). RSS: 7.4MB.
- Lazy bootstrap: D104. `-Dwasm=false`: D103.
- Java interop: `src/interop/` module (D101, to be superseded by D105/83B)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only. Libraries requiring heavy Java interop are out of scope.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (4.25MB macOS default, 3.68MB wasm=false)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).

## Current Task

Phase 88A: Correctness Sweep
88A.5: Implement extend-via-metadata for protocols

## Previous Task

Phase 88 DONE: v0.3.0 released (https://github.com/clojurewasm/ClojureWasm/releases/tag/v0.3.0)

## Task Queue

```
88A.1: Fix `is` macro instance? reporting bug (Small)
88A.2: Fix serialize.zig hierarchy var restore (Small)
88A.3: Fix test_fixtures.clj (Medium)
88A.4: Fix parallel/vars sequential state pollution (Medium)
88A.5: Implement extend-via-metadata for protocols (Medium-Large)
88A.6: Full regression verify 63/63 upstream pass (Small)
```

## 83E Audit Results & Scope Reduction

**Findings**:
- 778 Zig builtins already registered
- 432 defn + 123 defmacro in .clj bootstrap files
- 94.6% of core.clj defn are trivial (< 5 lines composition)
- Startup already 4.6-5.5ms with lazy bootstrap (D104)
- Binary already 4.44MB (4.5MB threshold)

**Decision**: Full All-Zig migration deferred. Reasons:
1. Startup already excellent (4.6ms) — minimal gain from migrating .clj
2. Binary size would exceed 4.5MB threshold with 400+ new Zig builtins
3. .clj functions are trivial compositions — not performance bottlenecks
4. Bytecode cache already eliminates parsing overhead
5. Maintenance cost of Zig > .clj for simple composition functions

**What stays**: Current hybrid architecture (Zig primitives + .clj composition)
is the optimal design. Consider targeted migration only if specific hot-path
functions are identified as bottlenecks through profiling.

## Known Issues (Phase 88A targets)

- ~~test_fixtures.clj: bootstrap eval error in use-fixtures~~ FIXED 88A.3 (HANDLERS_MAX 16→64, now 63/63 upstream pass)
- ~~is macro: bug with instance? special form~~ FIXED 88A.1 (analyzer now checks locals, runtime accepts symbols)
- ~~parallel.clj, vars.clj: state pollution~~ RESOLVED (was caused by HANDLERS_MAX overflow, fixed in 88A.3)
- ~~serialize.zig: hierarchy var not restored from bytecode cache~~ FIXED 88A.2 (resolve from env during deserialization)
- extend-via-metadata: not supported in defprotocol → 88A.5

## Next Phase Queue

After 84, proceed to Phase 85 (Library Compatibility Expansion).

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
- Design document for Architecture v2: `.dev/interop-v2-design.md`
- Phase 84: compilation.clj now 8/8 pass (def return type fixed)
