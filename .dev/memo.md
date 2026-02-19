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

- **All phases through 79A COMPLETE** (Binary Optimization & Startup Acceleration)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.25MB (wasm=true) / 3.68MB (wasm=false) ReleaseSafe. See `.dev/binary-size-audit.md`.
- Startup: 4.6ms (wasm=true) / 4.3ms (wasm=false). RSS: 7.4MB.
- Lazy bootstrap: D104. `-Dwasm=false`: D103.
- Java interop: `src/interop/` module with URI, File, UUID, PushbackReader, StringBuilder, StringWriter, BufferedWriter classes (D101)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only. Libraries requiring heavy Java interop are out of scope.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (4.25MB macOS default, 3.68MB wasm=false)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).
When behavior differs from upstream Clojure, trace CW's processing pipeline to find
and fix the root cause. Add Java interop shims only when 3+ libraries need the same
pattern AND it's <100 lines of Zig. If a library requires heavy Java interop that
CW won't implement, that library is out of scope — document and move on.
See `.dev/library-port-targets.md` for targets and decision guide.

## Current Task

Phase 80: Crash Hardening & Fuzzing.
Sub-task 80.9: Threat model document (CW trust boundaries).

## Previous Task

Phase 80.8 COMPLETE (Vulnerability Audit).
Full audit across all categories:
- **GC**: All secure — mark-and-sweep with HashMap tracking, mutex protection, no use-after-free/double-free
- **VM**: Hardened — added pop/peek underflow assertions, jump bounds checks, try_begin catch_ip validation
- **Clojure layer**: All secure — eval injection (expected), path traversal (sanitized), namespace poisoning (standard), serialization bomb (reader limits), lazy-seq OOM (lazy evaluation)
- **Interop/FFI**: All secure — opaque wasm wrapper, WASI capability flags, sandbox integrity
- **Build**: All secure — ReleaseSafe preserves bounds/overflow checks, zwasm pinned+hashed

## Task Queue

```
80.9: Threat model document (CW trust boundaries)
```

## Known Issues

(none)

## Next Phase Queue

After Phase 80, proceed to Phase 81 (Error System Maturity).
Read `.dev/roadmap.md` Phase 81 section for sub-tasks.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
