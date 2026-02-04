# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 19 (Foundation Reset: Upstream Fidelity)
- Sub-phase: BE (Error System Overhaul)
- Next task: BE1 (Threadlocal infrastructure + display)
- Coverage: 399/712 clojure.core vars done (0 without notes)
- Blockers: none

## Task Queue

| Task | Description                  | Notes                              |
|------|------------------------------|------------------------------------|
| BE1  | Threadlocal infra + display  | error.zig, main.zig, bootstrap etc |
| BE2  | Builtin error messages       | 17 files, ~314 sites               |
| BE3  | Runtime source location      | vm.zig, tree_walk.zig              |
| B0   | test.clj enhancement         | is pattern dispatch, thrown?        |
| B1   | Core Semantics fixes         | F29/F33, F34, F30, F31, F32        |
| B2   | Macro Enhancement            | F27/F28, F93, F92, F25/F26         |
| B3   | Seq/String Operations        | F41, F45, F48, F49                 |
| B4   | defn/ns Enhancement          | F90, F85                           |

## Current Task

### BE1: Threadlocal infrastructure + error display

**Goal**: Switch ErrorContext from instance-based to threadlocal.
Add reportError() and showSourceContext() to main.zig.

**Steps**:
1. error.zig: Replace ErrorContext struct with threadlocal vars + module-level
   functions (setError, setErrorFmt, getLastError, setSourceText, getSourceText).
   Keep Info, Kind, Phase, SourceLocation, Error unchanged.
2. Update all consumers (7 files):
   - analyzer.zig: Remove error_ctx field, use err.setError() directly
   - reader.zig: Remove error_ctx param, use err.setError() directly
   - bootstrap.zig: Remove local ErrorContext vars, remove &error_ctx params
   - env.zig: Remove error_ctx if used
   - nrepl.zig: Remove error_ctx if used
   - eval.zig (builtin): Remove error_ctx if used
3. main.zig: Add reportError(), showSourceContext(), countDigits(),
   writeLineNumber(), writeErrorPointer(), getSourceForLocation().
   Replace all "Error: evaluation failed" with reportError() calls.
   Add setSourceText() before evaluation.
4. Verify: zig build test + manual test with intentional errors

**Acceptance**: Error messages show kind + message + location + source context.

## Previous Task

Phase A completed. 399 done vars all annotated (0 without notes).
B0 attempted but reverted — defmacro multi-arity needed first.
Error system investigation showed current errors are "Error: evaluation failed"
with zero diagnostics. Inserted Phase BE before B0.

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul (threadlocal, display, builtin messages)
- Phase B: Fix F## items (test.clj, core semantics, macros, seq/string)
- Phase C: Faithful upstream test porting with CLJW markers
- Phase D: Parallel expansion (new vars + test porting)
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- CW D3a (instance-based ErrorContext) will be reversed → threadlocal
