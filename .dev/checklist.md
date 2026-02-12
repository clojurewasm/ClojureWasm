# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Thread-safe (48.1)**: threadlocal (current_frame, macro_eval_env, predicates.current_env, last_thrown_exception, io capture/input stacks, active_vm, file_read_buf), atomic (_vec_gen_counter, gensym_counter), mutex (keyword_intern.table, prng, host_contexts, loaded_libs/loading_libs)
  - **Known exceptions**: lifecycle.shutdown_requested/hooks (34.5), http_server.build_mode/background_mode/bg_server (34.2) — module-level, init-once or single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID   | Item                                        | Trigger                                                                  |
|------|---------------------------------------------|--------------------------------------------------------------------------|
| F4   | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                                    |
| F94  | Upstream Alignment pass                     | Phase 54-55 done. Java static fields/methods/tests restored. Remaining: ~24 UPSTREAM-DIFF vars in vars.yaml (mostly permanent design diffs: protocol→fn, Java→Zig). |
| F99  | Iterative lazy-seq realization engine       | D74 fixes sieve. General recursion remains. See `optimizations.md`       |
| F102 | map/filter chunked processing               | Lazy range first, then chunked map/filter                                |
| F103 | Escape analysis (local scope skip GC)       | Compiler detects local-only Values, skip GC tracking                     |
| F104 | Profile-guided optimization (extend IC)     | Extend inline caching beyond monomorphic                                 |
| F105 | JIT compilation                             | Future major phase — trace-based or method-based. See `optimizations.md` |
| F120 | Native SIMD optimization (CW internals)     | Investigate Zig `@Vector` for CW hot paths. Profile first.               |
| F135 | import → wasm mapping design                | Explore ClojureDart-like :import for .wasm                               |
