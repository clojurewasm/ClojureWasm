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
| F94  | Upstream Alignment pass                     | ~38 UPSTREAM-DIFF markers remain — mostly permanent design diffs (protocol→fn, Java→Zig). No further alignment expected. |
| F99  | Iterative lazy-seq realization engine       | D74 fixes sieve. General deep lazy-seq + apply-on-infinite still deferred. See `optimizations.md` |
| F102 | map/filter chunked processing               | Chunked types exist, range is lazy. Optimization: use chunks in map/filter pipelines. |
| F103 | Escape analysis (local scope skip GC)       | Compiler detects local-only Values, skip GC tracking                     |
| F104 | Profile-guided optimization (extend IC)     | Extend inline caching beyond monomorphic                                 |
| F105 | JIT compilation (expand beyond ARM64 PoC)   | ARM64 hot-loop JIT done (Phase 37.4, D87). Future: x86_64 port, expand beyond integer loops. |
| F120 | Native SIMD optimization (CW internals)     | Investigate Zig `@Vector` for CW hot paths. Profile first.               |
| F135 | import → wasm mapping design                | Explore ClojureDart-like :import for .wasm                               |
| F138 | binding *ns* + read-string                  | `(binding [*ns* ...] (read-string "::foo"))` — reader doesn't see runtime *ns*. Needs reader↔runtime dynamic var bridge. |
