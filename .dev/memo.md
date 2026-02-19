# ClojureWasm Development Memo

Session handover document. Read at session start.

## Note: Architecture v2 Plan (2026-02-20)

Major roadmap restructuring. Phases 83A-83E inserted before Phase 84.
Read `.dev/interop-v2-design.md` for full design rationale and approach.
Decision: D105. Roadmap: `.dev/roadmap.md` Phase Tracker.

Key changes:
- 83A: Exception System Unification (Exception. returns map, hierarchy, .getMessage)
- 83B: InterOp Architecture v2 (ClassDef registry, protocol dispatch)
- 83C: UTF-8 Codepoint Correctness (string ops use codepoints, not bytes)
- 83D: Handle Memory Safety (use-after-close detection, GC finalization)
- 83E: Core All-Zig Migration (all std-lib → Zig builtins, eliminate .clj bootstrap)

Phase 84 (Testing Expansion) paused at 84.1 (compilation.clj 7/8 pass,
1 fail due to eval/defn returning symbol not var). Resume after 83E.

## Note: zwasm v1.1.0 API Change (APPLIED)

zwasm `loadWasi()` default changed to `Capabilities.cli_default`.
CW updated to use `loadWasiWithOptions(..., .{ .caps = .all })` in `src/wasm/types.zig:82`.

## Note: Roadmap Restructured (2026-02-19)

- Phase 83 reduced to "Essential Documentation" (no book, no README enrichment)
- Phase 86 (Distribution/Homebrew) deferred to Tier 4
- Phase 91 (wasm_rt) marked DEFERRED
- v0.2.0 scope: GitHub Release with binaries (no Homebrew)

## Current State

- **All phases through 83 COMPLETE** (Essential Documentation)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v1.1.0 entry = latest baseline)
- Binary: 4.25MB (wasm=true) / 3.68MB (wasm=false) ReleaseSafe. See `.dev/binary-size-audit.md`.
- Startup: 4.6ms (wasm=true) / 4.3ms (wasm=false). RSS: 7.4MB.
- Lazy bootstrap: D104. `-Dwasm=false`: D103.
- Java interop: `src/interop/` module (D101, to be superseded by D105/83B)

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

## Current Task

Phase 83D: Handle Memory Safety
Read `.dev/roadmap.md` Phase 83D section and `.dev/interop-v2-design.md`.

## Previous Task

Phase 83C COMPLETE (UTF-8 Codepoint Correctness).
- codepoint.zig: codepointCount, codepointAt, codepointSlice, codepointIndexOf
- .length, .charAt, .substring, .indexOf now use codepoints
- count, nth, subs on strings now use codepoints
- Japanese, emoji, mixed script tests all pass
- No ASCII performance regression (string_ops 29ms→25ms)

## Task Queue

```
83D.1: Add closed flag to handle state. All operations check → error if closed.
83D.2: GC finalization: destructor callback for handle-bearing maps
83D.3: Audit shared handle semantics (map copy = shared handle?)
83D.4: with-open support
83D.5: Verify all tests
```

## Known Issues

- eval/defn returns symbol instead of var (found during 84.1, fix needed)
- compilation.clj 1/8 test failure (related to above)

## Next Phase Queue

After 83D, proceed to 83E (Core All-Zig Migration).
Read `.dev/roadmap.md` Phase 83E section.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
- Design document for Architecture v2: `.dev/interop-v2-design.md`
- Phase 84 partial work: `test/upstream/clojure/test_clojure/compilation.clj` (7/8 pass)
