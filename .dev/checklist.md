# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5), bootstrap.last_thrown_exception — module-level, single-thread only
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID  | Item                                        | Trigger                                                            |
| --- | ------------------------------------------- | ------------------------------------------------------------------ |
| F1  | NaN boxing (Value optimization)             | fib(30) < 500ms target or memory pressure                         |
| F2  | Real GC (replace arena)                     | Long-running REPL or memory benchmarks exceed bounds               |
| F3  | Ratio type (`1/3`)                          | SCI tests fail on float precision loss                             |
| F4  | Persistent data structures (HAMT, RRB-Tree) | Collection benchmarks show bottleneck                              |
| F6  | Multi-thread dynamic bindings               | Native multi-thread target                                        |
| F7  | Macro body serialization (AOT blocker)      | T4.7 AOT bytecode startup                                         |
| F20 | Safe point GC design                        | Real GC (F2) implementation start                                  |
| F21 | 3-layer separation (Memory/Exec/Opt)        | Introduction of fused reduce or optimization pass                  |
| F24 | vars.yaml status refinement                 | When stub functions appear                                         |
| F80 | find-keyword function                       | Needs keyword intern table                                         |
| F82 | Hierarchy system                            | derive, underive, parents, ancestors, descendants                  |
| F83 | prefer-method / prefers                     | Multimethod dispatch preference resolution                         |
| F87 | #'var inside deftest body                   | Var quote resolves at analyze time, fails for deftest-local defs   |
| F94 | Upstream Alignment pass                     | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
