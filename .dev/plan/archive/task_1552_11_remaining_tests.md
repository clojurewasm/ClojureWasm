# T15.5.2-11: Remaining Test Files Dual-Backend Verification

## Summary

All 11 test files verified on both VM and TreeWalk backends.
New features implemented: ns :require/:use, require, use, refer, alias builtins.

## Results

| File                | VM Tests | VM Assert | TW Tests | TW Assert | Notes                           |
| ------------------- | -------- | --------- | -------- | --------- | ------------------------------- |
| core_test.clj       | 71       | 264       | 72       | 267       | multimethod excluded (F13)      |
| for.clj             | 4        | 12        | 4        | 12        |                                 |
| control.clj         | 12       | 66        | 12       | 66        |                                 |
| logic.clj           | 6        | 80        | 6        | 80        |                                 |
| predicates.clj      | 20       | 143       | 20       | 143       |                                 |
| atoms.clj           | 14       | 39        | 14       | 39        |                                 |
| sequences.clj       | 33       | 188       | 33       | 188       |                                 |
| data_structures.clj | 17       | 203       | 17       | 203       |                                 |
| macros.clj          | 5        | 19        | 5        | 19        | ns :use; loop-recur excl (F76)  |
| special.clj         | 8        | 18        | 8        | 18        | :syms excl (F79); run-tests add |
| clojure_walk.clj    | 5        | 11        | 5        | 11        |                                 |
| **TOTAL**           | **195**  | **1043**  | **196**  | **1046**  |                                 |

## New features

- `require` builtin — sets up :as alias and :refer for pre-loaded namespaces
- `use` builtin — require + refer all
- `refer` builtin — refer vars from another namespace
- `alias` builtin — namespace alias
- `ns` macro expanded to process `:require` and `:use` references

## New F## items

- F76: VM compiler stack_depth underflow with recur in conditional
- F77: VM user-defined macro expansion
- F78: with-meta on symbols
- F79: :syms map destructuring
