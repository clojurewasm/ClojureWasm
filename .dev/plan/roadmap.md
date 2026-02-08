# ClojureWasm Roadmap

## Overview

Full-scratch Clojure implementation in Zig. Dual backend (TreeWalk + VM).
Goal: Babashka-competitive startup, single binary distribution, behavioral compatibility.

**References**:

- `.dev/future.md` — Design document (SS sections)
- `.dev/plan/memo.md` — Session handover memo
- `.dev/checklist.md` — Deferred items (F## entries)
- `.dev/status/vars.yaml` — Var implementation tracking

## Completed Phases

| Phase | Summary                          | Key Deliverables                                       |
| ----- | -------------------------------- | ------------------------------------------------------ |
| 1     | Reader + Analyzer                | Value types, Tokenizer, Reader, Form, Node, Analyzer   |
| 2     | Native VM                        | Env, Namespace, Var, Compiler, VM, TreeWalk, --compare |
| 3     | Builtins + core.clj              | 110 builtins, core.clj bootstrap, defmacro             |
| 4     | Production readiness             | Multi-arity, destructuring, REPL, Wasm target (207KB)  |
| 5     | Benchmark system                 | 11 benchmarks, 5 categories, bench.yaml tracking       |
| 6     | Core library I                   | lazy-seq, apply, mapcat, concat, 40+ builtins          |
| 7     | Robustness + nREPL               | Error recovery, nREPL server, CIDER-compatible         |
| 8     | Refactoring                      | Directory restructure, code cleanup                    |
| 9     | Core library II                  | peek, pop, update, merge, juxt, partial, 50+ fns       |
| 9.5   | Infrastructure fixes             | VM loop/recur, fn_val dispatch, data model fixes       |
| 10    | VM correctness                   | VM-CoreClj interop, bytecodeCallBridge                 |
| 11    | Metadata system                  | meta, with-meta, vary-meta, Var metadata               |
| 12    | Zig foundation + SCI test port   | Tier 1 builtins complete, SCI tests (70/74 pass)       |
| 13    | clojure.string + core expansion  | 14 string fns, protocols, defrecord, lazy-cat          |
| 14    | Clojure upstream test foundation | clojure.test, walk, 8 test files ported (72 tests)     |
| 14.5  | Bug fix round                    | assoc vector, seq set, empty list eval, pop nil        |
| 15-23 | Test -> GC (see above)           | TDD, upstream porting, GC, test gaps                   |
| 24    | Optimization (Babashka parity)   | 20 benchmarks, CW wins 19/20, 1 tied                   |

**Stats**: 526/704 vars done (as of Phase 24)

## Phases

### Phase 15: Test-Driven Core Expansion

Port upstream Clojure tests, implement missing features as gaps are found.
TDD approach: port test → fail → implement → pass.

**Scope**: High-priority test files (macros, special, walk, set, string, keywords, etc.)
**Reference**: (test_file_priority.md removed — batches completed)

### Phase 15.5: Test Re-port with Dual-Backend Verification

Phase 14-15 test porting verified TreeWalk only, leading to SKIP + F## accumulation.
Re-port tests from scratch, running both VM and TreeWalk, fixing root causes.

**Policy**:

- Run all tests on both VM and TreeWalk (no single-backend verification)
- SKIP only for JVM-specific features (threading, reflection)
- Failure → investigate root cause → implement/fix (no workarounds)
- Use `--dump-bytecode` for VM debugging

**Scope**: Tests ported in Phase 14-15 (up to walk)
**Reference**: `.dev/plan/memo.md`

### Phase 16: Test Expansion & Bug Fix

Port remaining Batch 1 test files (clojure_set, string, keywords, other_functions,
metadata). Fix VM bugs (F76, F77) and implement missing core functions.

**Scope**: Test Batch 1 completion, VM bug fixes, missing predicates/seq fns
**Reference**: (test_file_priority.md removed)

### Phase 16.5: Test Batch 2 Port

Port remaining Batch 2 test files (multimethods, vars, volatiles, delays).
Continue dual-backend policy. Fix bugs found during porting.

**Scope**: Test Batch 2 (multimethods, vars, volatiles, delays)
**Reference**: `.dev/plan/memo.md`

### Phase 17: IO / System Namespace

File I/O, system functions via Zig std library.

**Scope**: slurp, spit, _in_, _out_, _err_, read-line, System/getenv, System/nanoTime
**Reference**: See "IO / System Namespace Strategy" in Phase Notes below

### Phase 17.5: Infrastructure Fix (SKIP Unblock)

Focused fix phase for cross-cutting infrastructure gaps that block large numbers
of test SKIPs. Addresses root causes rather than individual symptoms.

**Rationale**: Remaining SKIPs (~60) are dominated by infrastructure gaps, not
leaf features. Fixing these before further test porting dramatically improves
coverage quality. See analysis in checklist.md.

**Scope** (priority order):

1. **try/catch/throw** (~15 SKIPs unblocked) — Analyzer special forms, VM opcodes,
   TreeWalk handling, error/exception Value type. Largest single blocker.
2. **Destructuring fixes** (~10 SKIPs unblocked) — F58, F67-F74, F79.
   All in Analyzer destructuring code, fixable in concentrated pass.
3. **VM defmulti/defmethod opcodes** (F13) — Compiler + VM opcodes so
   multimethod tests pass on VM backend.

**Out of scope** (later phases): regex (#"..."), seq abstraction (F34),
infinite range (F48), _out_/_err_ dynamic vars (needs binding F85).

**Reference**: `.dev/checklist.md` F## items, test/clojure/\*.clj SKIP comments

### Phase 18: Test Batch 3 Port + Coverage Expansion

Port Batch 3 test files (numbers, def, fn, ns_libs — partial) plus expand
existing test files with assertions previously SKIPed in Phase 17.5.

**Prerequisite**: Phase 17.5 (try/catch and destructuring available)
**Reference**: (test_file_priority.md removed)

### Phase 18.5: Upstream Alignment

Replace simplified `UPSTREAM-DIFF` implementations with verbatim upstream Clojure
when all dependencies are available. Close gap between ClojureWasm and JVM Clojure.

**Scope**:

1. **Macro alignment** (F90, F92, F93, F94) — defn, doseq, condp, case, etc.
2. **Analyzer rewrite** (F89) — Route `System/`, `Math/` syntax to `__` builtins
3. **Delay proper type** (F91) — Map-based → dedicated Value type
4. **Remaining F## items** — Resolve items unblocked by Phase 17.5 infrastructure

**Procedure**:

1. `grep UPSTREAM-DIFF .dev/status/vars.yaml` — list all simplified vars
2. For each: check if deps now available → copy upstream → test → remove note
3. For Analyzer rewrite: add `System/` and `Math/` pattern matching in analyzer

**Prerequisite**: Phase 18 (tests provide regression safety)
**Reference**: F89-F94 in checklist.md, `.claude/rules/java-interop.md`

### Phase 19: Foundation Reset (Upstream Fidelity)

Eliminate test workarounds and build a foundation faithful to upstream
Clojure/SCI. Var expansion resumes after this foundation is solid.

**Sub-phases**:

- **A**: Audit & Document — vars.yaml full audit (405 done vars vs upstream)
- **B**: Fix Known Issues — F## items by test-porting impact
- **C**: Faithful Test Porting — upstream tests with CLJW markers (C1-C12 done)
- **CX**: Known Issue Resolution — resolve actionable F## items (inserted between C12 and C13)
- **C** (cont.): Resume test porting from C13

**Plan**: `.dev/plan/foundation-reset.md`
**Phase CX plan**: `.dev/plan/phase-cx-plan.md`
**Tracker**: `.dev/status/audit-progress.yaml`
**Rules**: `.claude/rules/test-porting.md`
**Reference**: `.claude/references/interop-patterns.md`

### Phase R: require / load / ns System

Full upstream-compatible namespace loading system. Enables multi-file
projects and `::alias/foo` keyword resolution via `:as` aliases.

**Scope**:

- `load` / `load-file` — ns name to file path resolution, read + eval
- `require` — file-based loading with `:as`, `:refer`, `:reload`
- `use` — file-based loading with refer-all
- `ns` macro — full `:require` / `:use` / `:import` clause support
- Classpath equivalent — configurable load path(s)
- Circular require detection
- `*loaded-libs*`, `*loading-verbosely*` vars

**Current state**: `require` / `use` work for pre-loaded namespaces only
(clojure.string, clojure.set, clojure.walk, etc.). No file loading.

**Prerequisite**: Phase 19 complete (solid core foundation)
**Reference**: Upstream `clojure/core.clj` (load, require, use, ns)

### Phase D: Parallel Expansion

New vars with test-first approach. Expand var coverage (412 → 500+).

**Scope**: Implement remaining Tier 1 (Zig builtins) and Tier 2 (pure Clojure)
vars with upstream tests. Mark Tier 3 (JVM-specific) as skip.

**Prerequisite**: Phase R complete (multi-file loading enables richer testing)
**Reference**: `.dev/status/vars.yaml`, `.claude/references/impl-tiers.md`

### Phase 20: Infrastructure Expansion (skip unblock)

Implement collection types currently marked skip. Enables more upstream
code to work verbatim and expands test porting coverage.

**Scope**:

1. **Transient collections** (~7 vars) — transient, persistent!, assoc!, conj!, etc.
   PersistentVector/Map mutable versions. Performance-critical for bulk builds.
2. **Chunked sequences** (~7 vars) — chunk, chunk-buffer, etc.
   Batch lazy-seq processing. Upstream map/filter assume chunked support.
3. **Sorted collections** (~4 vars) — sorted-map-by, sorted-set-by, subseq, rsubseq.
   Comparator-based sorted collections.

**Prerequisite**: Phase D complete
**Reference**: `.dev/status/vars.yaml` (skip entries with "type not implemented")

### Phase 21: Upstream Alignment (F94)

Replace 13 UPSTREAM-DIFF simplified implementations with verbatim upstream.
Improves correctness without changing external behavior.

**Scope**: All vars with UPSTREAM-DIFF notes in vars.yaml
**Quick check**: `grep UPSTREAM-DIFF .dev/status/vars.yaml`
**Reference**: F94 in checklist.md, `.claude/rules/java-interop.md`

### Phase 22: Test Porting Expansion

Port additional upstream test files to expand coverage.

**Scope**:
- multimethods, protocols, transducers
- java_interop (portable subset)
- Any other portable upstream test files

**Prerequisite**: Phase 20 (transient/chunked available widens testable surface)
**Reference**: `.claude/rules/test-porting.md`

### Phase 23: Production GC

Replace arena allocator with real garbage collector.

**Scope**: Semi-space or mark-sweep GC, safe points
**Triggers**: Long-running REPL, memory benchmarks exceed bounds
**Reference**: F2, F20 in checklist.md; .dev/future.md SS5

### Phase 22b: Test Porting Round 2

Post-GC test expansion. Port additional upstream test files that exercise
implemented features. Provides regression safety net before Optimization.

**Prerequisite**: Phase 23 (Production GC) complete

**Tier 1 — Port (existing features, no new implementation):**

| File              | Lines | Tests | Portable | Notes                      |
| ----------------- | ----- | ----- | -------- | -------------------------- |
| keywords.clj      |    31 |     1 |    100%  | Keyword creation & arity   |
| printer.clj       |   195 |    13 |     90%  | print/pr formatting        |
| errors.clj        |   119 |     7 |     85%  | Error/exception handling   |
| protocols.clj     |   721 |    25 |     60%  | defprotocol/deftype/extend |
| try_catch.clj     |    39 |     2 |     50%  | try/catch/finally          |
| test.clj          |   129 |    14 |    100%  | clojure.test framework     |
| test_fixtures.clj |    73 |     5 |    100%  | Test fixture mechanism     |
| fn.clj            |    55 |     1 |     50%  | Function edge cases        |

**Tier 2 — Port + implement (new namespace or feature needed):**

| File         | Lines | Tests | Needs               | Notes            |
| ------------ | ----- | ----- | ------------------- | ---------------- |
| math.clj     |   326 |    41 | clojure.math ns     | Largest test set |
| parse.clj    |   102 |     6 | parse-long/double   | Core parse fns   |
| data.clj     |    32 |     1 | clojure.data ns     | diff function    |
| ns_libs.clj  |     ? |    10 | ns/require edge cases | R1-R7 already done |
| repl.clj     |     ? |     7 | doc/source/dir fns  | REPL utilities   |

**Skip (JVM-only, 28 files):** agents, annotations, api, array_symbols, clearing,
clojure_xml, compilation, data_structures_interop, genclass, generated_\*,
generators, java_interop, main, method_thunks, ns_libs_load_later, parallel,
param_tags, pprint, reflect, refs, rt, run_single_test, serialization, server, streams

**Scope**: Tier 1 first (8 files, ~68 tests). Tier 2 if time permits.
**Reference**: `.claude/rules/test-porting.md`

### Phase 22c: Test Gap Resolution

Revive skipped tests where features are now implemented, port remaining
portable upstream test files, implement small missing features as needed.

**Gap analysis**: `.dev/plan/test-gap-analysis.md`

**Scope** (3 tiers):

- **Tier 1** (revive only): sorted-set/map tests across 4 files, map-entry?,
  partitionv, with-redefs, eval — features already done, tests still skipped
- **Tier 2** (small impl + port): find-keyword (F80), parse-uuid, edn.clj,
  try_catch.clj, ##Inf/##NaN print, with-var-roots helper
- **Tier 3** (medium impl + port): eduction, iteration, test.clj,
  test_fixtures.clj, ns_libs.clj, data.clj, protocols.clj partial

**Prerequisite**: Phase 22b complete
**Reference**: `.dev/plan/test-gap-analysis.md`

### Phase 24: Optimization

Performance optimization pass, benchmark-driven. Three sub-phases.

**Detailed plan**: `.dev/plan/phase24-optimization.md`
**Prerequisite**: Phase 22c (Test Gap Resolution) complete

#### Phase 24A: Speed Optimization

| Task  | Item                         | Expected impact              |
|-------|------------------------------|------------------------------|
| 24A.0 | Baseline measurement         | Add 9 benchmarks, profile    |
| 24A.1 | VM dispatch optimization     | 10-30% VM throughput         |
| 24A.2 | Stack argument buffer        | 2-5x reduce-heavy benchmarks |
| 24A.3 | Fused reduce                 | 10-100x lazy-seq benchmarks  |
| 24A.4 | Arithmetic fast-path         | 10-30% computation           |
| 24A.5 | Inline caching               | 2-5x protocol dispatch       |
| 24A.6 | Hash table bitmask           | Up to 2x hash lookups        |
| 24A.7 | Constant folding             | Moderate (compile-time eval) |
| 24A.8 | Superinstructions            | 5-15% general code           |

**Gate**: Beat Babashka on all comparable benchmarks.

#### Phase 24B: Memory Optimization

| Task  | Item                         | Expected impact              |
|-------|------------------------------|------------------------------|
| 24B.1 | NaN boxing (F1)              | Value: 48 -> 8 bytes (6x)   |
| 24B.2 | HAMT (F4)                    | O(log32 n) map operations    |
| 24B.3 | RRB-Tree (conditional)       | O(log32 n) vector operations |
| 24B.4 | GC tuning                    | Reduced pause times          |

#### Phase 24C: Portable Optimization (Babashka Parity)

All portable optimizations that benefit both native and wasm_rt.
Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory).

| Task  | Item                         | Target benchmarks                          |
|-------|------------------------------|--------------------------------------------|
| 24C.1 | Closure specialization       | lazy_chain, transduce, map_filter_reduce   |
| 24C.2 | Multimethod dispatch opt     | multimethod_dispatch                       |
| 24C.3 | String ops optimization      | string_ops                                 |
| 24C.4 | Collection ops optimization  | vector_ops, list_build                     |
| 24C.5 | GC optimization              | gc_stress, nested_update                   |
| 24C.6 | NaN boxing (D72)             | ALL benchmarks (cache locality)            |
| 24C.7 | F99 iterative realization    | deep lazy-seq chains, wasm prerequisite    |
| 24C.8 | Constant folding             | general improvement                        |

**Knowledge base**: `.claude/references/optimization-knowledge.md`
**Benchmark recording**: Record after every task with `bench/record.sh`.

### Phase 24.5: Mini-Refactor (Pre-Wasm Cleanup)

Quick code hygiene before Phase 25. NOT a large refactoring (that's Phase 27).

**Scope**:
1. Dead code removal — unused pub fns, stale imports, commented-out blocks
2. Naming consistency audit — public API naming conventions check
3. D3 violation audit — catalog all module-level mutable state (7+ sites)
4. File size documentation — measure, annotate future split candidates

**Non-scope**: No file splitting, no architecture changes.
**Prerequisite**: Phase 24 complete

### Phase 25: Wasm InterOp (FFI)

Call Wasm modules from native track. Use zware (pure Zig) as primary engine.

**Detailed plan**: `.dev/plan/phase25-wasm-interop.md`
**Prerequisite**: Phase 24.5 complete

**Sub-phases**:
| Sub   | Content                     | Deliverables                       |
|-------|-----------------------------|------------------------------------|
| 25.0  | Infrastructure setup        | zware dep, WAT test files          |
| 25.1  | wasm/load + wasm/fn         | Load .wasm, call with type hints   |
| 25.2  | Memory + String interop     | Linear memory read/write, UTF-8    |
| 25.3  | Host function injection     | Clojure fns callable from Wasm     |
| 25.4  | WASI Preview 1 basics       | fd_write, proc_exit, args/environ  |
| 25.5  | WIT parser + module objects | Auto-resolve exports from WIT      |

**Reference**: .dev/future.md SS1, SS4, SS6; WasmResearch repo

### Phase 26: wasm_rt Track — DEFERRED

Research complete (26.R). Implementation deferred pending Wasm ecosystem maturity.
See `src/wasm_rt/README.md` for revival conditions.
**Research archive**: `.dev/plan/phase26-wasm-rt.md`

### Phase 27: NaN Boxing (Value 48B → 8B)

Fundamental performance optimization. Affects VM stack, collections, GC, cache.

**Scope**: Staged migration of Value representation
**Prerequisite**: Phase 25 complete
**Key risk**: 600+ call sites across 30+ files. Staged API migration (D72).
**Reference**: .dev/notes/decisions.md D72

| Sub-phase | Description                                              |
|-----------|----------------------------------------------------------|
| 27.1      | Add Value accessor API layer (tag(), asInteger(), etc.)  |
| 27.2      | Migrate call sites file-by-file to new API               |
| 27.3      | Switch internal representation to NaN-boxed u64          |

### Phase 28: Single Binary Builder

`cljw build app.clj -o app` — embed user code in self-contained binary.

**Scope**: @embedFile user .clj, optional .wasm pre-linking
**Prerequisite**: Phase 27 (NaN boxing makes binaries smaller/faster)
**Reference**: .dev/plan/phase28-single-binary.md (to be created)

| Sub-phase | Description                                              |
|-----------|----------------------------------------------------------|
| 28.1      | Source embedding: user .clj baked into binary             |
| 28.2      | Wasm pre-linking: .wasm modules embedded via @embedFile   |
| 28.3      | AOT bytecode: pre-compile to bytecode chunks (F7)        |

### Phase 29: Codebase Restructuring

Directory reorganization: common/native/ → core/eval/cli/.

**Scope**:
- Directory restructuring: core/ (platform-free), eval/ (VM+TW+bootstrap), cli/
- File splitting (collections.zig 3696L, bootstrap.zig 3353L, vm.zig 2290L)
- D3 violation resolution (move module-level state into structs)
- Import path cleanup, naming normalization

**Prerequisite**: Phase 27 (single import rewrite pass after NaN boxing)

### Phase 30: Production Robustness

Error messages, stack traces, skip var recovery, nREPL/cider-nrepl, clojure.repl.

**Scope**:
- Error reporting: Babashka-quality stack traces, source context
- nREPL: cider-nrepl op compatibility (eval, complete, info, stacktrace)
- Zero-config project model: auto-detect src/, require resolution
- Skip var recovery: re-evaluate 178 skipped vars for Zig equivalents
- clojure.repl namespace: doc, apropos, source, dir, find-doc

**Status**: COMPLETE. 30.1 (error reporting) + 30.2 (nREPL/CIDER) +
30.3 (project model) + 30.4 (skip vars) + 30.5 (clojure.repl) all done.

### Phase 31: AOT Compilation

Resolve F7 (macro serialization) and enable bytecode pre-compilation.

**Scope**:
- F7 resolution: serialize macro bodies to bytecode-reconstructable form
- Bootstrap AOT: pre-compile core.clj to bytecode at build time
- User code AOT: compile user .clj to bytecode for Phase 28.3 embedding
- Startup time optimization: skip runtime parse+analyze for pre-compiled code

**Status**: COMPLETE. Bytecode format (serialize.zig), FnProto/Chunk serialization,
env snapshot/restore, bootstrap cache generation, compileToModule/runBytecodeModule.
**Reference**: optimization-backlog.md F7, phase28-single-binary.md 28.3

### Phase 32: Build System & Startup Optimization

Pre-compiled bootstrap for instant startup, clean user interface, multi-file
project support. Architecture decision: D81.

**Scope**:
- Remove `cljw compile` — bytecode is internal only, two user paths
- Build-time bootstrap cache generation via build.zig
- Startup switch from source parsing to cache restoration (~12ms → ~2ms)
- Multi-file require robustness (deep chains, circular detection, dedup)
- `cljw build` overhaul: require graph resolution + bytecode embedding

| Sub   | Content                                        | Deliverables                            |
|-------|------------------------------------------------|-----------------------------------------|
| 32.1  | Remove cljw compile, clean up bytecode exposure | Simplified main.zig, two user paths     |
| 32.2  | Build-time bootstrap cache generation          | cache_gen tool, build.zig integration   |
| 32.3  | Startup path switch to cache restoration       | ~6x faster startup, measured            |
| 32.4  | Multi-file require robustness                  | Deep chains, circular detect, dedup     |
| 32.5  | cljw build overhaul                            | Require resolution + bytecode embedding |

**Prerequisite**: Phase 31 (AOT serialization infrastructure)
**Reference**: D81 in decisions.md

### Phase 33: Advanced GC + JIT Research

Research phase for generational GC and JIT compilation feasibility.

**Scope**:
- Generational GC design: write barrier strategy, nursery sizing
- JIT compilation survey: trace JIT vs method JIT vs Cranelift backend
- Escape analysis (F103): local-only Values skip GC tracking
- Profile-guided optimization (F104): extend inline caching beyond monomorphic
- Design documents + PoC prototypes, not full implementation
- Full implementation in subsequent phases based on research findings

**Prerequisite**: Phase 32 (build system stable, AOT infrastructure informs JIT design)
**Note**: Both items require deep architectural changes. Design documents
and PoC first, full implementation in subsequent phases.

### Phase 34: Wasm FFI Deep (Phase 25 Extension)

Deepen Wasm InterOp with multi-module support and practical examples.

**Scope**: Multi-module linking, WIT-based type-safe FFI, real-world samples
**Prerequisite**: Phase 32 (single binary builder mature)

### Future: wasm_rt Revival

When ecosystem conditions are met (see `src/wasm_rt/README.md`),
revive Phase 26 using archived research in `.dev/plan/phase26-wasm-rt.md`.

---

## Phase Notes

Notes for future phases. Read these when planning that phase.

### Implementation Tier Reference

When implementing new functions, see `.claude/references/impl-tiers.md`.

| Tier | Location    | Criteria                               |
| ---- | ----------- | -------------------------------------- |
| 1    | Zig builtin | Low-level, hot path, perf-critical     |
| 2    | core.clj    | Pure Clojure, existing fn combinations |
| 3    | Skip        | JVM-specific (threading, reflection)   |
| 4    | Zig stub    | Dynamic vars, config                   |

### Test Porting Policy

When porting upstream Clojure tests, follow dual-backend policy:
run all tests on both VM and TreeWalk, SKIP only for JVM-specific features.

### IO / System Namespace Strategy

When implementing IO/system functionality:

- **Java interop exclusion**: `proxy`/`reify`/`gen-class` are JVM-specific — skip
- **Native aliases**: `slurp`/`spit` via Zig `std.fs`, `Thread/sleep` via `std.time.sleep`
- **`clojure.java.io`**: Provide as `clojure.java.io` (compatible) or `clojure.io` (clean).
  Could support both (alias one to the other). Decide when implementing.
- **System**: `System/getenv`, `System/nanoTime` via `tryJavaInterop` routing
  or `clojure.system` namespace. Decide when implementing.
- **Reference**: .dev/future.md SS11

### Upstream Alignment

→ **Promoted to Phase 18.5**. See Phases section above.

**Quick reference**: `grep UPSTREAM-DIFF .dev/status/vars.yaml`

### Optimization Phase

**Prerequisite**: Phase 22c (Test Gap Resolution) complete
**Detailed plan**: `.dev/plan/phase24-optimization.md`

| ID  | Item                     | Phase | Reference |
| --- | ------------------------ | ----- | --------- |
| F1  | NaN boxing               | 24B.1 | D1, SS5   |
| F21 | 3-layer separation       | 24A.3 | SS5       |
| F4  | Persistent DS (HAMT/RRB) | 24B.2 | D9        |

**Zig-native optimization strategy**:

- comptime function pointer table for VM dispatch (24A.1)
- Stack-local argument buffers instead of GC allocation (24A.2)
- Fused reduce: collapse lazy-seq chains at compile-time (24A.3, Beta: 27GB -> 2MB)
- NaN boxing: `@bitCast`, packed structs, 48->8 byte Value (24B.1)
- HAMT: `@popCount`, packed bits for population count (24B.2)

**Benchmark baseline** (Phase 10):

| Benchmark         | TreeWalk | VM    | Notes                    |
| ----------------- | -------- | ----- | ------------------------ |
| fib_recursive     | 494ms    | 54ms  | VM 9x faster             |
| arith_loop        | 840ms    | 213ms | VM 4x faster             |
| map_filter_reduce | 381ms    | 623ms | VM slower (hybrid issue) |

**Success criteria**: Beat Babashka on all comparable benchmarks after 24A.
Full targets in `.dev/plan/phase24-optimization.md` Section 8.

**Decision gate**: Phase 24C complete (all 20 benchmarks beat Babashka) -> Phase 25.

### Wasm InterOp (FFI)

**Prerequisite**: Phase 24.5 (Mini-Refactor) complete

FFI for calling Wasm modules from native track. Distinct from wasm_rt.
**Research**: WasmResearch repo — docs/, examples/wat/, examples/wit/
**Engine**: zware (pure Zig, MIT, Wasm 2.0 minus SIMD). Verify Zig 0.15.2 compat.
**Latest Wasm status** (research at Phase 25 start):
- WASI Preview 2 stabilization
- WasmGC (part of Wasm 3.0 draft)
- zware 0.15.2 compatibility
Beta has working implementation to reference.

**SS1 Phases** (from .dev/future.md):

| Phase | Content                    | Implementation                             |
| ----- | -------------------------- | ------------------------------------------ |
| 1     | Type-safe boundary         | `wasm/load`, `wasm/fn`, signature verify   |
| 2a    | WIT parse + module objects | WIT parser (Zig), ILookup for field access |
| 2b    | require-wasm macro         | ns system integration (optional)           |
| 3     | Component Model            | After WASI 1.0 stabilizes                  |

**Code example**:

```clojure
;; Phase 1: Manual signature
(def mod (wasm/load "math.wasm"))
(def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))
(add 1 2)  ;=> 3

;; Phase 2a: WIT auto-resolution
(def img (wasm/load-wit "resize.wasm"))
(img/resize-image buf 800 600)
```

**File layout**: `src/wasm/` (see .dev/future.md SS17.2)
**References**: .dev/future.md SS1, SS4, SS15

### wasm_rt Track

**Prerequisite**: Phase 25 (Wasm InterOp) complete

Compile entire runtime to `.wasm`, run on WasmEdge/Wasmtime.

| Aspect     | native               | wasm_rt                    |
| ---------- | -------------------- | -------------------------- |
| GC         | Self-impl semi-space | WasmGC delegate            |
| NaN boxing | Yes                  | Yes (f64 bit ops universal) |
| Distribute | Single binary        | .wasm file                 |

**Current status**: Stub (T4.13 verified 207KB wasm32-wasi binary)
**References**: .dev/future.md SS7
