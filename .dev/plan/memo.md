# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: R (require/load/ns system)
- Next task: Plan Phase R task queue
- Coverage: 414/712 clojure.core vars done
- Blockers: none

## Task Queue

Phase R: require/load/ns system — file-based namespace loading.
Dependency chain: R1 → R2 → R3 → R4 → R5 → R6 → R7.

- R1: `*ns*` dynamic var — Clojure-accessible current namespace reference
  - Create `*ns*` var in bootstrap, sync with env.current_ns
  - Update in-ns to set `*ns*` binding when switching namespace
- R2: `load-file` + load path infrastructure
  - `load-file` reads file by path, evals all forms in sequence
  - Add `*load-paths*` (default: ["."]) for classpath-equivalent
  - CLI `--classpath` / `-cp` option to configure load paths
- R3: `load` + path resolution
  - `root-resource`: ns name → file path (clojure.string → /clojure/string.clj)
  - Search load paths for the file
  - `*loaded-libs*` dynamic var (atom wrapping set) for dedup tracking
- R4: Upgrade `require` to file-based loading
  - When ns not found → call load to find and eval the file
  - `:reload` / `:reload-all` flag support
  - Cyclic dependency detection via `*pending-paths*` stack
  - `:as`, `:refer`, `:refer :all` (already partially implemented)
- R5: Upgrade `use` to file-based + `refer-clojure`
  - `use` = require + refer-all
  - `refer-clojure` function for `:exclude` support in ns macro
- R6: `ns` macro full implementation
  - Upstream-faithful expansion: `:require`, `:use`, `:refer-clojure`
  - `*file*` var set during load
- R7: E2E test — multi-file project
  - Create test project with inter-dependent .clj files
  - Verify require/use/ns/alias/refer chain on both backends

## Current Task

R3: `load` + path resolution.

## Previous Task

R2 completed: `load-file` builtin.
- Added loadFileFn to file_io.zig — reads file, evals via bootstrap.evalString
- Works with ns switching in loaded files
- Both backends pass

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
- **Phase R** (current): require/load/ns system — full file-based loading, see `roadmap.md`
- Phase D (after Phase R): Parallel expansion (new vars + test porting)
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- Beta delay reference: `ClojureWasmBeta/src/lib/core/concurrency.zig`, `ClojureWasmBeta/src/base/value.zig`
- Beta hierarchy reference: `ClojureWasmBeta/src/lib/core/interop.zig`
