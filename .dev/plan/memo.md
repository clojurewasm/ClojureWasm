# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE2 (Builtin error messages)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description                  | Notes                              |
|------|------------------------------|------------------------------------|
| BE2  | Builtin error messages       | 17 files, ~314 sites               |
| BE3  | Runtime source location      | vm.zig, tree_walk.zig              |
| B0   | test.clj enhancement         | is pattern dispatch, thrown?        |
| B1   | Core Semantics fixes         | F29/F33, F34, F30, F31, F32        |
| B2   | Macro Enhancement            | F27/F28, F93, F92, F25/F26         |
| B3   | Seq/String Operations        | F41, F45, F48, F49                 |
| B4   | defn/ns Enhancement          | F90, F85                           |

## Current Task

Write task design here at iteration start.
On next task, move this content to Previous Task below.

## Previous Task

BE1 completed: Switched error system from instance-based ErrorContext (D3a)
to threadlocal. Added reportError() with babashka-style error display to
main.zig (Type, Message, Phase, Location, source context with pointer).
Analysis/parse errors now show full diagnostics. Runtime errors still show
fallback "Error: {errorName}" (BE2/BE3 will fix).

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul
  - BE1: Done — threadlocal + reportError() + showSourceContext()
  - BE2: Next — add error messages to 17 builtin files (~314 sites)
  - BE3: After BE2 — runtime source location in vm.zig/tree_walk.zig
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
