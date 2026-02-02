# Deferred Work Checklist

Compact list of deferred items extracted from `.dev/notes/decisions.md`.
Check this at session start to catch items that become relevant.

Last updated: 2026-02-02 (Phase 9.5 planning — D32)

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), realize_fn (D27) — both module-level, single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
  - **Known exceptions**: defmulti, defmethod, lazy-seq — TreeWalk only (D28)
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID      | Item                                        | Trigger                                               | Source |
| ------- | ------------------------------------------- | ----------------------------------------------------- | ------ |
| F1      | NaN boxing (Value optimization)             | fib(30) < 500ms target or memory pressure             | D1     |
| F2      | Real GC (replace arena)                     | Long-running REPL or memory benchmarks exceed bounds  | D2     |
| F3      | Ratio type (`1/3`)                          | SCI tests fail on float precision loss                | D12    |
| F4      | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                 | D9     |
| F5      | swap! with fn_val (closure dispatch)        | **Phase 9.5.2 — actively targeted**                   | D8     |
| F6      | Multi-thread dynamic bindings               | Native multi-thread target                            | D11    |
| F7      | Macro body serialization (AOT blocker)      | T4.7 AOT bytecode startup                             | D18    |
| F8      | Unified fn_val proto (VM/TreeWalk)          | VM tests for `for`, higher-order cross-boundary calls | D22    |
| F13     | VM opcodes for defmulti/defmethod           | VM-only mode needs multimethod dispatch               | D28    |
| F14     | VM opcodes for lazy-seq/realize             | VM-only mode needs lazy evaluation                    | D28    |
| ~~F9~~  | ~~`empty?` builtin~~                        | ~~Resolved: T6.1~~                                    | bench  |
| ~~F10~~ | ~~`range` builtin~~                         | ~~Resolved: T6.1~~                                    | bench  |
| ~~F11~~ | ~~TreeWalk stack depth limit~~              | ~~Resolved: T7.1 — MAX_CALL_DEPTH=512 + heap alloc~~  | bench  |
| ~~F12~~ | ~~`str` fixed 4KB buffer~~                  | ~~Resolved: T7.2 — Writer.Allocating (dynamic)~~      | bench  |
| F15     | VM evalStringVM fn_val use-after-free       | **Phase 9.5.1 — actively targeted**                   | D32    |
| F16     | seq on map (MapEntry)                       | **Phase 9.5.3 — actively targeted**                   | D32    |

## Phase 4 task priorities

| ID  | Item                                | Phase | Depends on | Notes                                                                  |
| --- | ----------------------------------- | ----- | ---------- | ---------------------------------------------------------------------- |
| P1  | VM parity with Phase 3 features     | 4b    | —          | variadic arith, predicates, inc/dec not in VM                          |
| P2  | core.clj AOT pipeline (T3.11/T3.12) | 4c    | P1         | build.zig custom step, @embedFile                                      |
| P3  | Missing language features           | 4d    | —          | Done: multi-arity T4.8, destructuring T4.9, for T4.10, protocols T4.11 |
| P4  | REPL                                | 4e    | —          | Done: T4.12 interactive REPL with multi-line + error recovery          |
| P5  | Wasm target                         | 4e    | P1         | Done: T4.13 `zig build wasm`, 207KB, wasmtime verified                 |
| P6  | Directory restructuring             | 4f    | —          | Done: T4.14/15 — src/repl/ created, wasm_rt/gc/ unified                |
