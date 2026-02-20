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

Phase 88B complete. All easy fixes done, baselines recorded.
Next: Phase B (Library namespaces → Zig builtins).

## Previous Task

88A-sweep: Upstream test stabilization (S.1-S.6 all DONE).

## Task Queue

```
Phase B: Library namespaces → Zig builtins (24 files, 7,739 lines → 0)
Phase C: Bootstrap pipeline elimination
Phase D: Directory & module refactoring
Phase E: Optimization (restore baselines)
--- After All-Zig ---
Phase 86: Distribution (PENDING)
Phase 89: Performance Optimization (PENDING)
Phase 90: JIT Expansion (PENDING)
```

## All-Zig Migration Context

User decision: Override audit deferral. Migrate ALL .clj to Zig (zero .clj in pipeline).
Strategy: Remove constraints → migrate everything → refactor directories → optimize.
Plan: `.dev/all-zig-plan.md` (Phases A-E). Benchmarks baseline: `83E-v2` in history.yaml.

## Known Issues (post-88B baselines)

Hard failures (individual execution):
- macros.clj: 8F (metadata propagation through syntax-quote)
- reducers.clj: 11F (CollFold protocol not implemented)
- spec.clj: 25E (spec.alpha largely unimplemented)
- test/clojure/numbers.clj: 3F (char type returns char not string)

State pollution in batch execution (pass individually):
- multimethods.clj: 36E in batch (defmethod leaks across tests)
- clojure_zip.clj: 17E in batch
- data.clj: 13E in batch

## Next Phase Queue

Phase B: Library namespaces → Zig. See `.dev/all-zig-plan.md`.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
- Architecture v2 design: `.dev/archive/interop-v2-design.md` (archived)
- Stale docs archived to `.dev/archive/` (9 files)
