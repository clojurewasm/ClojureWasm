# T9.10: while, doseq, doall, dorun

## Goal

Add imperative iteration macros/functions to core.clj:

- `while` — loop while condition is true (side-effect loop, needs atom)
- `doseq` — iterate over seq for side effects
- `doall` — force all elements of lazy seq, return seq
- `dorun` — force all elements of lazy seq, return nil

## Plan

1. Red/Green for each
2. Update vars.yaml

## Implementation Notes

- `while`: Not straightforward in pure Clojure without loop+recur and mutable state.
  In standard Clojure, while uses a loop that evaluates the test each iteration.
  Can be done as macro: `(loop [] (when test (do body) (recur)))`
- `doseq`: macro that expands to loop+recur over seq (simplified, single binding)
- `doall`: `(defn doall [coll] (dorun coll) coll)` or force via count
- `dorun`: Walk entire seq for side effects

## Log

- Added while, doseq, doall, dorun to core.clj
- while: macro expanding to loop+when+recur
- doseq: macro with single binding, loop over seq
- doall/dorun: functions that walk seq
- Note: swap! only works with builtin fns (F5), tests use `(swap! a + 1)`
- All tests pass, no regressions
- vars.yaml updated: while, doseq, doall, dorun → done
