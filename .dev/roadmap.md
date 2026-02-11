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

```
| Phase  | Summary                                     | Key Deliverables                                            |
|--------|---------------------------------------------|-------------------------------------------------------------|
| 1      | Reader + Analyzer                           | Value types, Tokenizer, Reader, Form, Node, Analyzer        |
| 2      | Native VM                                   | Env, Namespace, Var, Compiler, VM, TreeWalk, --compare      |
| 3      | Builtins + core.clj                         | 110 builtins, core.clj bootstrap, defmacro                  |
| 4      | Production readiness                        | Multi-arity, destructuring, REPL, Wasm target               |
| 5      | Benchmark system                            | Benchmark suite, multi-language comparison                  |
| 6      | Core library I                              | lazy-seq, apply, mapcat, concat, 40+ builtins               |
| 7      | Robustness + nREPL                          | Error recovery, nREPL server, CIDER-compatible              |
| 8      | Refactoring                                 | Directory restructure, code cleanup                         |
| 9      | Core library II                             | peek, pop, update, merge, juxt, partial, 50+ fns            |
| 9.5    | Infrastructure fixes                        | VM loop/recur, fn_val dispatch, data model fixes            |
| 10     | VM correctness                              | VM-CoreClj interop, bytecodeCallBridge                      |
| 11     | Metadata system                             | meta, with-meta, vary-meta, Var metadata                    |
| 12     | Zig foundation + SCI test port              | Tier 1 builtins complete, SCI tests (70/74 pass)            |
| 13     | clojure.string + core expansion             | 14 string fns, protocols, defrecord, lazy-cat               |
| 14     | Clojure upstream test foundation            | clojure.test, walk, 8 test files ported (72 tests)          |
| 14.5   | Bug fix round                               | assoc vector, seq set, empty list eval, pop nil             |
| 15     | Test-driven core expansion                  | TDD, port upstream test → fail → implement → pass           |
| 15.5   | Dual-backend test re-port                   | Both VM + TreeWalk verified, root cause fixes               |
| 16     | Test Batch 1 + VM bug fix                   | clojure_set, string, keywords, metadata tests               |
| 16.5   | Test Batch 2                                | multimethods, vars, volatiles, delays                       |
| 17     | IO / System namespace                       | slurp, spit, *in*/*out*/*err*, System/getenv                |
| 17.5   | Infrastructure fix                          | try/catch/throw, destructuring fixes, VM defmulti           |
| 18     | Test Batch 3                                | numbers, def, fn, ns_libs tests                             |
| 18.5   | Upstream alignment                          | defn, doseq, condp, case macro alignment                    |
| 19     | Foundation reset                            | vars.yaml audit, faithful test porting (C1-C12+)            |
| R      | require / load / ns system                  | File-based loading, :as/:refer, circular detection          |
| D      | Parallel expansion                          | Var coverage 412 → 500+                                     |
| 20     | Infrastructure expansion                    | Transient collections, chunked sequences                    |
| 21     | Upstream alignment (F94)                    | UPSTREAM-DIFF → verbatim upstream                           |
| 22     | Test porting expansion                      | multimethods, protocols, transducers tests                  |
| 23     | Production GC                               | MarkSweepGc (D69), three-allocator architecture (D70)       |
| 22b    | Test porting round 2                        | Post-GC test expansion                                      |
| 22c    | Test gap resolution                         | Revive skipped tests, port remaining test files             |
| 24     | Optimization                                | 20 benchmarks, CW wins 19/20 vs Babashka                    |
| 24.5   | Mini-refactor                               | Dead code, naming, D3 audit                                 |
| 25     | Wasm InterOp (FFI)                          | wasm/load, wasm/fn, memory interop, host fns, WASI          |
| 26.R   | wasm_rt research                            | Research complete, implementation DEFERRED (D79)            |
| 30     | Production robustness                       | Error reporting, nREPL/CIDER, project model, clojure.repl   |
| 31     | AOT compilation                             | Bytecode serialization, env snapshot/restore                |
| 32     | Build system + startup                      | Bootstrap cache (D81), ~6x startup, cljw build              |
| 33     | Namespace design                            | clojure.* + cljw.* convention (D82)                         |
| 34     | Server mode + networking                    | cljw.http, Ring handler, nREPL in built binaries (D83)      |
| 35W    | Custom Wasm runtime                         | Replace zware, switch dispatch, 5300 LOC (D84)              |
| 35X    | Cross-platform                              | Linux x86_64/aarch64, CI, LICENSE (D85 NaN boxing)          |
| 36.1-4 | SIMD implementation                         | 236 SIMD v128 opcodes                                       |
| 36.5   | SIMD Clojure API                            | wasm/v128-*, type conversion, benchmark                     |
| 36.6   | SIMD benchmark                              | vector_add 2.58x speedup                                    |
| 36.7   | Wasm interpreter optimization               | VM reuse 7.9x, sidetable 1.44x (D86)                        |
| 36.8   | Multi-module linking                        | Cross-module function imports via wasm/load :imports        |
| 36.9   | F119 WIT string fix                         | ptr/len swap in callWithWitMarshalling                      |
| 36.10  | Documentation + cleanup                     | wasm-spec-support.md updated, Phase 36 complete             |
| 36.11  | Pre-JIT optimizations                       | F101 into transient, F102/SmallStr/Intern analyzed+deferred |
| 37.1   | Profiling infrastructure                    | Opcode frequency, allocation histogram, GC benchmarks       |
| 37.2   | Superinstructions                           | 10 fused opcodes, arith_loop 53→40ms (1.33x)                |
| 37.3   | Branch+loop fusion                          | 7 fused branch ops, arith_loop 40→31ms (1.29x)              |
| 37.4   | JIT PoC — ARM64 hot loops (D87)             | ARM64 native code gen, arith_loop 31→3ms (10.3x)            |
| 38.1   | thrown-with-msg? + exception handling (D88) | Infrastructure fixes, var_ref fixup, stack isolation        |
| 38.2   | Matcher Value type + re-matcher/re-groups   | NanHeapTag 28, re-find 1-arg, regex group extraction        |
| 38.3   | Upstream alignment (defn/defn-)             | defn/defn- metadata propagation fixed                       |
| 38.5   | ns macro enhancement                        | docstring, attr-map, :import no-op, set-ns-doc              |
| 39.1   | clojure.java.shell                          | sh, with-sh-dir, with-sh-env                                |
| 39.2   | clojure.pprint                              | pprint (Zig), print-table, format width specifiers          |
| 39.3   | line-seq                                    | File line-by-line reading (UPSTREAM-DIFF: takes path)       |
| 39.4   | clojure.stacktrace                          | root-cause, print-stack-trace, etc. (6 vars)                |
| 40.1   | clojure.zip (28 vars)                       | Upstream near-verbatim, fix & rest destructuring            |
| 40.3   | clojure.test expansion (18 vars)            | Dynamic vars, macros, runner functions                      |
| 40.4   | Walk/math/repl remaining (6 vars)           | postwalk-demo, random, demunge, root-cause                  |
| 41.1   | ex-cause fix + pprint dynamic vars (7 vars) | ex-cause, *print-right-margin*, etc.                        |
| 41.4   | Upstream test porting                       | control, sequences, transducers tests                       |
| 41.5   | Bug fixes and edge cases                    | try/catch peephole, sorted collections, take 0              |
| 42.1   | Quick wins (uri?, uuid?, destructure)       | with-in-str, seq-to-map-for-destructuring                   |
| 42.2   | Protocol extension API (5 vars)             | extend, extenders, extends?, find-protocol-*                |
| 42.3   | Remaining core vars (bound-fn)              | get-thread-bindings, bound-fn*, bound-fn                    |
| 43.1-4 | Array subsystem (34 builtins)               | ZigArray Value type, typed arrays, amap/areduce             |
| 43.5   | BigInt (pure Zig)                           | BigInt Value type, bigint/biginteger, reader N              |
| 43.6   | BigDecimal (pure Zig)                       | BigDecimal Value type, bigdec, reader M                     |
| 43.7   | Auto-promoting arithmetic                   | +', -', *', inc', dec' → overflow to BigInt                 |
| 43.8   | Ratio type                                  | Ratio Value type, numerator/denominator/rationalize         |
```

