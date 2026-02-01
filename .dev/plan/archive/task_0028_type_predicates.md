# Task 3.7: Type Predicates

## Goal

Implement type predicate functions: nil?, number?, string?, keyword?,
symbol?, map?, vector?, seq?, fn?, boolean?, integer?, float?, set?, coll?

## Design

Simple type checks on Value tag. All are `runtime_fn` kind with BuiltinFn.
Each takes exactly 1 argument and returns a boolean.

## Plan

1. Create `builtin/predicates.zig` with implementations + BuiltinDef table
2. Add to registry
3. Tests: unit tests + TreeWalk + EvalEngine compare

## Log

- Created `builtin/predicates.zig` with 16 predicates: nil?, boolean?, number?, integer?, float?, string?, keyword?, symbol?, map?, vector?, seq?, fn?, set?, coll?, char?, not.
- All implemented as simple Value tag checks via shared `predicate()` helper.
- Registered in registry (total now 49 builtins).
- EvalEngine compare test: nil? produces matching results in both backends.
- All tests pass.
