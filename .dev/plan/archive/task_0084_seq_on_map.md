# T9.5.3: seq on map (MapEntry)

## Problem

`(seq {:a 1})` returned TypeError. Maps had no seq support, blocking
map iteration via HOFs.

## Fix

Added `.map` case to `seqFn` in collections.zig: converts flat entries
array to list of 2-element vectors `[k v]`. Also added `.map` cases to
`firstFn` and `restFn` that delegate through `seqFn`.

## Plan

1. RED: Unit tests in collections.zig (seq on map, seq on empty map)
2. GREEN: Add .map case to seqFn, firstFn, restFn
3. Integration test in bootstrap.zig

## Log

- RED: Added "seq on map returns list of entry vectors" + "seq on empty map returns nil" tests — confirmed TypeError
- GREEN: Added .map handler in seqFn (flat entries -> list of [k v] vectors)
  Added .map handlers in firstFn/restFn delegating through seqFn
- Integration test: count, vector?, first on maps all pass
- All 747+ tests pass
