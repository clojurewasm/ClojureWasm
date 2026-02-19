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

Target Phase references: see `.dev/roadmap.md` Phase Tracker + Open Checklist Items table.

| ID   | Item                                        | Target | Trigger                                                                  |
|------|---------------------------------------------|--------|--------------------------------------------------------------------------|
| F94  | Upstream Alignment pass                     | 78.3   | Phase 70.5.4 audit: 87 markers in src/clj/ (P=48, S=12, R=27). R items need: :inline meta (2), IDrop (2), IReduceInit/deftype (3), TransformerIterator (1), seqkvreduce (1), extend-via-metadata (2), deftype (3), ref/multimethod in test (7), spec in repl (1), assert-expr (1), run-test (1), :__reify_type (1). |
| F102 | map/filter chunked processing               | 89.1   | Chunked types exist, range is lazy. Optimization: use chunks in map/filter pipelines. |
| F103 | Escape analysis (local scope skip GC)       | 89.3   | Compiler detects local-only Values, skip GC tracking                     |
| F104 | Profile-guided optimization (extend IC)     | 89     | Extend inline caching beyond monomorphic                                 |
| F105 | JIT compilation (expand beyond ARM64 PoC)   | 90     | ARM64 hot-loop JIT done (Phase 37.4, D87). Future: x86_64 port, expand beyond integer loops. |
| F120 | Native SIMD optimization (CW internals)     | 89     | Investigate Zig `@Vector` for CW hot paths. Profile first.               |
| F139 | case macro fails with mixed body types      | 78.2   | `(case x :a 1 :b (cond-> ...))` — shift-mask error. Related to case hash computation when body exprs mix integer literals and complex forms. Workaround: use `cond`. |
| F141 | cljw.xxx aliases for clojure.java.xxx       | 85.4   | `(require '[cljw.io])` should map to `clojure.java.io`. Targets: cljw.io, cljw.shell, cljw.browse, cljw.process. Needs ns alias mapping in require/resolve path. |
