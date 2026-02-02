# T9.7: partition-all, take-while, drop-while

## Goal

Add sequence slicing functions to core.clj:

- `partition-all` — like partition but includes final incomplete chunk
- `take-while` — takes elements while predicate is true
- `drop-while` — drops elements while predicate is true

## Plan

1. **Red**: Write test for `partition-all` in bootstrap.zig
2. **Green**: Add `partition-all` to core.clj
3. **Red**: Write test for `take-while` in bootstrap.zig
4. **Green**: Add `take-while` to core.clj
5. **Red**: Write test for `drop-while` in bootstrap.zig
6. **Green**: Add `drop-while` to core.clj
7. **Refactor**: Clean up if needed
8. Update vars.yaml

## Implementation Notes

- `partition-all`: Like existing `partition` but appends leftover chunk
- `take-while`: `(loop [s (seq coll) acc (list)] (if (and s (pred (first s))) (recur ...) (reverse acc)))`
- `drop-while`: `(loop [s (seq coll)] (if (and s (pred (first s))) (recur (next s)) s))`

## Log

- Added partition-all, take-while, drop-while to core.clj
- Tests for all three pass in bootstrap.zig
- All tests pass, no regressions
- vars.yaml updated: partition-all, take-while, drop-while → done
