# T9.11: case, condp, declare, defonce

## Goal

Add missing control flow macros to core.clj:

- `case` — constant-time dispatch on value
- `condp` — binary predicate dispatch
- `declare` — forward declaration of vars
- `defonce` — define only if not already bound

## Plan

1. Red/Green for each
2. Update vars.yaml

## Implementation Notes

- `case`: Expand to cond with = checks (not truly constant-time, but correct behavior)
- `condp`: `(condp pred expr clause...)` where each clause is `test result`
- `declare`: `(defmacro declare [& names] (cons 'do (map (fn [n] (list 'def n)) names)))`
- `defonce`: `(defmacro defonce [name init] ...check if var exists...)`
  May need a `bound?` or `resolve` check. Could use try/catch approach.

## Log

- Added case, condp, declare to core.clj
- case: cond-based dispatch with default clause support
- condp: predicate-based dispatch (no quasiquote for pred, uses cons/list)
- declare: (do (def name) ...) for forward declarations
- defonce: deferred — needs bound? builtin (not implemented)
- All tests pass, no regressions
- vars.yaml updated: case, condp, declare → done; defonce → todo with note
