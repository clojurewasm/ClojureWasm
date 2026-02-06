# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5), bootstrap.last_thrown_exception, keyword_intern.table, collections._vec_gen_counter (24C.4) — module-level, single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID  | Item                                        | Trigger                                                            |
| --- | ------------------------------------------- | ------------------------------------------------------------------ |
| F1  | NaN boxing (Value optimization)             | Phase 24C.6 — Babashka parity target                              |
| ~~F2~~  | ~~Real GC (replace arena)~~             | Done: Phase 23, MarkSweepGc (D69, D70)                            |
| F3  | Ratio type (`1/3`)                          | SCI tests fail on float precision loss                             |
| F4  | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                              |
| F6  | Multi-thread dynamic bindings               | Native multi-thread target                                        |
| F7  | Macro body serialization (AOT blocker)      | T4.7 AOT bytecode startup                                         |
| ~~F20~~ | ~~Safe point GC design~~                | Done: Phase 23.4, VM/REPL safe points (D70)                       |
| F21 | 3-layer separation (Memory/Exec/Opt)        | Introduction of fused reduce or optimization pass                  |
| F24 | vars.yaml status refinement                 | When stub functions appear                                         |
| ~~F80~~ | ~~find-keyword function~~                | Done: 22c.5, keyword_intern.zig                                   |
| F94 | Upstream Alignment pass                     | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
| F95 | VM intrinsic ns awareness                   | :exclude of +,-,*,/ in refer-clojure ineffective on VM backend     |
| ~~F97~~ | ~~GC double-free in sieve benchmark~~    | Resolved: stack overflow from deep lazy-seq realization (512MB stack + meta tracing fix) |
| F98 | fib_recursive ReleaseFast anomaly            | 487ms Release > 205ms Debug — investigate Zig optimizer interaction |
| F99 | Iterative lazy-seq realization engine       | Wasm stack is limited (~1MB). Current realize→realizeMeta→seqFn mutual recursion uses ~381KB/frame (Debug) per nesting level. Phase 25 (Wasm) will need heap-based work stack to replace call stack recursion. |
| F100 | nested_update regression from hot bootstrap | D73 hot recompilation causes 42→72ms regression via cache/allocator side effects. Investigate: could lazy bytecode compilation or GPA compaction recover the 30ms. |
| ~~F96~~ | ~~VM protocol compilation~~             | Done: defprotocol/extend-type in compiler.zig + vm.zig + bootstrap.zig |
