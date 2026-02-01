# Deferred Work Checklist

Compact list of deferred items extracted from `.dev/notes/decisions.md`.
Check this at session start to catch items that become relevant.

Last updated: 2026-02-02 (after T4.8)

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID  | Item                                        | Trigger                                              | Source |
| --- | ------------------------------------------- | ---------------------------------------------------- | ------ |
| F1  | NaN boxing (Value optimization)             | fib(30) < 500ms target or memory pressure            | D1     |
| F2  | Real GC (replace arena)                     | Long-running REPL or memory benchmarks exceed bounds | D2     |
| F3  | Ratio type (`1/3`)                          | SCI tests fail on float precision loss               | D12    |
| F4  | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                | D9     |
| F5  | swap! with fn_val (closure dispatch)        | User reports or SCI tests require it                 | D8     |
| F6  | Multi-thread dynamic bindings               | Native multi-thread target                           | D11    |
| F7  | Macro body serialization (AOT blocker)      | T4.7 AOT bytecode startup                            | D18    |

## Phase 4 task priorities

| ID  | Item                                | Phase | Depends on | Notes                                                            |
| --- | ----------------------------------- | ----- | ---------- | ---------------------------------------------------------------- |
| P1  | VM parity with Phase 3 features     | 4b    | —          | variadic arith, predicates, inc/dec not in VM                    |
| P2  | core.clj AOT pipeline (T3.11/T3.12) | 4c    | P1         | build.zig custom step, @embedFile                                |
| P3  | Missing language features           | 4d    | —          | destructuring, try/catch, for, protocols (multi-arity done T4.8) |
| P4  | REPL                                | 4e    | —          | Currently stub (version print only)                              |
| P5  | Wasm target                         | 4e    | P1         | wasm32-wasi build, test on wasmtime                              |
| P6  | Directory restructuring             | 4f    | —          | Create src/repl/, src/wasm/ stubs per README                     |
