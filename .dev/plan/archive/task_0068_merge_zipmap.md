# T9.1: merge, merge-with, zipmap

## Goal

Add three high-frequency map operations as Zig-level builtins:

- `merge` — merge multiple maps left-to-right
- `merge-with` — merge with custom conflict-resolution function
- `zipmap` — create map from key/value sequences

## Plan

1. **Red**: Write failing test for `merge` (two maps)
2. **Green**: Implement `mergeFn` in collections.zig
3. **Red**: Test `merge` with nil args, empty maps, overlapping keys
4. **Green**: Handle edge cases
5. **Red**: Write failing test for `merge-with`
6. **Green**: Implement `mergeWithFn` — calls user function on key conflict
7. **Red**: Write failing test for `zipmap`
8. **Green**: Implement `zipmapFn`
9. **Refactor**: Clean up, update builtins array + registry count
10. Update vars.yaml status

## References

- Beta: src/builtin/collections.zig (merge, merge-with, zipmap)
- Clojure: clojure.core/merge, merge-with, zipmap

## Log

- RED: merge test (undeclared identifier) → GREEN: implemented mergeFn
- RED: merge nil/overlapping tests → GREEN: all pass (nil handling, key override)
- RED: merge-with test (undeclared identifier) → GREEN: implemented mergeWithFn
- RED: zipmap basic/unequal/empty tests → GREEN: implemented zipmapFn
- REFACTOR: Added 3 BuiltinDef entries, updated registry count 88→91
- All tests pass. vars.yaml updated.