**Stats**: 795 vars done (593 clojure.core, 14+ namespaces total)

**Note**: Phase 27 (NaN Boxing) and Phase 28 (Single Binary Builder) from the
original plan were completed as part of Phases 35X (D85) and 31-32 (D81)
respectively. Phase 29 (Codebase Restructuring) remains deferred (F110).

## Current & Future Phases

### Phase 36 (cont.): Wasm FFI Deep

Remaining work from Phase 36:

| Sub    | Content                        | Status   |
|--------|--------------------------------|----------|
| 36.1-4 | SIMD opcodes (236 total)       | COMPLETE |
| 36.5   | SIMD Clojure API               | COMPLETE |
| 36.6   | SIMD benchmark                 | COMPLETE |
| 36.7   | Interpreter optimization (D86) | COMPLETE |
| 36.8   | Multi-module linking           | COMPLETE |
| 36.9   | F119 WIT string fix            | COMPLETE |
| 36.10  | Documentation + cleanup        | COMPLETE |

**Reference**: F118, F119 in checklist.md

### Phase 37: VM Optimization + JIT PoC — COMPLETE

Interpreter-level optimizations with JIT PoC for hot integer loops.

**Results** (cumulative from baseline 36.11):
- Superinstructions (37.2): 10 fused opcodes, arith_loop 53→40ms (1.33x)
- Branch+loop fusion (37.3): 7 fused branch ops, arith_loop 40→31ms (1.29x)
- JIT PoC (37.4): ARM64 native code gen, arith_loop 31→3ms (10.3x)
- **Total**: arith_loop 53→3ms (17.7x), fib_recursive 20→17ms (1.2x)
- 37.5 (Slab GC): SKIPPED — gc_stress 24ms < Java 31ms
- 37.6 (Escape analysis + IC): SKIPPED — remaining bottleneck is call/ret overhead

