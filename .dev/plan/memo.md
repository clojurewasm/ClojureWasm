# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: CX (Known Issue Resolution, inserted between C12 and C13)
- Next task: CX8 (Hierarchy system)
- Coverage: 402/712 clojure.core vars done
- Blockers: none

## Task Queue

Phase CX: Resolve actionable F## items before continuing test porting.
Detailed plan: `.dev/plan/phase-cx-plan.md`

- ~~CX1: Remove F51 + Fix F24 (housekeeping)~~ done
- ~~CX2: bound? takes var_ref (F86)~~ done
- ~~CX3: Math/System syntax routing (F89)~~ done
- ~~CX4: delay proper Value type (F91)~~ done
- ~~CX5: {:as x} seq-to-map coercion (F68)~~ done
- ~~CX6: Namespaced destructuring (F70-F74)~~ done
- ~~CX7: ::foo auto-resolved keyword (F81)~~ done
- CX8: Hierarchy system (F82 + F83)
- CX9: #'var inside deftest body (F87)
- CX10: UPSTREAM-DIFF quick fixes (F94 partial)

## Saved Phase C Queue (resume after CX)

Phase C: Faithful upstream test porting with CLJW markers.
Order: new small → re-port existing → new medium → new large.

Completed:
- ~~C1: volatiles.clj~~ done
- ~~C2: macros.clj~~ done
- ~~C3: Re-port logic.clj~~ done (102 assertions)
- ~~C4: Re-port for.clj~~ done (49 assertions, lazy seq infrastructure D65)
- ~~C5: Re-port atoms.clj~~ done (12 assertions, *warn-on-reflection* stub)
- ~~C6: delays.clj~~ done (6 assertions, delay exception caching)
- ~~C7: def.clj~~ done (2 assertions, eval do sequential fix)
- ~~C8: vars.clj~~ done (1 assertion, zipmap lazy seq fix)
- ~~C9: Re-port control.clj~~ done (155 assertions, was 66)
- ~~C10: Re-port predicates.clj~~ skip (already faithful, 143 assertions)
- ~~C11: Re-port data_structures.clj~~ done (236 assertions, was 197, keys/vals nil-for-non-map fix)
- ~~C12: Re-port sequences.clj~~ done (301 assertions, was 188, lazy-seq equality + drop lazy-seq)

Remaining (resume here after CX):
- C13: clojure_walk.clj (75 lines)
- C14: string.clj (196 lines)
- C15: clojure_set.clj (224 lines)
- C16: metadata.clj (239 lines)
- C17: special.clj (106 lines, many F## blockers — CX should resolve most)
- C18: other_functions.clj (401 lines)
- C19: numbers.clj (959 lines)
- C20: evaluation.clj (226 lines)

## Current Task

CX8: Hierarchy system (F82 + F83) — derive, isa?, prefer-method for multimethods.

## Previous Task

CX7 completed: ::foo auto-resolved keyword (F81).
- SymbolRef.auto_resolve flag in form.zig
- Reader sets flag for :: keywords
- Analyzer resolves via env.current_ns (::foo) or ns.getAlias (::alias/foo)
- macro.formToValueWithNs propagates resolution through macro expansion
- Supports ::foo, ::keys, :keys [::x], ns switching, quoted ::foo
- Both backends pass all E2E tests

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- **Phase CX plan: `.dev/plan/phase-cx-plan.md`** (read before starting CX tasks)
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
- Phase C: Faithful upstream test porting with CLJW markers (C1-C12 done, C13-C20 saved)
- Phase CX: Known issue resolution (F51, F24, F68, F70-74, F80-83, F86-87, F89, F91, F94)
- Phase D: Parallel expansion (new vars + test porting)
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- Beta delay reference: `ClojureWasmBeta/src/lib/core/concurrency.zig`, `ClojureWasmBeta/src/base/value.zig`
- Beta hierarchy reference: `ClojureWasmBeta/src/lib/core/interop.zig`
