# T9.5: map-indexed, keep, keep-indexed, remove

## Goal

Add high-frequency HOFs as core.clj functions:

- `map-indexed` — (map-indexed f coll) applies (f index item)
- `keep` — (keep f coll) returns non-nil results of (f item)
- `keep-indexed` — (keep-indexed f coll)
- `remove` — (remove pred coll) complement of filter

## Plan

1. Add `remove` to core.clj (simplest — complement of filter)
2. Add `map-indexed` to core.clj
3. Add `keep` to core.clj
4. Add `keep-indexed` to core.clj
5. Test via CLI -e
6. Update vars.yaml

## Log

- Added remove, map-indexed, keep, keep-indexed to core.clj
- All verified in TreeWalk mode: correct output
- VM mode: closure bridge issue (F8) causes segfault for HOFs with user closures
- All unit tests pass. vars.yaml updated.
