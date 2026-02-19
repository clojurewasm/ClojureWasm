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
- Coverage: 1,126/1,243 vars done (90.6%), 113 skip, 4 TODO (cl-format), 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.07MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
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

Phase 79: cl-format Implementation
Sub-task 79.2: formatter macro

## Previous Task

79.1: cl-format core engine. Ported full cl-format from upstream (~1600 lines).
All directives: ~A, ~S, ~D, ~B, ~O, ~X, ~R (cardinal/ordinal/roman), ~P, ~C, ~%, ~~,
~[conditional], ~{iteration}, ~*, ~?, ~^, ~F, ~E, ~$, ~(case), ~T, ~W, ~_newline, ~I, ~<justify>.
Fixed: merge-with closure support (collections.zig), bootstrap cache forward-reference bug (serialize.zig).
CW adaptations: char-upper/char-lower helpers, predicate-based type checks, contains? for flag checks.

## Task Queue

```
79.2 formatter macro ← CURRENT
79.3 formatter-out macro
79.4 code-dispatch (pprint, uses formatter-out)
```

## Known Issues

(none)

## Next Phase Queue

After Phase 79 completes, proceed to Phase 80 (Crash Hardening & Fuzzing).
Read `.dev/roadmap.md` Phase 80 section for sub-tasks.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
