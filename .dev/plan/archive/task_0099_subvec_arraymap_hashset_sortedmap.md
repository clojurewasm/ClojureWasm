# T12.2: subvec, array-map, hash-set, sorted-map

Phase: 12a (Tier 1 Zig Builtins)
Status: in-progress

## Scope

4 collection constructors/utilities as Zig builtins:

1. **subvec** — `(subvec v start)` or `(subvec v start end)`: vector slice
2. **array-map** — `(array-map & kvs)`: create map from key-value pairs (preserves insertion order)
3. **hash-set** — `(hash-set & vals)`: create set from values
4. **sorted-map** — `(sorted-map & kvs)`: create sorted map

## Design Decisions

- **array-map**: Identical to hash-map in our implementation since PersistentArrayMap
  already preserves insertion order. Both create PersistentArrayMap.
- **sorted-map**: Simple implementation — create PersistentArrayMap with entries
  sorted by key using existing compare infrastructure. Not a tree-based structure
  (matches Beta's approach). D## entry needed.
- **subvec**: Copy-based slice (not view-based) matching Beta. Creates a new
  PersistentVector with duplicated items.
- **hash-set**: Create PersistentHashSet from args, deduplicating via contains check.

## Plan

1. RED: Write failing tests for all 4 builtins in collections.zig
2. GREEN: Implement subvecFn, arrayMapFn, hashSetFn, sortedMapFn
3. Register in BuiltinDef table + update registry test count (126 → 130)
4. Add EvalEngine.compare() tests
5. Update vars.yaml (4 vars → done)
6. Commit gate checks

## Log

- RED: Wrote 13 failing tests (4 subvec, 3 array-map, 3 hash-set, 3 sorted-map)
- GREEN: Implemented subvecFn, arrayMapFn, hashSetFn, sortedMapFn
- Registered in BuiltinDef table (31 → 35 in collections, 126 → 130 total)
- Added 3 EvalEngine compare tests (subvec, hash-set, sorted-map)
- CLI verification: all 4 builtins produce correct output
- D45: sorted-map design decision recorded
- vars.yaml: 4 vars marked done (241 → 245/702)
