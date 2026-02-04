# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5) — module-level, single-thread only
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
| F51 | shuffle function                            | not implemented                                                    |
| F68 | {:as x} on empty list returns ()            | JVM: `{}`, ClojureWasm: `()` (not coerced to map)                  |
| F70 | Namespaced keywords in :keys                | `{:keys [:a/b]}` not supported                                     |
| F71 | Namespaced symbols in :keys                 | `{:keys [a/b]}` not supported                                      |
| F72 | Namespaced :syms destructuring              | `{:syms [a/b]}` not supported                                      |
| F73 | Namespace-qualified :keys syntax            | `{:a/keys [b]}` not supported                                      |
| F74 | Namespace-qualified :syms syntax            | `{:a/syms [b]}` not supported                                      |
| F80 | find-keyword function                       | Needs keyword intern table                                         |
| F81 | ::foo auto-resolved keyword                 | Reader needs Env access for `:current-ns/foo`                      |
| F82 | Hierarchy system                            | derive, underive, parents, ancestors, descendants                  |
| F83 | prefer-method / prefers                     | Multimethod dispatch preference resolution                         |
| F86 | bound? takes var_ref not symbol             | ClojureWasm bound? takes symbol, JVM takes var_ref                 |
| F87 | #'var inside deftest body                   | Var quote resolves at analyze time, fails for deftest-local defs   |
| F89 | Analyzer rewrite for System/Math            | Builtins exist but syntax routing missing                          |
| F91 | delay proper Value type                     | Map-based delay; upstream uses clojure.lang.Delay class            |
| F94 | Upstream Alignment pass                     | Replace UPSTREAM-DIFF implementations with upstream verbatim       |