**Decisions**: D87 (JIT PoC architecture)

### Phase 38: Core Library Completeness — COMPLETE

| Sub  | Content                                     | Status   |
|------|---------------------------------------------|----------|
| 38.1 | thrown-with-msg? + exception handling (D88) | COMPLETE |
| 38.2 | Matcher Value type + re-matcher/re-groups   | COMPLETE |
| 38.3 | Upstream alignment (defn/defn- metadata)    | COMPLETE |
| 38.4 | case* compiler special form                 | DEFERRED |
| 38.5 | ns macro enhancement (:import, docstring)   | COMPLETE |

### Phase 39: Real-World Usability — COMPLETE

Critical scripting and development features for real-world usage.

| Sub  | Content                              | Status                                                          |
|------|--------------------------------------|-----------------------------------------------------------------|
| 39.1 | clojure.java.shell (sh)              | COMPLETE                                                        |
| 39.2 | clojure.pprint (pprint, print-table) | COMPLETE                                                        |
| 39.3 | line-seq                             | COMPLETE                                                        |
| 39.4 | clojure.stacktrace                   | COMPLETE                                                        |
| 39.5 | read / read-string                   | COMPLETE (read-string done, read skipped: needs PushbackReader) |

### Phase 40: Library Expansion — COMPLETE

| Sub  | Content                             | Status   |
|------|-------------------------------------|----------|
| 40.1 | clojure.zip (28 vars)               | COMPLETE |
| 40.2 | clojure.data (skip: protocols only) | COMPLETE |
| 40.3 | clojure.test expansion (18 vars)    | COMPLETE |
| 40.4 | clojure.walk/math/repl remaining    | COMPLETE |

### Phase 41: Polish & Hardening — COMPLETE

Bug fixes, edge cases, upstream test porting.

| Sub  | Content                            | Status                          |
|------|------------------------------------|---------------------------------|
| 41.1 | ex-cause fix + pprint dynamic vars | COMPLETE                        |
| 41.2 | clojure.edn/read                   | SKIPPED (needs PushbackReader)  |
| 41.3 | clojure.core.reducers              | SKIPPED (needs reify, ForkJoin) |
| 41.4 | Upstream test porting              | COMPLETE                        |
| 41.5 | Bug fixes and edge cases           | COMPLETE                        |

### Phase 42: Quick Wins + Protocol Extension — COMPLETE

SKIP recovery Phase 1. See `.dev/skip-recovery.md` for full context.

| Sub  | Content                                              | Status   |
|------|------------------------------------------------------|----------|
| 42.1 | Quick wins (with-in-str, uri?, uuid?, destructure)   | COMPLETE |
| 42.2 | Protocol extension API (extend, extenders, extends?) | COMPLETE |
| 42.3 | Remaining implementable core vars (bytes?, bound-fn) | COMPLETE |

