# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: C (Faithful test porting) in progress
- Next task: C7 (def.clj)
- Coverage: 402/712 clojure.core vars done
- Blockers: none

## Task Queue

Phase C: Faithful upstream test porting with CLJW markers.
Order: new small → re-port existing → new medium → new large.

- ~~C1: volatiles.clj~~ done
- ~~C2: macros.clj~~ done
- ~~C3: Re-port logic.clj~~ done (102 assertions)
- ~~C4: Re-port for.clj~~ done (49 assertions, lazy seq infrastructure D65)
- ~~C5: Re-port atoms.clj~~ done (12 assertions, *warn-on-reflection* stub)
- ~~C6: delays.clj~~ done (6 assertions, delay exception caching)
- C7: def.clj (84 lines, partial — spec tests JVM-only)
- C8: vars.clj (109 lines, partial — threading/promise JVM-only)
- C9: Re-port control.clj (upstream faithful)
- C10: Re-port predicates.clj (upstream faithful)
- C11: Re-port data_structures.clj (upstream faithful)
- C12: Re-port sequences.clj (upstream faithful)
- C13: clojure_walk.clj (75 lines)
- C14: string.clj (196 lines)
- C15: clojure_set.clj (224 lines)
- C16: metadata.clj (239 lines)
- C17: special.clj (106 lines, many F## blockers)
- C18: other_functions.clj (401 lines)
- C19: numbers.clj (959 lines)
- C20: evaluation.clj (226 lines)

## Current Task

C7: def.clj — faithful from upstream with CLJW markers.

## Previous Task

C6 completed: Port delays.clj — 6 assertions (2 of 5 tests; 3 JVM interop).
- Fixed nested try/catch VM handler bug (pop_handler opcode 0xA2)
- Fixed cross-backend exception value propagation (bootstrap.last_thrown_exception)
- Added delay exception caching (:error atom, force try/catch, deref override)

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul (complete)
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
- Phase B: Complete — all F## items resolved (B0-B4)
- Phase C: Faithful upstream test porting with CLJW markers
- Phase D: Parallel expansion (new vars + test porting)
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
