# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE3b (VM source location)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description             | Notes                                                                                                                     |
|------|-------------------------|---------------------------------------------------------------------------------------------------------------------------|
| BE3  | Runtime source location | vm.zig, tree_walk.zig NOTE: Source code locations and original code before macro expansion, enabling proper stack traces. |
| B0   | test.clj enhancement    | is pattern dispatch, thrown?                                                                                              |
| B1   | Core Semantics fixes    | F29/F33, F34, F30, F31, F32                                                                                               |
| B2   | Macro Enhancement       | F27/F28, F93, F92, F25/F26                                                                                                |
| B3   | Seq/String Operations   | F41, F45, F48, F49                                                                                                        |
| B4   | defn/ns Enhancement     | F90, F85                                                                                                                  |

## Current Task

BE3b: Add runtime source location tracking to VM backend.
VM needs debug info table (instruction → SourceInfo mapping) in Chunk,
Compiler records source at emit time, VM annotates errors from debug info.

## Previous Task

BE3a completed: TreeWalk source location + file name + pointer message.
- `annotateLocation()` in error.zig: fills SourceLocation on threadlocal error
- TreeWalk `run()` wraps `runNode()` to annotate errors with Node SourceInfo
- `setSourceFile/getSourceFile` threadlocal: threads file name from main → Analyzer
- Error pointer shows message instead of generic "error here"
- Example output:
  Location: test.clj:3:0
  3 | (+ 1 "x")
      ^--- Cannot cast string to number

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul
  - BE1: Done — threadlocal + reportError() + showSourceContext()
  - BE2a: Done — core builtins (arithmetic, numeric, predicates); DivisionByZero removed
  - BE2b: Done — collections + sequences; IndexOutOfBounds→IndexError, IllegalState→ValueError
  - BE2c: Done — strings (strings.zig, clj_string.zig); IndexOutOfBounds→IndexError in subsFn
  - BE2d: Done — other builtins (atom, metadata, multimethods, io, system, regex, file_io, ns_ops, misc, eval, var.zig); legacy tags removed
  - BE3a: Done — TreeWalk source location (annotateLocation, file name, message pointer)
  - BE3b: Next — VM source location (needs debug_info in Chunk/Compiler, IP→SourceInfo mapping)
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