### Phase 43: Numeric Types + Arrays — COMPLETE

New Value types: Array, BigInt, BigDecimal, Ratio. Decision D89.

| Sub    | Content                                       | Status   |
|--------|-----------------------------------------------|----------|
| 43.1-4 | Array ops, typed arrays, macros               | COMPLETE |
| 43.5   | BigInt + bigint/biginteger + reader N literal | COMPLETE |
| 43.6   | BigDecimal + bigdec + reader M literal        | COMPLETE |
| 43.7   | Auto-promotion (+', *', -', inc', dec')       | COMPLETE |
| 43.8   | Ratio + numerator/denominator/rationalize     | COMPLETE |

### Phase 44: OSS Release Prep — COMPLETE

v0.1.0-alpha release preparation.
**Master plan**: `private/20260208/02_oss_plan.md`

| Sub      | Category      | Content                                          | Status   |
|----------|---------------|--------------------------------------------------|----------|
| 44.1-2   | Lazy Range    | LazyRange Value, infinite range support          | COMPLETE |
| 44.3-8   | Wasm Speed    | Dispatch optimization, wasm benchmarks           | COMPLETE |
| 44.9-11  | Directory     | Remove wasm_rt, merge common/native, fix imports | COMPLETE |
| 44.12-15 | Refactoring   | Module doc comments, stale phase IDs, TODOs      | COMPLETE |
| 44.16-18 | License       | EPL-1.0 headers, copyright verification          | COMPLETE |
| 44.19-22 | Repo Cleanup  | .gitignore, CONTRIBUTING.md                      | COMPLETE |
| 44.23-25 | Documentation | README, ARCHITECTURE, DIFFERENCES                | COMPLETE |
| 44.26-30 | Release Prep  | GitHub config, badges, acknowledgments           | COMPLETE |

### Phase 45: Wasm Runtime Optimization — COMPLETE

Interpreter-level optimizations for wasm execution.

| Sub  | Content                                   | Status             |
|------|-------------------------------------------|--------------------|
| 45.1 | TinyGo benchmark infrastructure           | COMPLETE           |
| 45.2 | Predecoded IR (fixed-width 8-byte instrs) | COMPLETE           |
| 45.3 | Tail-call dispatch                        | SKIPPED (0% on M4) |
| 45.4 | Superinstructions (11 fused opcodes)      | COMPLETE           |
| 45.5 | Cached memory pointer                     | COMPLETE           |

**Results**: 2-3x cumulative improvement (fib 2.3x, sieve 3.0x, gcd 2.0x).
Remaining 7-65x gap to wasmtime is interpreter vs JIT fundamental limit.

### Phase 46: Correctness & Cleanup — COMPLETE

| Sub  | Content                                   | Status   |
|------|-------------------------------------------|----------|
| 46.1 | Fix F95 — VM intrinsic ns awareness       | COMPLETE |
| 46.2 | Checklist cleanup — remove resolved items | COMPLETE |

### zwasm Integration (D92)

Replaced internal wasm engine (Phase 35W, 9 files, ~9300 LOC) with zwasm as
external Zig path dependency. CW keeps thin bridge (`src/wasm/types.zig`).
Branch: `zwasm-integration`.

Benefits: -9300 LOC maintenance, inherits zwasm Register IR + ARM64 JIT + 99.9% spec.

### Phase 50+: Post-Release (deferred)

| Phase | Content                               | Notes                                   |
|-------|---------------------------------------|-----------------------------------------|
| 50    | Concurrency (future, pmap, agent)     | Zig std.Thread, GC safety. Was Phase 44 |
| 51    | import → wasm mapping                 | ClojureDart-like :import. Was Phase 45  |
| 52    | Generational GC                       | Nursery/tenured, profile-driven         |
| 53    | JIT expansion                         | Float, fn call, broader loop patterns   |
| 54    | Persistent data structures (HAMT/RRB) | F4, profile when collections bottleneck |

### Future: wasm_rt Revival

When ecosystem conditions are met, revive Phase 26 using archived research
in `.dev/archive/phase26-wasm-rt.md`. Mentioned in README.md Future Plans.

---

## Phase Notes

Notes for future phases. Read these when planning that phase.

### Implementation Tier Reference

When implementing new functions, see `.claude/references/impl-tiers.md`.

| Tier | Location    | Criteria                               |
|------|-------------|----------------------------------------|
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
