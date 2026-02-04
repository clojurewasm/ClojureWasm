# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE2d (Other builtins error messages)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description             | Notes                                                                                                                     |
|------|-------------------------|---------------------------------------------------------------------------------------------------------------------------|
| BE2  | Builtin error messages  | 17 files, ~314 sites                                                                                                      |
| BE3  | Runtime source location | vm.zig, tree_walk.zig NOTE: Source code locations and original code before macro expansion, enabling proper stack traces. |
| B0   | test.clj enhancement    | is pattern dispatch, thrown?                                                                                              |
| B1   | Core Semantics fixes    | F29/F33, F34, F30, F31, F32                                                                                               |
| B2   | Macro Enhancement       | F27/F28, F93, F92, F25/F26                                                                                                |
| B3   | Seq/String Operations   | F41, F45, F48, F49                                                                                                        |
| B4   | defn/ns Enhancement     | F90, F85                                                                                                                  |

## Current Task

BE2d: Add descriptive error messages to remaining builtin files
(atom, metadata, multimethods, ns_ops, misc, io, file_io,
regex_builtins, system, eval, var.zig). Migrate var.zig's IllegalState
→ ValueError. After this, remove legacy tags (IndexOutOfBounds,
IllegalState) from VMError/TreeWalkError.

## Previous Task

BE2c completed: Added descriptive error messages to strings.zig
(~18 sites) and clj_string.zig (~51 sites). Migrated IndexOutOfBounds →
IndexError in subsFn. Both backends verified with E2E tests.

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul
  - BE1: Done — threadlocal + reportError() + showSourceContext()
  - BE2a: Done — core builtins (arithmetic, numeric, predicates); DivisionByZero removed
  - BE2b: Done — collections + sequences; IndexOutOfBounds→IndexError, IllegalState→ValueError
  - BE2c: Done — strings (strings.zig, clj_string.zig); IndexOutOfBounds→IndexError in subsFn
  - BE2d: Next — other builtins (~111 sites remaining)
  - Legacy error tags: IndexOutOfBounds/IllegalState in VMError/TreeWalkError — remove after BE2d migrates all files
  - BE3: After BE2 — runtime source location in vm.zig/tree_walk.zig NOTE: Source code locations and original code before macro expansion, enabling proper stack traces.
  - Architecture: D3a superseded by D63 (threadlocal)
  - Error API: `err.setError(info)`, `err.setErrorFmt(...)`, `err.getLastError()`
  - Display: `reportError()` in main.zig, babashka-style format
- Phase B: Fix F## items (test.clj, core semantics, macros, seq/string)
- Phase C: Faithful upstream test porting with CLJW markers
- Phase D: Parallel expansion (new vars + test porting)
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
