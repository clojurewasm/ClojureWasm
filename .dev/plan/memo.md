# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: B0 (test.clj enhancement)
- Coverage: 399/712 clojure.core vars done
- Blockers: none

## Task Queue

| Task | Description                        | Notes                                                                        |
|------|------------------------------------|------------------------------------------------------------------------------|
| B0   | test.clj enhancement              | is pattern dispatch, thrown?                                                  |
| B1   | Core Semantics fixes               | F29/F33, F34, F30, F31, F32                                                   |
| B2   | Macro Enhancement                  | F27/F28, F93, F92, F25/F26                                                    |
| B3   | Seq/String Operations              | F41, F45, F48, F49                                                            |
| B4   | defn/ns Enhancement                | F90, F85                                                                      |

## Current Task

B0: test.clj enhancement.
is pattern dispatch, thrown? implementation.

## Previous Task

BE4 completed: Integration verification + macro child source preservation.
- Root cause: formToValue→valueToForm roundtrip lost per-child source positions
- Fix: child_lines/child_columns on PersistentList/PersistentVector
- formToValue stores child Form positions, valueToForm restores them
- Result: defn body errors now point to exact bad argument, not just `(+`
- Verified: defn, nested defn, let, custom macro — both backends consistent
- E2E tests added for defn body error and let body error positions

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
  - BE4: Done — child source preservation on PersistentList/PersistentVector, E2E tests for macro-expanded error positions
  - BE5: Done — source_line/source_column on PersistentList/PersistentVector, formToValue/valueToForm roundtrip, expandMacro stamp (D64)
  - BE6: Done (Part A) — VM column tracking (Chunk.columns, Compiler.current_column, CallFrame.columns)
  - BE6 Part B: Done — arg-level source (ConstantNode, threadlocal arg sources, VM backward scan)
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
