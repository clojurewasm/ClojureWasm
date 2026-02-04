# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE4 (Error caret precision)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description             | Notes                                                                                                                                                                                                         |
|------|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| BE4  | Error caret precision   | Investigate nested expr errors, choose strategy (arg-level threadlocal, heuristic, etc.) to improve caret position NOTE: The reported error location does not match the actual location in the original code. |
| B0   | test.clj enhancement    | is pattern dispatch, thrown?                                                                                                                                                                                  |
| B1   | Core Semantics fixes    | F29/F33, F34, F30, F31, F32                                                                                                                                                                                   |
| B2   | Macro Enhancement       | F27/F28, F93, F92, F25/F26                                                                                                                                                                                    |
| B3   | Seq/String Operations   | F41, F45, F48, F49                                                                                                                                                                                            |
| B4   | defn/ns Enhancement     | F90, F85                                                                                                                                                                                                      |

## Current Task

BE4: Error caret precision investigation.
Investigate nested expression errors. Choose strategy for improving
caret position (arg-level threadlocal, heuristic, etc.).
Also: defn macro expansion loses source info — related issue.

## Previous Task

BE3b completed: VM source location tracking.
- Chunk: `lines: ArrayList(u32)` parallel to code, `current_line: u32 = 0`
- FnProto: `lines: []const u32` parallel to code
- emit/emitOp/emitJump append current_line to lines
- Compiler.compile() sets current_line from node.source().line
- CallFrame has lines, VM.execute() annotates errors via lines[ip-1]
- Works for direct fn calls; defn macro expansion loses source info (needs BE4/macro fix)

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
