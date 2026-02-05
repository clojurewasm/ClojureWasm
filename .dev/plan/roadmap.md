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

**Stats**: 405/712 vars done (as of Phase 19)

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

Performance optimization pass, benchmark-driven.

**Scope**: NaN boxing (F1), fused reduce (F21), persistent DS (F4), inline caching
**Prerequisite**: Phase 22b (Test Porting Round 2) complete
**Reference**: See "Optimization Phase" in Phase Notes below; bench/README.md

### Phase 25: Wasm InterOp (FFI)

Call Wasm modules from native track.

**Scope**: wasm/load, wasm/fn, WIT parser, Component Model
**Prerequisite**: Phase 24 (Optimization) complete
**Reference**: See "Wasm InterOp" in Phase Notes below; .dev/future.md SS1, SS4

### Phase 26: wasm_rt Track

Compile entire runtime to Wasm.

**Scope**: WasmGC delegate, wasm32-wasi target
**Prerequisite**: Phase 25 (Wasm InterOp) complete
**Reference**: See "wasm_rt Track" in Phase Notes below; .dev/future.md SS7

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

**Prerequisite**: Phase 23 (Production GC) complete

| ID  | Item                     | Trigger                            | Reference |
| --- | ------------------------ | ---------------------------------- | --------- |
| F1  | NaN boxing               | fib(30) < 500ms or memory pressure | D1, SS5   |
| F21 | 3-layer separation       | Fused reduce without GC coupling   | SS5       |
| F4  | Persistent DS (HAMT/RRB) | Collection benchmarks bottleneck   | D9        |

**Targets**:

1. NaN boxing — Value representation (f64 bit tricks), native track only
2. Fused reduce — Collapse map/filter/reduce chains (Beta: 27GB → 2MB)
3. Inline caching — Protocol method calls, keyword lookup

**Benchmark baseline** (Phase 10):

| Benchmark         | TreeWalk | VM    | Notes                    |
| ----------------- | -------- | ----- | ------------------------ |
| fib_recursive     | 494ms    | 54ms  | VM 9x faster             |
| arith_loop        | 840ms    | 213ms | VM 4x faster             |
| map_filter_reduce | 381ms    | 623ms | VM slower (hybrid issue) |

Target: VM outperforms TreeWalk on all benchmarks.

### Wasm InterOp (FFI)

**Prerequisite**: Phase 24 (Optimization) complete

FFI for calling Wasm modules from native track. Distinct from wasm_rt.
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
| NaN boxing | Yes                  | No (Wasm JIT incompatible) |
| Distribute | Single binary        | .wasm file                 |

**Current status**: Stub (T4.13 verified 207KB wasm32-wasi binary)
**References**: .dev/future.md SS7
