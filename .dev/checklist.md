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
| F94  | Upstream Alignment pass                     | Phase 70.5.4 audit: 87 markers in src/clj/ (P=48, S=12, R=27). R items need: :inline meta (2), IDrop (2), IReduceInit/deftype (3), TransformerIterator (1), seqkvreduce (1), extend-via-metadata (2), deftype (3), ref/multimethod in test (7), spec in repl (1), assert-expr (1), run-test (1), :__reify_type (1). |
| F99  | ~~Iterative lazy-seq realization engine~~   | RESOLVED (D96): VM FRAMES_MAX 256→1024, iterative unwrapping in realize. Thunk depth ~1000, Meta path unlimited. |
| F102 | map/filter chunked processing               | Chunked types exist, range is lazy. Optimization: use chunks in map/filter pipelines. |
| F103 | Escape analysis (local scope skip GC)       | Compiler detects local-only Values, skip GC tracking                     |
| F104 | Profile-guided optimization (extend IC)     | Extend inline caching beyond monomorphic                                 |
| F105 | JIT compilation (expand beyond ARM64 PoC)   | ARM64 hot-loop JIT done (Phase 37.4, D87). Future: x86_64 port, expand beyond integer loops. |
| F120 | Native SIMD optimization (CW internals)     | Investigate Zig `@Vector` for CW hot paths. Profile first.               |
| F135 | ~~import → wasm mapping design~~            | RESOLVED: `:import-wasm` ns macro expands to `(def alias (cljw.wasm/load path))`. |
| F138 | ~~binding *ns* + read-string~~              | RESOLVED: readStringFn (and all read fns) now use resolveCurrentNs() to pass dynamic *ns* to formToValueWithNs. |
| F139 | case macro fails with mixed body types      | `(case x :a 1 :b (cond-> ...))` — shift-mask error. Related to case hash computation when body exprs mix integer literals and complex forms. Workaround: use `cond`. |
| F140 | GC crash in dissocFn (keyword pointer freed) | Segfault in keyword name comparison under heavy allocation pressure (tools.cli test-summarize). Pre-existing GC root tracking issue. |
