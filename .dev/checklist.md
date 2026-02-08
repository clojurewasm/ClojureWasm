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
| F3   | Ratio type (`1/3`)                           | SCI tests fail on float precision loss                             |
| F4   | Persistent data structures (HAMT, RRB-Tree)  | Collection benchmarks show bottleneck                              |
| F6   | Multi-thread dynamic bindings                | Native multi-thread target                                         |
| F94  | Upstream Alignment pass                      | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
| F95  | VM intrinsic ns awareness                    | :exclude of +,-,*,/ in refer-clojure ineffective on VM backend     |
| F99  | Iterative lazy-seq realization engine        | D74 fixes sieve. General recursion remains. See `optimizations.md` |
| ~~F101~~ | ~~into() transient optimization~~        | **DONE**: into uses transient for vector/map/set targets. |
| F102 | map/filter chunked processing                | chunk.zig infra exists, map/filter don't use it. See `optimizations.md` |
| F103 | Escape analysis (local scope skip GC)        | Compiler detects local-only Values, skip GC tracking               |
| F104 | Profile-guided optimization (extend IC)      | Extend inline caching beyond monomorphic                           |
| F105 | JIT compilation                              | Future major phase — trace-based or method-based. See `optimizations.md` |
| F110 | Directory restructure (core/eval/cli)        | Phase 29 — common/native/ -> core/eval/cli/                        |
| ~~F113~~ | ~~nREPL GC integration~~                 | **DONE**: MarkSweepGc added to nREPL ServerState. GC collectIfNeeded after each eval. |
| ~~F118~~ | ~~Wasm FFI deep (Phase 36)~~              | **DONE**: SIMD 236 opcodes, optimization D86, multi-module, F119 fix, docs. |
| ~~F119~~ | ~~WIT string return marshalling~~        | **DONE**: Swapped ptr/len order in callWithWitMarshalling. |
| F120 | Native SIMD optimization (CW internals)      | Investigate Zig `@Vector` for CW hot paths. Profile first.         |
| ~~F121~~ | ~~Cross-language benchmark equivalence fixes~~ | **DONE**: 6/7 fixed. Only 05_map_filter_reduce deferred (minor). |
