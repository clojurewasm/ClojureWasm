# T6.0: Phase 6 Planning — Core Library Expansion

**Goal**: Expand clojure.core with frequently-used functions and macros
to improve real-world usability. Address deferred items F9 (empty?),
F10 (range), and add essential utilities.

## Context

After Phase 5 (Benchmark System), the implementation has:

- 101 vars implemented (of ~695 total in clojure.core)
- All tests passing
- Dual backend (TreeWalk primary, VM with hybrid dispatch)
- Benchmark baseline recorded

The next priority is expanding the standard library for practical use.

## Plan

### Phase 6a: Essential Missing Builtins (Zig-level)

| #   | Task                                                     | Scope                                                          |
| --- | -------------------------------------------------------- | -------------------------------------------------------------- |
| 6.1 | Sequence utilities: range, repeat, iterate               | range (0-3 arity), repeat, iterate — all eager (lazy deferred) |
| 6.2 | Collection queries: empty?, contains?, keys, vals        | Simple type dispatch on collections                            |
| 6.3 | Collection builders: hash-set, sorted-map, zipmap        | New collection construction                                    |
| 6.4 | Numeric functions: abs, max, min, quot, rand, rand-int   | Math operations                                                |
| 6.5 | String functions: subs, name, namespace, keyword, symbol | String manipulation + coercion                                 |

### Phase 6b: Core Library Expansion (core.clj)

| #    | Task                                                                                   | Scope                   |
| ---- | -------------------------------------------------------------------------------------- | ----------------------- |
| 6.6  | Assoc/update family: assoc-in, update, update-in, get-in, select-keys                  | Deep nested ops         |
| 6.7  | Predicate/search: some, every?, not-every?, not-any?, distinct, frequencies            | Higher-order predicates |
| 6.8  | Sequence transforms: partition, partition-by, group-by, flatten, interleave, interpose | Advanced seq ops        |
| 6.9  | Function combinators: partial, comp, juxt, memoize, trampoline                         | Function composition    |
| 6.10 | Utility macros: doto, as->, cond->, cond->>, if-let, when-let, some->, some->>         | Threading + binding     |

### Phase 6c: Validation

| #    | Task                         | Scope                                                                |
| ---- | ---------------------------- | -------------------------------------------------------------------- |
| 6.11 | SCI Tier 2 test expansion    | Add tests for all new functions, targeting 30+ additional test cases |
| 6.12 | Benchmark re-run + recording | Verify no regression, measure impact of new functions                |

## References

- Clojure cheatsheet: most commonly used functions
- Beta implementation: reference for Zig-level builtins
- `.dev/checklist.md` F9 (empty?), F10 (range)

## Log

- Phase 6 planning started
- Reviewed current state: 101 vars, 594 todo, all tests passing
- Created Phase 6 plan with 12 tasks across 3 sub-phases
- Moving to T6.1 implementation
