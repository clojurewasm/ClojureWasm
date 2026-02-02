# T9.8: butlast, last, second, nfirst, fnext

## Goal

Add convenience sequence accessor functions to core.clj:

- `last` — last element of a collection
- `butlast` — all but last element
- `second` — second element (= first of next)
- `nfirst` — next of first (= next (first coll))
- `fnext` — first of next (= first (next coll))

## Plan

1. Red/Green for each function with tests in bootstrap.zig
2. Update vars.yaml

## Implementation Notes

- `last`: loop to end of seq
- `butlast`: take all but last
- `second`: (first (next coll))
- `nfirst`: (next (first coll))
- `fnext`: (first (next coll)) — same as second

## Log

- Added last, butlast, second, fnext, nfirst to core.clj
- Tests for all five functions pass in bootstrap.zig
- All tests pass, no regressions
- vars.yaml updated: last, butlast, second, fnext, nfirst → done
