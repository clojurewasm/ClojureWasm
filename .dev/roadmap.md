# ClojureWasm Roadmap

## Overview

Full-scratch Clojure implementation in Zig 0.15.2. Dual backend (TreeWalk + VM).
Goal: Babashka-competitive startup, single binary distribution, behavioral compatibility.

**References**:

- `.dev/future.md` — Design document (SS sections)
- `.dev/memo.md` — Session handover memo
- `.dev/checklist.md` — Deferred items (F## entries)
- `.dev/status/vars.yaml` — Var implementation tracking
- `private/alpha_plan/` — Multi-perspective Alpha planning docs

## Current Stats

- **835+ vars** implemented (635/706 core, 16 namespaces)
- **71 skip vars** remaining (70+ permanently JVM, ~1 implementable)
- **49 upstream test files**, all passing (44 upstream ports + 5 SCI)
- **31 benchmarks** (20 native + 5 wasm legacy + 4 wasm TinyGo + 2 GC)
- **Wasm engine**: zwasm v0.7.0 (Register IR + ARM64 JIT, 0.9-2.2x of wasmtime)

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
| 36     | Wasm FFI Deep                               | SIMD 236 opcodes, multi-module, interpreter opt (D86)       |
| 37     | VM Optimization + JIT PoC                   | Superinstrs, branch fusion, ARM64 JIT (D87), 17.7x         |
| 38     | Core Library Completeness                   | Exception handling (D88), Matcher, ns macro, defn align     |
| 39     | Real-World Usability                        | shell, pprint, line-seq, stacktrace                         |
| 40     | Library Expansion                           | zip (28), test (18), walk/math/repl remaining               |
| 41     | Polish & Hardening                          | Bug fixes, upstream test porting, edge cases                |
| 42     | Quick Wins + Protocol Extension             | uri?, uuid?, extend, extenders, bound-fn (skip recovery)    |
| 43     | Numeric Types + Arrays                      | Array, BigInt, BigDecimal, Ratio (D89), 34 array builtins   |
| 44     | OSS Release Prep                            | Lazy range, repo cleanup, docs, license, README             |
| 45     | Wasm Runtime Optimization                   | Predecoded IR, superinstrs, cached memory (2-3x)            |
| 46     | Correctness & Cleanup                       | F95 VM intrinsic ns, checklist cleanup                      |
| —      | zwasm Integration (D92)                     | External wasm engine, -9300 LOC, Register IR + ARM64 JIT    |
| 47-50B | Alpha DX + Compat + Bug fixes               | REPL, errors, case*, PushbackReader, upstream align, agents |
| 51     | Agent Subsystem                             | AgentObj, send/send-off, await, error modes, *agent*        |
| 52     | Quality & Alignment                         | println fix, catch types, is macro, test/reader port        |
| 53     | Hardening & pprint Tests                    | Loop destr, BigDec exp, colon symbols, pprint tests         |
```

---

## Release Roadmap

### v0.1.0-alpha — Developer Experience (Phase 47)

First public Alpha. Focus: make ClojureWasm pleasant to use for scripting.

| Sub  | Content                         | Priority | Notes                              |
|------|---------------------------------|----------|------------------------------------|
| 47.1 | REPL improvements               | MUST     | Multiline, color, ns prompt        |
| 47.2 | Error message improvements      | MUST     | Source context, better formatting  |
| 47.3 | case* compiler special form     | MUST     | Deferred from 38.4, compatibility  |
| 47.4 | with-in-str, io!, with-precision| SHOULD   | Missing quick-win vars             |
| 47.5 | Upstream test expansion         | SHOULD   | 5+ additional test files ported    |
| 47.6 | Reader validation hardening     | SHOULD   | Edge cases, malformed input        |

**Exit criteria**: "A Clojure developer can write non-trivial scripts comfortably"

### v0.2.0-alpha — Concurrency (Phase 48)

Enable parallel processing. Prerequisite: GC thread safety.

| Sub  | Content                         | Priority | Notes                              |
|------|---------------------------------|----------|------------------------------------|
| 48.1 | GC thread safety (D## needed)  | MUST     | Pin values across thread boundary  |
| 48.2 | Thread pool infrastructure      | MUST     | Zig std.Thread pool                |
| 48.3 | future, future-call, deref      | MUST     | 6 vars from skip-recovery Cat 5   |
| 48.4 | pmap, pcalls, pvalues           | MUST     | Parallel collection processing     |
| 48.5 | Multi-thread dynamic bindings   | SHOULD   | F6 — binding frame per thread      |
| 48.6 | nREPL ops expansion             | SHOULD   | test, macroexpand                  |

**Exit criteria**: `(pmap f coll)` works correctly, no GC crashes under concurrency

### v0.3.0-alpha — Compatibility (Phase 49)

Maximize Clojure code compatibility. Library testing.

| Sub  | Content                         | Priority | Notes                              |
|------|---------------------------------|----------|------------------------------------|
| 49.1 | PushbackReader + read           | SHOULD   | Enables clojure.edn/read, read    |
| 49.2 | Upstream alignment pass (F94)   | SHOULD   | Replace UPSTREAM-DIFF with verbatim|
| 49.3 | Pure Clojure library compat     | MUST     | Test 5+ popular libraries          |
| 49.4 | Additional upstream tests       | SHOULD   | Expand from 38 to 45+ test files   |
| 49.5 | Agent subsystem (partial)       | COULD    | If GC thread safety proves solid   |

**Exit criteria**: "Most pure Clojure code runs without modification"

### v0.4.0-beta — Ecosystem (Phase 50)

Build the ecosystem foundation. Dependency management, distribution.

| Sub  | Content                         | Priority | Notes                              |
|------|---------------------------------|----------|------------------------------------|
| 50.1 | deps.edn basic support          | MUST     | git/sha deps, :paths, :deps       |
| 50.2 | Wasm module deps                | SHOULD   | .wasm in deps graph                |
| 50.3 | cljw test command               | SHOULD   | Run tests from project             |
| 50.4 | Homebrew tap                    | SHOULD   | Easy macOS install                 |
| 50.5 | import → wasm mapping           | COULD    | F135, ClojureDart-like :import     |

**Exit criteria**: "Can manage multi-file projects with external dependencies"

### Quality & Alignment (Phase 52) — DONE

Test framework hardening, upstream alignment, and bug fixes.

- Fixed println/print/pr/prn/str/pr-str hang on infinite lazy seqs
- Implemented exception type checking in catch clauses
- Fixed `is` macro: try-expr pattern, test-ns-hook support
- Ported test.clj (10 tests, 41 assertions) and reader.cljc (22 tests, 117 assertions)
- Audited 32 UPSTREAM-DIFF markers
- 48 upstream test files, all passing on both backends

### v0.5.0-beta — Advanced Features (Phase 51)

Polish for production use.

| Sub  | Content                         | Priority | Notes                              |
|------|---------------------------------|----------|------------------------------------|
| 51.1 | spec.alpha (basic)              | SHOULD   | Core spec predicates, s/def, s/valid?|
| 51.2 | Generational GC                 | COULD    | Write barriers, nursery/tenured    |
| 51.3 | x86_64 JIT                      | COULD    | ARM64 JIT → x86_64 port           |
| 51.4 | Windows basic support           | COULD    | Cross-compile + CI                 |
| 51.5 | LSP foundation                  | COULD    | Completion, go-to-def              |

### v1.0.0 — Stable (Future)

- API freeze
- All platforms verified
- Comprehensive documentation
- Security audit
- Release cycle established

---

## Skip Var Summary

112 skip vars remaining in clojure.core:

| Category                 | Count | Status                                |
|--------------------------|-------|---------------------------------------|
| Permanently JVM          | ~70   | Never implement (class system, etc.)  |
| Future/pmap/pvalues      | 9     | Phase 48 — DONE                       |
| Agent                    | 17    | Phase 51 — DONE (13 impl, 4 JVM skip)|
| STM/Ref                  | 9     | OUT OF SCOPE (atom sufficient)        |
| read/PushbackReader      | 2     | Phase 49.1                            |
| import                   | 2     | Phase 50.5                            |
| Quick wins remaining     | 3     | Phase 47.4 (with-in-str, io!, etc.)   |

See `.dev/skip-recovery.md` for detailed breakdown.

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

### Concurrency Strategy (Phase 48)

- Zig `std.Thread` for thread pool — no need for green threads
- GC safety is the prerequisite: must pin roots across thread boundaries
- Dynamic bindings need per-thread binding frames (F6)
- Start with future/pmap (most useful), defer agent (complex error model)
- Reference: `.dev/skip-recovery.md` Category 2, 5
- Reference: `private/alpha_plan/10_concurrency.md`
