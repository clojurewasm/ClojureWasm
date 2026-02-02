# T9.2: sort, sort-by, compare

## Goal

Add sorting and comparison builtins:

- `compare` — generic comparison returning -1, 0, 1
- `sort` — sort a collection using natural ordering
- `sort-by` — sort by a keyfn

## Plan

1. **Red**: Test for `compare` (integers, strings, keywords)
2. **Green**: Implement `compareFn` using Value.compare
3. **Red**: Test for `sort` (vector of integers)
4. **Green**: Implement `sortFn` using insertion sort or std.mem.sort
5. **Red**: Test for `sort-by`
6. **Green**: Implement `sortByFn`
7. **Refactor**: Update builtins, registry count

## Implementation Notes

- compare: should work across types like Clojure — numbers, strings, keywords
- sort: returns a list (like Clojure), uses compare semantics
- sort-by: calls keyfn on each element, then sorts by key
- Need Value.compare method or compareFn internal helper
- std.mem.sort requires comptime fn — need runtime comparison wrapper

## Log

- RED: compare integers/strings → GREEN: compareValues + compareFn
- RED: sort integers/empty → GREEN: sortFn with sortUnstable
- RED: sort-by keyfn → GREEN: sortByFn with index-based sort
- REFACTOR: 3 BuiltinDefs added, registry count 91→94
- All tests pass. vars.yaml updated.
