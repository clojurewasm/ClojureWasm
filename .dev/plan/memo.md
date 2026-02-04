# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE6 (Arg-level error source)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description                        | Notes                                                                        |
|------|------------------------------------|------------------------------------------------------------------------------|
| BE6  | Arg-level error source             | Column debug info + threadlocal arg sources. Design: be5-be6-design.md        |
| BE4  | Integration verification           | Complex nesting tests, both backends, macro + nested errors                   |
| B0   | test.clj enhancement              | is pattern dispatch, thrown?                                                  |
| B1   | Core Semantics fixes               | F29/F33, F34, F30, F31, F32                                                   |
| B2   | Macro Enhancement                  | F27/F28, F93, F92, F25/F26                                                    |
| B3   | Seq/String Operations              | F41, F45, F48, F49                                                            |
| B4   | defn/ns Enhancement                | F90, F85                                                                      |

## Current Task

BE6: Arg-level error source.
Column tracking in VM (Chunk columns array, Compiler save/restore).
Threadlocal arg source API in error.zig.
TreeWalk/VM arg source saving, builtins use getArgSource.
Design: `.dev/notes/be5-be6-design.md`

## Previous Task

BE5 completed: Macro expansion source preservation.
- Added source_line/source_column fields to PersistentList/PersistentVector
- formToValue copies Form.line/column to collection source fields
- valueToForm restores Form.line/column from collection source fields
- expandMacro stamps original call source on expanded form when line=0
- TreeWalk: exact sub-expression (e.g. (+ x y) at 1:16 inside defn)
- VM: line-level precision through macros (column is call-site)

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
  - BE3b: Done — VM source location (lines array in Chunk/FnProto, Compiler tracks current_line, VM annotates from lines[ip-1])
  - BE4: Investigation done — identified 2 root causes, created BE5/BE6 tasks
  - BE5: Done — source_line/source_column on PersistentList/PersistentVector, formToValue/valueToForm roundtrip, expandMacro stamp (D64)
  - BE6: Next — arg-level error source (column debug info + threadlocal arg sources)
  - BE5/BE6 design: `.dev/notes/be5-be6-design.md` (read before implementing)
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
