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

## Open follow-ups from the Zig 0.16.0 migration (D111)

| ID   | Item                                                       | Trigger / notes                                                                |
|------|------------------------------------------------------------|--------------------------------------------------------------------------------|
| F140 | Restore HTTP server (`cljw.http/run-server`) on `std.Io.net` | Server / Stream / Connection were stubbed in `lang/builtins/http_server.zig` (D111). Reimplement accept loop on `std.Io.net.Server`, plumb `io` through handler dispatch, restore Ring request/response building. Original logic preserved in git history pre-`40d2f20`. |
| F141 | Restore HTTP client (`cljw.http/get|post|put|delete`)        | `std.http.Client` now has a `.io` field (D111). Wire `io_default.get()` and unstub `doHttpRequest`.                                              |
| F142 | Restore nREPL server                                       | Whole `src/app/repl/nrepl.zig` (~1818 lines) collapsed to a stub during D111. Needs the same `std.Io.net` + accept loop work as F140 plus `std.posix.poll` replacement; sessions / mutex use `io_default` helpers. |
| F143 | Restore raw-mode line editor                               | `src/app/repl/line_editor.zig` not yet ported (still on `std.fs.File` + `std.io.fixedBufferStream`). `runRepl` falls through to `runReplSimple` until this is done. |
| F144 | Restore `cljw build` self-bundling                         | `std.fs.selfExePath` + `std.fs.openFileAbsolute` were removed in 0.16. Reimplement via argv[0] + `std.c.realpath` (or `_NSGetExecutablePath` / `/proc/self/exe`) and migrate file write loop. Stub in `runner.zig handleBuildCommand`. |
| F145 | OrbStack Ubuntu re-validation under Zig 0.16.0             | `--seed 0` workaround was discovered on 0.15.2; re-test on 0.16.0 (Random.zig line numbers may have shifted). Run full `bash test/run_all.sh` + `bash bench/run_bench.sh` on Linux ARM64 + x86_64. |
| F146 | Strip libc back out (`link_libc = false`)                  | zwasm v1.11.0 enables libc to satisfy the `std.posix.*` removals (D111). cf. zwasm W46. Once `std.Io` and the std.c usages in CW (`getcwd`, `getenv`, `realpath`, `mprotect`, `write`) all get pure-zig equivalents, drop libc to recover the pre-migration ~290 KB on Linux. |
