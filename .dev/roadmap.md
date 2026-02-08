# ClojureWasm Roadmap

## Overview

Full-scratch Clojure implementation in Zig 0.15.2. Dual backend (TreeWalk + VM).
Goal: Babashka-competitive startup, single binary distribution, behavioral compatibility.

**References**:

- `.dev/future.md` — Design document (SS sections)
- `.dev/memo.md` — Session handover memo
- `.dev/checklist.md` — Deferred items (F## entries)
- `.dev/status/vars.yaml` — Var implementation tracking

## Completed Phases

| Phase | Summary                          | Key Deliverables                                       |
| ----- | -------------------------------- | ------------------------------------------------------ |
| 1     | Reader + Analyzer                | Value types, Tokenizer, Reader, Form, Node, Analyzer   |
| 2     | Native VM                        | Env, Namespace, Var, Compiler, VM, TreeWalk, --compare |
| 3     | Builtins + core.clj              | 110 builtins, core.clj bootstrap, defmacro             |
| 4     | Production readiness             | Multi-arity, destructuring, REPL, Wasm target          |
| 5     | Benchmark system                 | Benchmark suite, multi-language comparison              |
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
| 15    | Test-driven core expansion       | TDD, port upstream test → fail → implement → pass      |
| 15.5  | Dual-backend test re-port        | Both VM + TreeWalk verified, root cause fixes           |
| 16    | Test Batch 1 + VM bug fix        | clojure_set, string, keywords, metadata tests          |
| 16.5  | Test Batch 2                     | multimethods, vars, volatiles, delays                  |
| 17    | IO / System namespace            | slurp, spit, *in*/*out*/*err*, System/getenv           |
| 17.5  | Infrastructure fix               | try/catch/throw, destructuring fixes, VM defmulti      |
| 18    | Test Batch 3                     | numbers, def, fn, ns_libs tests                        |
| 18.5  | Upstream alignment               | defn, doseq, condp, case macro alignment               |
| 19    | Foundation reset                 | vars.yaml audit, faithful test porting (C1-C12+)       |
| R     | require / load / ns system       | File-based loading, :as/:refer, circular detection     |
| D     | Parallel expansion               | Var coverage 412 → 500+                                |
| 20    | Infrastructure expansion         | Transient collections, chunked sequences               |
| 21    | Upstream alignment (F94)         | UPSTREAM-DIFF → verbatim upstream                      |
| 22    | Test porting expansion           | multimethods, protocols, transducers tests             |
| 23    | Production GC                    | MarkSweepGc (D69), three-allocator architecture (D70)  |
| 22b   | Test porting round 2             | Post-GC test expansion                                 |
| 22c   | Test gap resolution              | Revive skipped tests, port remaining test files         |
| 24    | Optimization                     | 20 benchmarks, CW wins 19/20 vs Babashka               |
| 24.5  | Mini-refactor                    | Dead code, naming, D3 audit                            |
| 25    | Wasm InterOp (FFI)               | wasm/load, wasm/fn, memory interop, host fns, WASI     |
| 26.R  | wasm_rt research                 | Research complete, implementation DEFERRED (D79)        |
| 30    | Production robustness            | Error reporting, nREPL/CIDER, project model, clojure.repl |
| 31    | AOT compilation                  | Bytecode serialization, env snapshot/restore            |
| 32    | Build system + startup           | Bootstrap cache (D81), ~6x startup, cljw build         |
| 33    | Namespace design                 | clojure.* + cljw.* convention (D82)                    |
| 34    | Server mode + networking         | cljw.http, Ring handler, nREPL in built binaries (D83) |
| 35W   | Custom Wasm runtime              | Replace zware, switch dispatch, 5300 LOC (D84)         |
| 35X   | Cross-platform                   | Linux x86_64/aarch64, CI, LICENSE (D85 NaN boxing)     |
| 36.1-4| SIMD implementation              | 236 SIMD v128 opcodes                                  |
| 36.5  | SIMD Clojure API                 | wasm/v128-*, type conversion, benchmark                |
| 36.6  | SIMD benchmark                   | vector_add 2.58x speedup                               |
| 36.7  | Wasm interpreter optimization    | VM reuse 7.9x, sidetable 1.44x (D86)                  |

**Stats**: 659/704 core vars done (535 clojure.core, 14 namespaces total)

**Note**: Phase 27 (NaN Boxing) and Phase 28 (Single Binary Builder) from the
original plan were completed as part of Phases 35X (D85) and 31-32 (D81)
respectively. Phase 29 (Codebase Restructuring) remains deferred (F110).

## Current & Future Phases

### Phase 36 (cont.): Wasm FFI Deep

Remaining work from Phase 36:

| Sub   | Content                          | Status      |
|-------|----------------------------------|-------------|
| 36.1-4| SIMD opcodes (236 total)         | COMPLETE    |
| 36.5  | SIMD Clojure API                 | COMPLETE    |
| 36.6  | SIMD benchmark                   | COMPLETE    |
| 36.7  | Interpreter optimization (D86)   | COMPLETE    |
| 36.8  | Multi-module linking             | TODO        |
| 36.9  | F119 WIT string fix              | TODO        |
| 36.10 | Documentation + cleanup          | TODO        |

**Reference**: F118, F119 in checklist.md

### Phase 37: Advanced GC + JIT Research

Research phase for generational GC and JIT compilation feasibility.

**Scope**:
- Generational GC design: write barrier strategy, nursery sizing
- JIT compilation survey: trace JIT vs method JIT vs Cranelift backend
- Escape analysis (F103): local-only Values skip GC tracking
- Profile-guided optimization (F104): extend inline caching beyond monomorphic
- Design documents + PoC prototypes, not full implementation

**Wasm interpreter JIT targets** (post-36.7 optimization):
- wasm_fib: 7.7s → target ~0.5s with JIT (vs wasmtime ~0.02ms)
- wasm_sieve: 792ms → target ~50ms

**Prerequisite**: Phase 36 complete
**Note**: Design documents and PoC first, full implementation in subsequent phases.

### Phase 29: Codebase Restructuring (deferred)

Directory reorganization: common/native/ → core/eval/cli/.

**Scope**:
- Directory restructuring: core/ (platform-free), eval/ (VM+TW+bootstrap), cli/
- File splitting (collections.zig, bootstrap.zig, vm.zig)
- D3 violation resolution (move module-level state into structs)
- Import path cleanup, naming normalization

**Status**: Deferred (F110). Will be scheduled when needed.

### Future: wasm_rt Revival

When ecosystem conditions are met (see `src/wasm_rt/README.md`),
revive Phase 26 using archived research in `.dev/archive/phase26-wasm-rt.md`.

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
See `.claude/rules/test-porting.md` for full rules.

### IO / System Namespace Strategy

When implementing IO/system functionality:

- **Java interop exclusion**: `proxy`/`reify`/`gen-class` are JVM-specific — skip
- **Native aliases**: `slurp`/`spit` via Zig `std.fs`, `Thread/sleep` via `std.time.sleep`
- **`clojure.java.io`**: Provided as `clojure.java.io` (compatible, Babashka model)
- **System**: `System/getenv`, `System/nanoTime` via `tryJavaInterop` routing
- **Reference**: .dev/future.md SS11
