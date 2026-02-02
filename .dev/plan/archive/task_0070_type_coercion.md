# T9.3: vec, set, into (improved), list\*

## Goal

Add type coercion builtins:

- `vec` — coerce collection to vector
- `set` — coerce collection to set
- `list*` — create list from args + trailing seq
- Improve `into` to handle map entries (conj [k v] pairs)

## Plan

1. **Red**: Test `vec` on list, nil
2. **Green**: Implement `vecFn`
3. **Red**: Test `set` on vector, list
4. **Green**: Implement `setFn`
5. **Red**: Test `list*`
6. **Green**: Implement `listStarFn`
7. **Refactor**: Register builtins, update counts

## Log

- RED: vec list→vector, nil→empty → GREEN: vecFn
- RED: set vector→set with dedup → GREEN: setCoerceFn
- RED: list\* with trailing coll → GREEN: listStarFn
- REFACTOR: 3 BuiltinDefs added, registry 94→97. All tests pass.
