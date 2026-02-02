# T9.0: Phase 9 Planning — Core Library Expansion III

## Goal

Plan Phase 9: implement high-frequency missing functions to increase
clojure.core coverage from 155/695 (22%) toward ~200+ (29%+).

Focus on functions that real Clojure programs use most often,
prioritizing pure-Clojure (core.clj) implementations where possible.

## Plan

### Phase 9a: Essential Collection Operations (Zig builtins)

| #    | Task                                    | Notes                                          |
| ---- | --------------------------------------- | ---------------------------------------------- |
| T9.1 | merge, merge-with, zipmap               | Map merging — very high frequency              |
| T9.2 | sort, sort-by, compare                  | Sorting — needs Zig-level comparator           |
| T9.3 | vec, set, into (improved), list\*       | Type coercion — used everywhere                |
| T9.4 | meta, with-meta, vary-meta, alter-meta! | Metadata system — prerequisite for many things |

### Phase 9b: Core Library Expansion (core.clj)

| #    | Task                                    | Notes                                 |
| ---- | --------------------------------------- | ------------------------------------- |
| T9.5 | map-indexed, keep, keep-indexed, remove | High-frequency HOFs                   |
| T9.6 | mapv, filterv, reduce-kv                | Vector-returning variants + kv reduce |
| T9.7 | partition-all, take-while, drop-while   | Sequence slicing                      |
| T9.8 | butlast, last, second, nfirst, fnext    | Convenience accessors                 |
| T9.9 | not-empty, every-pred, some-fn, fnil    | Predicate/function utilities          |

### Phase 9c: Control Flow + Utility Macros

| #     | Task                          | Notes                  |
| ----- | ----------------------------- | ---------------------- |
| T9.10 | while, doseq, doall, dorun    | Imperative iteration   |
| T9.11 | case, condp, declare, defonce | Missing control macros |
| T9.12 | delay, force, realized?       | Delayed evaluation     |

### Phase 9d: Misc Builtins

| #     | Task                                            | Notes                             |
| ----- | ----------------------------------------------- | --------------------------------- |
| T9.13 | boolean, true?, false?, some?, any?             | Basic predicates (Zig builtins)   |
| T9.14 | bit-and, bit-or, bit-xor, bit-not, bit-shift-\* | Bitwise operations (Zig builtins) |
| T9.15 | type, class, instance?, isa?                    | Type introspection                |

### Estimated var count increase

- Phase 9a: ~12 vars (Zig builtins)
- Phase 9b: ~15 vars (core.clj functions)
- Phase 9c: ~10 vars (core.clj macros)
- Phase 9d: ~15 vars (Zig builtins)
- Total: ~52 new vars → ~207 done (30%)

### Dependencies

- T9.4 (metadata) is a prerequisite for many advanced features
- T9.2 (sort) needs a Zig-level generic comparator
- Most core.clj tasks only depend on existing builtins

## Log

- Phase 9 planning created. Ready to start with T9.1 (merge/merge-with/zipmap).
