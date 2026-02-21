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
- 68 upstream test files (68/68 passing individually). 6/6 e2e. 14/14 deps e2e.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.25MB (wasm=true) / 3.68MB (wasm=false) ReleaseSafe. See `.dev/binary-size-audit.md`.
- Startup: 4.6ms (wasm=true) / 4.3ms (wasm=false). RSS: 7.4MB.
- Lazy bootstrap: D104. `-Dwasm=false`: D103.
- Java interop: `src/interop/` module (D101, to be superseded by D105/83B)

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

Core philosophy:
- **Zero embedded Clojure**: No .clj in processing pipeline. All vars are Zig builtins.
- **1 NS = 1 File**: Each lib/*.zig is self-contained (definition + implementation).
- **Behavioral compat**: Upstream .clj is reference for behavior, not structure.
  Zig implementations may optimize freely.
- **Upstream traceability**: Clojure NS/var → Zig file:function mapping is always clear.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (4.25MB macOS default, 3.68MB wasm=false)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).

## Current Task

Phase B.15b: spec.alpha → Zig (1789 lines).
Migrate clojure.spec.alpha from @embedFile .clj to Zig builtins.
B.15a complete: spec.gen.alpha (52 builtins + 5 macros) and core.specs.alpha (1 builtin).
ns_loader.zig fixed to use registerNamespace() for full registration (post_register, macros, vars).

## Previous Task

Phase F: 1NS=1File Consolidation (D108) — COMPLETE.
- Merged 18 ns_*.zig into lib/*.zig (4 batches: F.1-F.4)
- Only ns_ops.zig remains (core namespace operations, not a library NS)
- Each lib/*.zig is now self-contained: NamespaceDef + full implementation
- Cross-dependencies resolved (core_protocols exports used by data, datafy, java_io, collections)

## Task Queue

```
Phase B.15: spec/alpha → Zig (next)
Phase B.16: pprint → Zig (2732 lines)
--- After Phase B ---
Phase C: Bootstrap pipeline elimination (zero evalString)
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

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3, with resolution timeline).

P0: I-001, I-002, I-003 all RESOLVED in 88C.
P1: I-010 RESOLVED in 88C.
P1 (fix in Phase B): finally catch (I-011), watch/validator catch (I-012).
P2 (fix in Phase B): syntax-quote metadata (I-020), CollFold (I-021), spec (I-022), pointer cast (I-023-024).
P3 (Phase B+ organic): UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Next Phase Queue

Phase B: Library namespaces → Zig. See `.dev/all-zig-plan.md`.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
- Architecture v2 design: `.dev/archive/interop-v2-design.md` (archived)
- Stale docs archived to `.dev/archive/` (9 files)
