# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5), bootstrap.last_thrown_exception, keyword_intern.table, collections._vec_gen_counter (24C.4), lifecycle.shutdown_requested/hooks (34.5), http_server.build_mode/background_mode/bg_server (34.2) — module-level, single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID   | Item                                         | Trigger                                                            |
| ---- | -------------------------------------------- | ------------------------------------------------------------------ |
| F3   | ~~Ratio type (`1/3`)~~                       | DONE: Phase 43.8 (subsumed by F132)                                |
| F4   | Persistent data structures (HAMT, RRB-Tree)  | Collection benchmarks show bottleneck                              |
| F6   | Multi-thread dynamic bindings                | Prerequisite for F133 (Future), native multi-thread target         |
| F94  | Upstream Alignment pass                      | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
| F95  | VM intrinsic ns awareness                    | :exclude of +,-,*,/ in refer-clojure ineffective on VM backend     |
| F99  | Iterative lazy-seq realization engine        | D74 fixes sieve. General recursion remains. See `optimizations.md` |
| F102 | map/filter chunked processing                | Phase 44 (OSS Prep): lazy range first, then chunked map/filter             |
| F103 | Escape analysis (local scope skip GC)        | Compiler detects local-only Values, skip GC tracking               |
| F104 | Profile-guided optimization (extend IC)      | Extend inline caching beyond monomorphic                           |
| F105 | JIT compilation                              | Future major phase — trace-based or method-based. See `optimizations.md` |
| F110 | Directory restructure (core/eval/cli)        | Phase 44 (OSS Prep): remove wasm_rt, merge common/native           |
| F120 | Native SIMD optimization (CW internals)      | Investigate Zig `@Vector` for CW hot paths. Profile first.         |
| F130 | ~~Array Value type + ops (35 vars)~~         | DONE: Phase 43.1-43.4                                             |
| F131 | ~~BigInt + BigDecimal (pure Zig)~~            | DONE: Phase 43.5-43.6                                             |
| F132 | ~~Ratio type + numerator/denominator~~       | DONE: Phase 43.8                                                   |
| F133 | Future + thread pool                         | Zig std.Thread, GC safety, deref timeout. Phase 44                 |
| F134 | ~~Protocol extension API~~                   | DONE: Phase 42.2                                                   |
| F135 | import → wasm mapping design                 | Explore ClojureDart-like :import for .wasm. Phase 45               |
| F136 | Wasm table.copy cross-table support          | Currently stub; needed for full bulk memory ops spec               |
| F137 | Wasm table.init implementation               | Currently stub; needed for element segment initialization          |
| F138 | ~~Wasm recursive call + memory access bug~~  | DONE: Label stack leak on function return — labels not cleaned up after popFrame |
