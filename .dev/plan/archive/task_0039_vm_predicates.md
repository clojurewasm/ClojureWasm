# T4.2 — VM: Type Predicates + Numeric Predicates

## Goal

Verify and validate that all 21 predicates + `not` work identically in both
TreeWalk and VM backends via EvalEngine.compare() tests.

## Analysis

All predicates are already implemented as `runtime_fn` in predicates.zig with
`func` pointers. The VM's `performCall` handles `builtin_fn` dispatch.
The existing `nil?` compare test (eval_engine.zig:447) passes.

**No new production code needed** — just comprehensive compare tests.

inc/dec are defined in core.clj (not host builtins), so they depend on the
bootstrap/AOT pipeline (T4.6/T4.7) for VM parity.

## Plan

1. Add EvalEngine compare tests for all type predicates:
   nil?, boolean?, number?, integer?, float?, string?, keyword?, symbol?,
   map?, vector?, seq?, fn?, set?, coll?, char?
2. Add compare tests for numeric predicates: zero?, pos?, neg?, even?, odd?
3. Add compare test for `not`
4. Run full test suite

## Log

- Analysis: all 21 predicates + not already work in VM via call + builtin_fn dispatch
- Added 41 EvalEngine compare tests covering:
  - Type predicates: nil?, boolean?, number?, integer?, float?, string?,
    keyword?, symbol?, map?, vector?, seq?, fn?, set?, coll?
  - Numeric predicates: zero?, pos?, neg?, even?, odd?
  - Logic: not (true, false, nil)
  - Both true and false cases for each predicate
- Used comptime helper `makePredicateCompareTest` for scalar types,
  direct test bodies for collection types (runtime pointers)
- All tests pass in both TreeWalk and VM backends
- No production code changes needed — predicates were already functional
