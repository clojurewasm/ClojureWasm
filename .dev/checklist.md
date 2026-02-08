# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5), bootstrap.last_thrown_exception, keyword_intern.table, collections._vec_gen_counter (24C.4), lifecycle.shutdown_requested/hooks (34.5), http_server.build_mode/background_mode/bg_server (34.2) — module-level, single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID  | Item                                        | Trigger                                                            |
| --- | ------------------------------------------- | ------------------------------------------------------------------ |
| ~~F1~~  | ~~NaN boxing (Value optimization)~~     | Done: Phase 27, Value 48B→8B (D72). 33% faster, 53% less memory   |
| ~~F2~~  | ~~Real GC (replace arena)~~             | Done: Phase 23, MarkSweepGc (D69, D70)                            |
| F3  | Ratio type (`1/3`)                          | SCI tests fail on float precision loss                             |
| F4  | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                              |
| F6  | Multi-thread dynamic bindings               | Native multi-thread target                                        |
| ~~F7~~  | ~~Macro body serialization (AOT blocker)~~  | Done: Phase 31, vmRecompileAll converts TreeWalk closures to bytecode |
| ~~F20~~ | ~~Safe point GC design~~                | Done: Phase 23.4, VM/REPL safe points (D70)                       |
| F21 | 3-layer separation (Memory/Exec/Opt)        | Introduction of fused reduce or optimization pass                  |
| F24 | vars.yaml status refinement                 | When stub functions appear                                         |
| ~~F80~~ | ~~find-keyword function~~                | Done: 22c.5, keyword_intern.zig                                   |
| F94 | Upstream Alignment pass                     | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
| F95 | VM intrinsic ns awareness                   | :exclude of +,-,*,/ in refer-clojure ineffective on VM backend     |
| ~~F97~~ | ~~GC double-free in sieve benchmark~~    | Resolved: stack overflow from deep lazy-seq realization (512MB stack + meta tracing fix) |
| F98 | fib_recursive ReleaseFast anomaly            | 487ms Release > 205ms Debug — investigate Zig optimizer interaction |
| F99 | Iterative lazy-seq realization engine       | D74 fixes sieve. General recursion remains. Not critical for Phase 26 MVP (26.R.4: 8MB stack sufficient). See optimization-backlog.md |
| F101 | into() transient optimization              | into uses reduce+conj, could use transient. See optimization-backlog.md   |
| F102 | map/filter chunked processing              | chunk.zig infra exists, map/filter don't use it. See optimization-backlog.md |
| F103 | Escape analysis (local scope skip GC)      | Compiler detects local-only Values, skip GC tracking                       |
| F104 | Profile-guided optimization (extend IC)    | Extend inline caching beyond monomorphic                                   |
| F105 | JIT compilation                            | Future major phase — trace-based or method-based. See optimization-backlog.md |
| ~~F100~~ | ~~nested_update regression from hot bootstrap~~ | Resolved: adding update-in/assoc-in/get-in to hot_core_defs recovered 72→40ms (24C.5c) |
| ~~F96~~ | ~~VM protocol compilation~~             | Done: defprotocol/extend-type in compiler.zig + vm.zig + bootstrap.zig |
| ~~F106~~ | ~~Single binary builder (`cljw build`)~~ | Done: Phase 28.1, binary trailer approach (source embedding)           |
| ~~F107~~ | ~~cider-nrepl op compatibility~~       | Done: Phase 30.2, 14 ops including stacktrace, info, eldoc            |
| ~~F108~~ | ~~Skip var recovery pass~~             | Done: Phase 30.4, letfn/with-open/tagged-literal/with-local-vars      |
| ~~F109~~ | ~~Zero-config project model~~          | Done: Phase 30.3, auto-detect src/, require resolution, cljw.edn      |
| F110 | Directory restructure (core/eval/cli)      | Phase 29 — common/native/ -> core/eval/cli/                            |
| ~~F111~~ | ~~GC trace NaN-boxed heap pointers~~   | RESOLVED — bootstrap Symbols tracked in Env.owned_symbols, freed at deinit    |
| ~~F112~~ | ~~nREPL Var corruption (ArenaAllocator)~~ | RESOLVED — Env.init(gpa) + eval_arena removed. See D80 for root cause analysis |
| F113 | nREPL GC integration                      | Without GC, transient Values accumulate in GPA (same as main.zig REPL). Add MarkSweepGc to nREPL for true long-session memory management. |
| ~~F114~~ | ~~clojure.repl namespace~~            | Done: Phase 30.5, doc/dir/apropos/find-doc/source/pst + Var meta synthesis |
| ~~F115~~ | ~~Namespace naming strategy~~ | Done: Phase 33 (D82). clojure.* for JVM compat, cljw.* for extensions. wasm→cljw.wasm, clojure.repl extracted, clojure.java.io compat layer added, System/getProperty added. Portability test suite passes (0 diff with JVM Clojure 1.12). |
| ~~F116~~ | ~~Long-running server mode + networking~~ | Done: Phase 34 (D83). nREPL passthrough, HTTP server/client, graceful shutdown with signal handling. |
| F117 | Cross-platform build (Phase 35X)             | Mac + Linux only (Windows excluded). Cross-compile cljw, verify `cljw build` on ELF, CI matrix. Phase 35W complete (zware removed). Saved plan: `.claude/plans/phase35-cross-platform-saved.md`. |
| F118 | Wasm SIMD (v128) + FFI deep (Phase 36)       | ~100 SIMD opcodes (Zig `@Vector`), multi-module linking, ClojureWasm-native API. Enables near-native C/Rust .wasm execution. See `.dev/plan/phase35-custom-wasm.md` Phase 36 section. |
| F119 | WIT string return marshalling                   | `wasm/fn` with WIT returns accumulated memory (prior writes included in result). Affects `greet` string return — returns all linear memory from offset 0. Fix: use returned (ptr, len) pair to slice result correctly. |
