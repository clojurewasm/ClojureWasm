# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Thread-safe (48.1)**: threadlocal (current_frame, macro_eval_env, predicates.current_env, last_thrown_exception, io capture/input stacks, active_vm, file_read_buf), atomic (_vec_gen_counter, gensym_counter), mutex (keyword_intern.table, prng, host_contexts, loaded_libs/loading_libs)
  - **Known exceptions**: lifecycle.shutdown_requested/hooks (34.5), http_server.build_mode/background_mode/bg_server (34.2) — module-level, init-once or single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Active (fix now — Phase 88C)

| ID   | Item                                        | Issue  | Priority |
|------|---------------------------------------------|--------|----------|
| ~~F130~~ | ~~cljw test state pollution across files~~ | ~~I-001~~ | RESOLVED |
| ~~F131~~ | ~~bit-shift-left/right panics on shift ≥64~~ | ~~I-002~~ | RESOLVED |
| ~~F132~~ | ~~char returns char type, not string~~ | ~~I-003~~ | RESOLVED |
| ~~F133~~ | ~~Unified "run all tests" command~~ | ~~I-010~~ | RESOLVED |

## Blocked until needed

Target Phase references: see `.dev/roadmap.md` Phase Tracker + Open Checklist Items table.

| ID   | Item                                        | Target | Trigger                                                                  |
|------|---------------------------------------------|--------|--------------------------------------------------------------------------|
| F94  | Upstream Alignment pass                     | 78.3   | 199 markers in src/clj/ (P=71, S=107, R=21). P/S resolved by design. R items: ForkJoin(5), socket server(3), dynamic deps(2), GUI(2), ProcessBuilder(4), test.check(1), Throwable-map(1), BigDecimal(1), Long/Integer(1), runtime-compile(1). extend-via-metadata(2) resolved in 88A.5. Most blocked on future infra. Achievable now: Throwable-map(1). |
| F102 | map/filter chunked processing               | 89.1   | Chunked types exist, range is lazy. Optimization: use chunks in map/filter pipelines. |
| F103 | Escape analysis (local scope skip GC)       | 89.3   | Compiler detects local-only Values, skip GC tracking                     |
| F104 | Profile-guided optimization (extend IC)     | 89     | Extend inline caching beyond monomorphic                                 |
| F105 | JIT compilation (expand beyond ARM64 PoC)   | 90     | ARM64 hot-loop JIT done (Phase 37.4, D87). Future: x86_64 port, expand beyond integer loops. |
| F120 | Native SIMD optimization (CW internals)     | 89     | Investigate Zig `@Vector` for CW hot paths. Profile first.               |
