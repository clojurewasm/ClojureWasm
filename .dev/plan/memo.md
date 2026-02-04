# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE3 (Runtime source location)
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

BE3: Add runtime source location tracking to error messages.
vm.zig and tree_walk.zig need to capture source code locations and
original code before macro expansion, enabling proper stack traces.

## Previous Task

BE2d completed: Added descriptive error messages to atom.zig,
metadata.zig, multimethods.zig, io.zig, system.zig, regex_builtins.zig,
file_io.zig, ns_ops.zig, misc.zig, eval.zig (~73 sites), and var.zig
(1 site). Migrated InvalidNumberOfArguments → ArityError, IllegalState →
ValueError. Removed legacy tags (IndexOutOfBounds, IllegalState) from
VMError/TreeWalkError. BE2 sub-phase complete (~314 sites total across
BE2a-d).

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
