# T9.9: not-empty, every-pred, some-fn, fnil

## Goal

Add predicate and function utility functions to core.clj:

- `not-empty` — returns coll if non-empty, else nil
- `every-pred` — combines predicates with and
- `some-fn` — combines predicates with or
- `fnil` — wraps fn to replace nil args with defaults

## Plan

1. Red/Green for each function with tests
2. Update vars.yaml

## Log

- Added not-empty, every-pred, some-fn, fnil to core.clj
- Tests for all four pass. some-fn returns false (not nil) for all-falsy case.
- All tests pass, no regressions
- vars.yaml updated: not-empty, every-pred, some-fn, fnil → done
