# Deferred Work Checklist

Compact list of deferred items extracted from `.dev/notes/decisions.md`.
Check this at session start to catch items that become relevant.

Last updated: 2026-02-03 (T15.0 — vars.yaml Audit)

## Invariants (always enforce)

- [ ] D3: No threadlocal / global mutable state (Env is instantiated)
  - **Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5) — module-level, single-thread only. realize_fn and atom.call_fn removed by D36 deep refactor (direct import of bootstrap.callFnVal)
- [ ] D6: New features must be in both TreeWalk and VM + EvalEngine.compare() test
  - **Known exceptions**: defmulti, defmethod, lazy-seq — TreeWalk only (D28)
- [ ] D10: All code in English (identifiers, comments, commits)

## Blocked until needed

| ID      | Item                                             | Trigger                                                                                | Source  |
| ------- | ------------------------------------------------ | -------------------------------------------------------------------------------------- | ------- |
| F1      | NaN boxing (Value optimization)                  | fib(30) < 500ms target or memory pressure                                              | D1      |
| F2      | Real GC (replace arena)                          | Long-running REPL or memory benchmarks exceed bounds                                   | D2      |
| F3      | Ratio type (`1/3`)                               | SCI tests fail on float precision loss                                                 | D12     |
| F4      | Persistent data structures (HAMT, RRB-Tree)      | Collection benchmarks show bottleneck                                                  | D9      |
| ~~F5~~  | ~~swap! with fn_val (closure dispatch)~~         | ~~Resolved: T9.5.2 — atom.call_fn dispatcher~~                                         | D8      |
| F6      | Multi-thread dynamic bindings                    | Native multi-thread target                                                             | D11     |
| F7      | Macro body serialization (AOT blocker)           | T4.7 AOT bytecode startup                                                              | D18     |
| ~~F8~~  | ~~TreeWalk→VM reverse dispatch~~                 | ~~Resolved: T10.2 — bytecodeCallBridge in bootstrap.zig~~                              | D22     |
| F13     | VM opcodes for defmulti/defmethod                | VM-only mode needs multimethod dispatch                                                | D28     |
| F14     | VM opcodes for lazy-seq/realize                  | VM-only mode needs lazy evaluation                                                     | D28     |
| ~~F19~~ | ~~Reader input validation (depth/size limits)~~  | ~~Resolved: T11.1b — Reader.Limits (depth/string/collection) + nREPL/CLI size checks~~ | SS14    |
| F20     | Safe point GC design                             | Real GC (F2) implementation start                                                      | SS5     |
| F21     | 3-layer separation (Memory/Exec/Opt)             | Introduction of fused reduce or optimization pass                                      | SS5     |
| ~~F22~~ | ~~compat_test.yaml introduction~~                | ~~Resolved: T12.9 — .dev/status/compat_test.yaml (70/74 SCI tests pass)~~              | SS10    |
| ~~F23~~ | ~~comptime Value variant verification~~          | ~~Resolved: T12.4 — Zig exhaustive switch IS the comptime verification (D46)~~         | SS3     |
| F24     | vars.yaml status refinement (stub/defer/partial) | When stub functions appear (T15.0 audit: done/todo/skip accurate, 269 done)            | SS10    |
| F25     | for macro :while modifier                        | for.clj tests (currently excluded)                                                     | T14.4   |
| F26     | for macro :let + :when combination               | for.clj tests (currently excluded) — :let followed by :when fails                      | T14.4   |
| F27     | case multiple test values syntax                 | control.clj tests (excluded) — (case x (1 2 3) :match :default) fails                  | T14.5   |
| F28     | case symbol matching                             | control.clj tests (excluded) — (case 'sym sym :match :default) fails                   | T14.5   |
| F29     | Empty list () truthy behavior                    | control.clj tests (excluded) — JVM: () is truthy, ClojureWasm: () is falsy             | T14.5   |
| F30     | if-let / if-not optional else clause             | control.clj tests (3-arg only) — JVM allows 2-arg, ClojureWasm requires 3-arg          | T14.5   |
| F31     | (and) returns true                               | logic.clj tests (excluded) — JVM: true, ClojureWasm: nil                               | T14.6   |
| F32     | reverse nil/[] returns empty list                | logic.clj tests (adjusted) — JVM: empty list (truthy), ClojureWasm: nil (falsy)        | T14.6   |
| F33     | Empty list () type predicates                    | predicates.clj tests (excluded) — list?/coll?/seq? return false for ()                 | T14.7   |
| F34     | seq returns proper seq type                      | predicates.clj tests (excluded) — (seq [1 2 3]) returns vector, not seq                | T14.7   |
| ~~F35~~ | ~~sequential? predicate~~                        | ~~Resolved: T16.8 — Zig builtin: list or vector~~                                      | T14.7   |
| ~~F36~~ | ~~associative? predicate~~                       | ~~Resolved: T16.8 — Zig builtin: map or vector~~                                       | T14.7   |
| ~~F37~~ | ~~ifn? predicate~~                               | ~~Resolved: T16.8 — Zig builtin: fn/keyword/map/set/vector/symbol~~                    | T14.7   |
| ~~F38~~ | ~~swap-vals! (returns [old new])~~               | ~~Resolved: T16.10 — Zig builtin: returns [old new] vector~~                           | T14.8   |
| ~~F39~~ | ~~reset-vals! (returns [old new])~~              | ~~Resolved: T16.10 — Zig builtin: returns [old new] vector~~                           | T14.8   |
| ~~F40~~ | ~~first/rest on set~~                            | ~~Resolved: T16.1 — added .set case to firstFn/restFn~~                                | T14.9   |
| F41     | first/rest on string                             | sequences.clj tests (excluded) — (first "a") fails                                     | T14.9   |
| ~~F43~~ | ~~ffirst function~~                              | ~~Resolved: T16.9 — (first (first x)) in core.clj~~                                    | T14.9   |
| ~~F44~~ | ~~nnext function~~                               | ~~Resolved: T16.9 — (next (next x)) in core.clj~~                                      | T14.9   |
| F45     | interleave 0-1 args                              | sequences.clj tests (excluded) — (interleave) and (interleave [1]) fail                | T14.9   |
| ~~F46~~ | ~~drop-last function~~                           | ~~Resolved: T16.9 — take-based in core.clj (no multi-coll map)~~                       | T14.9   |
| ~~F47~~ | ~~split-at / split-with~~                        | ~~Resolved: T16.9 — vector of [take/drop] pairs in core.clj~~                          | T14.9   |
| F48     | (range) infinite sequence                        | sequences.clj tests (excluded) — infinite range not supported                          | T14.9   |
| F49     | partition with step arg                          | sequences.clj tests (excluded) — (partition 2 3 coll) not supported                    | T14.9   |
| F50     | reductions function                              | sequences.clj tests (excluded) — not implemented                                       | T14.9   |
| F51     | shuffle function                                 | sequences.clj tests (excluded) — not implemented                                       | T14.9   |
| ~~F55~~ | ~~(= nil ()) returns true~~                      | ~~Resolved: T14.5.4 — empty list now self-evaluates~~                                  | T14.10  |
| ~~F56~~ | ~~(conj () ()) returns (nil)~~                   | ~~Resolved: T14.5.4 — empty list now self-evaluates~~                                  | T14.10  |
| ~~F57~~ | ~~Empty list comparison~~                        | ~~Resolved: T14.5.4 — empty list now self-evaluates~~                                  | T14.10  |
| ~~F58~~ | ~~Nested map destructuring~~                     | ~~Resolved: T17.5.2 — recursive expandBindingPattern in analyzer~~                     | T14.10  |
| F67     | Rest args + map destructuring                    | `(fn [& {:keys [x]}] x)` — keyword args pattern not supported                          | T15.2   |
| F68     | {:as x} on empty list returns ()                 | JVM: `(let [{:as x} '()] x)` → `{}`, ClojureWasm: `()` (not coerced to map)            | T15.2   |
| ~~F69~~ | ~~Keywords in :keys vector~~                     | ~~Resolved: already working — :keys accepts keywords and symbols~~                     | T15.2   |
| F70     | Namespaced keywords in :keys                     | `{:keys [:a/b]}` — namespaced keywords in :keys not supported                          | T15.2   |
| F71     | Namespaced symbols in :keys                      | `{:keys [a/b]}` — namespaced symbols for namespaced key lookup not supported           | T15.2   |
| F72     | Namespaced :syms destructuring                   | `{:syms [a/b]}` — namespaced symbol lookup in :syms not supported                      | T15.2   |
| F73     | Namespace-qualified :keys syntax                 | `{:a/keys [b]}` — shorthand for `{:keys [:a/b]}` not supported                         | T15.2   |
| F74     | Namespace-qualified :syms syntax                 | `{:a/syms [b]}` — shorthand for `{:syms [a/b]}` not supported                          | T15.2   |
| ~~F75~~ | ~~VM closure capture with named fn self-ref~~    | ~~Resolved: T15.5.1 — per-slot capture_slots array in FnProto (D56)~~                  | T15.4   |
| ~~F76~~ | ~~VM compiler stack_depth underflow with recur~~ | ~~No longer reproducible as of T16.7 — likely fixed by D56 closure capture~~           | T15.5   |
| ~~F77~~ | ~~VM user-defined macro expansion~~              | ~~Resolved: T16.6 — def_macro opcode preserves macro flag (D58)~~                      | T15.5   |
| F78     | with-meta on symbols                             | `(with-meta 'sym {:k v})` fails — symbol meta not supported                            | T15.5   |
| F79     | :syms map destructuring                          | `{:syms [a b]}` basic symbol key destructuring not implemented                         | T15.5   |
| F80     | find-keyword function                            | Needs keyword intern table to distinguish existing vs absent keywords                  | T16.3   |
| F81     | ::foo auto-resolved keyword                      | `::foo` should resolve to `:current-ns/foo` — reader needs Env access                  | T16.3   |
| F82     | Hierarchy system                                 | make-hierarchy, derive, underive, parents, ancestors, descendants                      | T16.5.1 |
| F83     | prefer-method / prefers                          | Multimethod dispatch preference resolution                                             | T16.5.1 |
| F85     | binding special form                             | Dynamic binding per-call-stack not implemented                                         | T16.5.2 |
| F86     | bound? takes var_ref not symbol                  | ClojureWasm bound? takes symbol, JVM takes var_ref                                     | T16.5.2 |
| F87     | #'var inside deftest body                        | Var quote resolves at analyze time, fails for deftest-local defs                       | T16.5.2 |
| F88     | ^:dynamic / ^:meta on def                        | Reader metadata on def special form not supported                                      | T16.5.2 |
| F89     | Analyzer rewrite for System/Math                 | `(System/nanoTime)` → `(__nano-time)` etc. — builtins exist but syntax routing missing | T17.6   |
| F90     | defn full implementation                         | No docstring, metadata, pre/post conditions, inline support                            | T17     |
| F91     | delay proper Value type                          | Map-based delay; upstream uses clojure.lang.Delay class                                | T17     |
| F92     | doseq :let/:when/:while and nesting              | Single binding only, no modifiers, no nested bindings                                  | T17     |
| F93     | condp :>> modifier                               | Result-fn routing via `:>>` not supported                                              | T17     |
| F94     | Upstream Alignment pass                          | Replace UPSTREAM-DIFF implementations with upstream verbatim where deps available      | T17     |
| ~~F59~~ | ~~(pop nil) throws error~~                       | ~~Resolved: T14.5.5 — (pop nil) now returns nil~~                                      | T14.10  |
| ~~F60~~ | ~~() evaluates to nil~~                          | ~~Resolved: T14.5.4 — analyzer returns empty list for ()~~                             | T14.10  |
| ~~F61~~ | ~~keys/vals on non-maps throws error~~           | ~~Not a bug: Clojure JVM also throws on non-map input~~                                | T14.10  |
| ~~F62~~ | ~~reduce cannot iterate over set~~               | ~~Resolved: T14.5.2 — added set support to seqFn~~                                     | T14.10  |
| ~~F63~~ | ~~(set map) fails~~                              | ~~Resolved: T14.5.3 — added map support to setCoerceFn~~                               | T14.10  |
| ~~F64~~ | ~~(set string) fails~~                           | ~~Resolved: T14.5.3 — added string support to setCoerceFn~~                            | T14.10  |
| ~~F65~~ | ~~postwalk-replace on set literal fails~~        | ~~Resolved: T14.5.2 — fixed by adding set support to seqFn~~                           | T14.10  |
| ~~F66~~ | ~~assoc on vectors fails~~                       | ~~Resolved: T14.5.1 — added vector support to assocFn~~                                | T14.10  |
| ~~F9~~  | ~~`empty?` builtin~~                             | ~~Resolved: T6.1~~                                                                     | bench   |
| ~~F10~~ | ~~`range` builtin~~                              | ~~Resolved: T6.1~~                                                                     | bench   |
| ~~F11~~ | ~~TreeWalk stack depth limit~~                   | ~~Resolved: T7.1 — MAX_CALL_DEPTH=512 + heap alloc~~                                   | bench   |
| ~~F12~~ | ~~`str` fixed 4KB buffer~~                       | ~~Resolved: T7.2 — Writer.Allocating (dynamic)~~                                       | bench   |
| ~~F15~~ | ~~VM evalStringVM fn_val use-after-free~~        | ~~Resolved: T9.5.1 — Compiler.detachFnAllocations~~                                    | D32     |
| ~~F16~~ | ~~seq on map (MapEntry)~~                        | ~~Resolved: T9.5.3 — seqFn + firstFn/restFn map support~~                              | D32     |
| ~~F17~~ | ~~VM loop/recur wrong results~~                  | ~~Resolved: T10.1 — emitLoop used pop instead of pop_under~~                           | T9.5.4  |
| ~~F18~~ | ~~Nested fn use-after-free in compiler~~         | ~~Resolved: T10.3 — detachFnAllocations in compileArity~~                              | D35     |

## Phase 4 task priorities (historical — all complete)

| ID  | Item                                | Phase | Status                                                                 |
| --- | ----------------------------------- | ----- | ---------------------------------------------------------------------- |
| P1  | VM parity with Phase 3 features     | 4b    | Done: T4.1-4.4 (variadic arith, predicates, collection ops, string/IO) |
| P2  | core.clj AOT pipeline (T3.11/T3.12) | 4c    | Partial: T4.6 evalStringVM done. T4.7 AOT embed deferred (needs F7)    |
| P3  | Missing language features           | 4d    | Done: multi-arity T4.8, destructuring T4.9, for T4.10, protocols T4.11 |
| P4  | REPL                                | 4e    | Done: T4.12 interactive REPL with multi-line + error recovery          |
| P5  | Wasm target                         | 4e    | Done: T4.13 `zig build wasm`, 207KB, wasmtime verified                 |
| P6  | Directory restructuring             | 4f    | Done: T4.14/15 — src/repl/ created, wasm_rt/gc/ unified                |
