# Deferred Work Checklist

Compact list of deferred items extracted from `.dev/notes/decisions.md`.
Check this at session start to catch items that become relevant.

Last updated: 2026-02-03 (Phase 12 — T12.1 done, T12.2 next)

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5) — module-level, single-thread only. realize_fn and atom.call_fn removed by D36 deep refactor (direct import of bootstrap.callFnVal)
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
  - **Known exceptions**: defmulti, defmethod, lazy-seq — TreeWalk only (D28)
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID      | Item                                            | Trigger                                                                                | Source |
| ------- | ----------------------------------------------- | -------------------------------------------------------------------------------------- | ------ |
| F1      | NaN boxing (Value optimization)                 | fib(30) < 500ms target or memory pressure                                              | D1     |
| F2      | Real GC (replace arena)                         | Long-running REPL or memory benchmarks exceed bounds                                   | D2     |
| F3      | Ratio type (`1/3`)                              | SCI tests fail on float precision loss                                                 | D12    |
| F4      | Persistent data structures (HAMT, RRB-Tree)     | Collection benchmarks show bottleneck                                                  | D9     |
| ~~F5~~  | ~~swap! with fn_val (closure dispatch)~~        | ~~Resolved: T9.5.2 — atom.call_fn dispatcher~~                                         | D8     |
| F6      | Multi-thread dynamic bindings                   | Native multi-thread target                                                             | D11    |
| F7      | Macro body serialization (AOT blocker)          | T4.7 AOT bytecode startup                                                              | D18    |
| ~~F8~~  | ~~TreeWalk→VM reverse dispatch~~                | ~~Resolved: T10.2 — bytecodeCallBridge in bootstrap.zig~~                              | D22    |
| F13     | VM opcodes for defmulti/defmethod               | VM-only mode needs multimethod dispatch                                                | D28    |
| F14     | VM opcodes for lazy-seq/realize                 | VM-only mode needs lazy evaluation                                                     | D28    |
| ~~F19~~ | ~~Reader input validation (depth/size limits)~~ | ~~Resolved: T11.1b — Reader.Limits (depth/string/collection) + nREPL/CLI size checks~~ | SS14   |
| F20     | Safe point GC design                            | Real GC (F2) implementation start                                                      | SS5    |
| F21     | 3-layer separation (Memory/Exec/Opt)            | Introduction of fused reduce or optimization pass                                      | SS5    |
| F22     | compat_test.yaml introduction                   | SCI/upstream test mass porting (Phase 12b)                                             | SS10   |
| ~~F9~~  | ~~`empty?` builtin~~                            | ~~Resolved: T6.1~~                                                                     | bench  |
| ~~F10~~ | ~~`range` builtin~~                             | ~~Resolved: T6.1~~                                                                     | bench  |
| ~~F11~~ | ~~TreeWalk stack depth limit~~                  | ~~Resolved: T7.1 — MAX_CALL_DEPTH=512 + heap alloc~~                                   | bench  |
| ~~F12~~ | ~~`str` fixed 4KB buffer~~                      | ~~Resolved: T7.2 — Writer.Allocating (dynamic)~~                                       | bench  |
| ~~F15~~ | ~~VM evalStringVM fn_val use-after-free~~       | ~~Resolved: T9.5.1 — Compiler.detachFnAllocations~~                                    | D32    |
| ~~F16~~ | ~~seq on map (MapEntry)~~                       | ~~Resolved: T9.5.3 — seqFn + firstFn/restFn map support~~                              | D32    |
| ~~F17~~ | ~~VM loop/recur wrong results~~                 | ~~Resolved: T10.1 — emitLoop used pop instead of pop_under~~                           | T9.5.4 |
| ~~F18~~ | ~~Nested fn use-after-free in compiler~~        | ~~Resolved: T10.3 — detachFnAllocations in compileArity~~                              | D35    |

## Phase 4 task priorities (historical — all complete)

| ID  | Item                                | Phase | Status                                                                 |
| --- | ----------------------------------- | ----- | ---------------------------------------------------------------------- |
| P1  | VM parity with Phase 3 features     | 4b    | Done: T4.1-4.4 (variadic arith, predicates, collection ops, string/IO) |
| P2  | core.clj AOT pipeline (T3.11/T3.12) | 4c    | Partial: T4.6 evalStringVM done. T4.7 AOT embed deferred (needs F7)    |
| P3  | Missing language features           | 4d    | Done: multi-arity T4.8, destructuring T4.9, for T4.10, protocols T4.11 |
| P4  | REPL                                | 4e    | Done: T4.12 interactive REPL with multi-line + error recovery          |
| P5  | Wasm target                         | 4e    | Done: T4.13 `zig build wasm`, 207KB, wasmtime verified                 |
| P6  | Directory restructuring             | 4f    | Done: T4.14/15 — src/repl/ created, wasm_rt/gc/ unified                |
