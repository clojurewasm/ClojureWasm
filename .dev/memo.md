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

All-Zig Migration Phase A.1: Simple predicates & type utils → Zig builtins.
Plan: `.dev/all-zig-plan.md`. ~20 functions (boolean, true?, false?, some?, any?, ident?, etc.)
Non-functional thresholds SUSPENDED during Phase A-D (benchmarks ≤ 2x safety net only).

## Previous Task

83E-v2.1.7+1.8: Complex control flow + namespace/misc macros DONE.
Migrated 24 macros to Zig transforms. Only `ns` and `case` remain as .clj defmacros.
Total macro migration: 57 macros across 83E-v2.0-v2.1 (8 sub-tasks, 8 commits).
Formal benchmarks recorded: `bench/history.yaml` id="83E-v2".

## Task Queue

```
Phase A: Core functions → Zig builtins (core.clj 2,749 lines → 0)
  A.1: Simple predicates & type utils (~20 fn) ← CURRENT
  A.2: Arithmetic & comparison wrappers (~15 fn)
  A.3: Collection constructors & accessors (~20 fn)
  A.4: Sequence functions (~25 fn)
  A.5: Higher-order (memoize, trampoline, juxt, etc.) (~15 fn)
  A.6: String/print utilities (~10 fn)
  A.7: Transducer/reduce compositions (~15 fn)
  A.8: Hierarchy & multimethod helpers (~15 fn)
  A.9: Concurrency (~15 fn)
  A.10: Destructure, ex-info, special vars, remaining (~30 fn)
  A.11: `ns` macro → Zig transform
  A.12: `case` macro → Zig transform
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

## Known Issues (Phase 88A targets)

- ~~test_fixtures.clj: bootstrap eval error in use-fixtures~~ FIXED 88A.3 (HANDLERS_MAX 16→64, now 63/63 upstream pass)
- ~~is macro: bug with instance? special form~~ FIXED 88A.1 (analyzer now checks locals, runtime accepts symbols)
- ~~parallel.clj, vars.clj: state pollution~~ RESOLVED (was caused by HANDLERS_MAX overflow, fixed in 88A.3)
- ~~serialize.zig: hierarchy var not restored from bytecode cache~~ FIXED 88A.2 (resolve from env during deserialization)
- extend-via-metadata: not supported in defprotocol → 88A.5

## Next Phase Queue

Phase B (after A complete): Library namespaces → Zig. See `.dev/all-zig-plan.md`.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
- Architecture v2 design: `.dev/archive/interop-v2-design.md` (archived)
- Stale docs archived to `.dev/archive/` (9 files)
