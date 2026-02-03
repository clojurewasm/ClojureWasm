# T12.4: Reduced — reduced, reduced?, unreduced, ensure-reduced

Phase: 12a (Tier 1 Zig Builtins)
Status: in-progress

## Scope

New Value variant `.reduced` + 4 builtins:

1. **reduced** — `(reduced x)`: wraps x for early termination in reduce
2. **reduced?** — `(reduced? x)`: returns true if x is a Reduced value
3. **unreduced** — `(unreduced x)`: unwraps if Reduced, else returns x
4. **ensure-reduced** — `(ensure-reduced x)`: wraps if not already Reduced

Also: update core.clj `reduce` to check for Reduced early termination.

## Design

- Add `reduced: *const Reduced` to Value union
- Reduced struct: `{ value: Value }` (heap-allocated via pointer)
- F23: The Zig compiler's exhaustive switch enforcement is the comptime
  verification mechanism. Adding a new variant will cause compile errors
  wherever `else =>` is NOT used, forcing us to handle it.
- For formatPrStr: print as the inner value (Reduced is transparent in output)
- For eql: compare inner values (Reduced wrapping is transparent)

## Plan

1. Add Reduced struct to value.zig
2. Add `.reduced` variant to Value union
3. Handle in formatPrStr, eql, isNil, and other Value methods
4. Write tests for 4 builtins (RED)
5. Implement reducedFn, isReducedPred, unreducedFn, ensureReducedFn (GREEN)
6. Register in BuiltinDef table
7. Update core.clj reduce to handle Reduced
8. EvalEngine compare tests
9. F23 verification (document that exhaustive switch covers it)
10. vars.yaml, commit gate

## Log

- Added Reduced struct to value.zig
- Added `.reduced` variant — 8 exhaustive switch errors (F23 verification!)
- Fixed all 8: value.zig, predicates.zig(x2), macro.zig, tree_walk.zig, nrepl.zig, main.zig
- RED: 7 tests for 4 builtins
- GREEN: reducedFn, isReducedPred, unreducedFn, ensureReducedFn in predicates.zig
- Registered in BuiltinDef table (31 → 35 in predicates, 133 → 137 total)
- Updated core.clj reduce to check reduced? for early termination
- CLI verified: (reduce ... (reduced acc) ...) terminates correctly
- D46: F23 resolved — Zig exhaustive switch IS comptime verification
- vars.yaml: 4 vars done (248 → 252/702)
