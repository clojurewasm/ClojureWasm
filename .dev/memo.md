# ClojureWasm Development Memo

Session handover document. Read at session start.

## Note: zwasm v1.1.0 API Change (APPLIED)

zwasm `loadWasi()` default changed to `Capabilities.cli_default`.
CW updated to use `loadWasiWithOptions(..., .{ .caps = .all })` in `src/wasm/types.zig:82`.

## Note: Roadmap Restructured (2026-02-19)

- Phase 83 reduced to "Essential Documentation" (no book, no README enrichment)
- Phase 86 (Distribution/Homebrew) deferred to Tier 4
- Phase 91 (wasm_rt) marked DEFERRED
- Phases 80, 81, 84 enhanced with zwasm production learnings (fuzzing, error catalog, differential testing)
- v0.2.0 scope: GitHub Release with binaries (no Homebrew)
- Tier 3 = Phases 87-88 (DX + Release), not 86-88
- zwasm dependencies table updated (v1.1.0, 100% spec, security done)

## Current State

- **All phases through 76 COMPLETE** (Type System & Reader Enhancements)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO (cl-format complete), 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.44MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
- Java interop: `src/interop/` module with URI, File, UUID, PushbackReader, StringBuilder, StringWriter, BufferedWriter classes (D101)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only. Libraries requiring heavy Java interop are out of scope.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (4.07MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).
When behavior differs from upstream Clojure, trace CW's processing pipeline to find
and fix the root cause. Add Java interop shims only when 3+ libraries need the same
pattern AND it's <100 lines of Zig. If a library requires heavy Java interop that
CW won't implement, that library is out of scope — document and move on.
See `.dev/library-port-targets.md` for targets and decision guide.

## Current Task

Phase 79A: Binary Optimization & Startup Acceleration.
Sub-task 79A.4: cljw build integration verification.

## Previous Task

Phase 79A.3 COMPLETE (lazy bootstrap: deferred NS deserialization + require integration).
- Essential NS: core, core.protocols, user (restored at startup)
- 12 deferred NS restored on-demand via require
- Cross-NS dependency resolution (recursive)
- Global deferred var_ref + protocol_fn resolution
- RSS reduced ~18% (9.3MB → 7.6MB)

## Task Queue

```
79A.4: cljw build integration verification
79A.5: bench/build_bench.sh measurement infrastructure
79A.6: Cross-language benchmark full run
79A.7: All-profile final measurement
79A.8: Test verification (both profiles)
79A.9b: Final docs (baselines, decisions, audit)
```

## Known Issues

(none)

## Next Phase Queue

After Phase 79A, proceed to Phase 80 (Crash Hardening & Fuzzing).
Read `.dev/roadmap.md` Phase 80 section for sub-tasks.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
