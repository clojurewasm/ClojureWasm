# ClojureWasm Roadmap

## Overview

Full-scratch Clojure implementation in Zig. Dual backend (TreeWalk + VM).
Goal: Babashka-competitive startup, single binary distribution, behavioral compatibility.

**References**:

- `.dev/future.md` — Design document (SS sections)
- `.dev/plan/memo.md` — Current task and session state
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

**Stats**: 269/704 vars done, 156 Zig builtins, 110+ core.clj fns

## Phases

### Phase 15: Test-Driven Core Expansion

Port upstream Clojure tests, implement missing features as gaps are found.
TDD approach: port test → fail → implement → pass.

**Scope**: High-priority test files (macros, special, walk, set, string, keywords, etc.)
**Reference**: `.dev/notes/test_file_priority.md` (Batch 1-3 ordering)

### Phase 15.5: Test Re-port with Dual-Backend Verification

Phase 14-15 test porting verified TreeWalk only, leading to SKIP + F## accumulation.
Re-port tests from scratch, running both VM and TreeWalk, fixing root causes.

**Policy**:

- Run all tests on both VM and TreeWalk (no single-backend verification)
- SKIP only for JVM-specific features (threading, reflection)
- Failure → investigate root cause → implement/fix (no workarounds)
- Use `--dump-bytecode` for VM debugging

**Scope**: Tests ported in Phase 14-15 (up to walk)
**Reference**: `.dev/plan/memo.md` Current Phase section

### Phase 16: IO / System Namespace

File I/O, system functions via Zig std library.

**Scope**: slurp, spit, _in_, _out_, _err_, read-line, System/getenv, System/nanoTime
**Reference**: See "IO / System Namespace Strategy" in Phase Notes below

### Phase 17: Production GC

Replace arena allocator with real garbage collector.

**Scope**: Semi-space or mark-sweep GC, safe points
**Triggers**: Long-running REPL, memory benchmarks exceed bounds
**Reference**: F2, F20 in checklist.md; .dev/future.md SS5

### Phase 18: Optimization

Performance optimization pass, benchmark-driven.

**Scope**: NaN boxing (F1), fused reduce (F21), persistent DS (F4), inline caching
**Prerequisite**: Phase 17 (Production GC) complete
**Reference**: See "Optimization Phase" in Phase Notes below; bench/README.md

### Phase 19: Wasm InterOp (FFI)

Call Wasm modules from native track.

**Scope**: wasm/load, wasm/fn, WIT parser, Component Model
**Reference**: See "Wasm InterOp" in Phase Notes below; .dev/future.md SS1, SS4

### Phase 20: wasm_rt Track

Compile entire runtime to Wasm.

**Scope**: WasmGC delegate, wasm32-wasi target
**Prerequisite**: Phase 19 (Wasm InterOp) complete
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

When porting upstream Clojure tests, see memo.md "Long-term Reference" section
for JVM dependency handling (categories, porting rules, implicit assumptions).

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

After Tier 1-2 implementation stabilizes, replace `UPSTREAM-DIFF` tagged
definitions in core.clj with verbatim upstream Clojure definitions.

**Query**: `grep UPSTREAM-DIFF .dev/status/vars.yaml`
**Procedure**: Verify deps available → copy upstream → test → remove UPSTREAM-DIFF note

### Optimization Phase

**Prerequisite**: Phase 17 (Production GC) complete

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

**Prerequisite**: Optimization phase complete

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

**Prerequisite**: Wasm InterOp (SS1 Phase 1-2) complete

Compile entire runtime to `.wasm`, run on WasmEdge/Wasmtime.

| Aspect     | native               | wasm_rt                    |
| ---------- | -------------------- | -------------------------- |
| GC         | Self-impl semi-space | WasmGC delegate            |
| NaN boxing | Yes                  | No (Wasm JIT incompatible) |
| Distribute | Single binary        | .wasm file                 |

**Current status**: Stub (T4.13 verified 207KB wasm32-wasi binary)
**References**: .dev/future.md SS7
