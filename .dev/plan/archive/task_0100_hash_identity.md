# T12.3: hash, identical?, ==

Phase: 12a (Tier 1 Zig Builtins)
Status: in-progress

## Scope

3 builtins for hash & identity:

1. **hash** — `(hash x)`: return integer hash code for any value
2. **identical?** — `(identical? x y)`: reference/value identity check
3. **==** — `(== x y)`: numeric equality (only numbers, unlike `=` which is structural)

## Design

- **hash**: Polynomial rolling hash (×31) for strings/keywords/symbols.
  Integers return themselves. Floats multiply by large prime. nil → 0,
  booleans → Java constants 1231/1237. Collections → 42 (simple placeholder).
  hash-combine deferred per roadmap.
- **identical?**: For value types (nil, bool, int, float, char) → bit equality.
  For pointer types (string, list, vec, map, set, fn, atom) → pointer equality.
  Keywords → name+ns comparison (interned semantics).
- **==**: Only defined for numbers. Non-numeric args → error.
  Cross-type int/float comparison like `=` but restricted to numbers.

## Plan

1. RED: Write failing tests for hash, identical?, ==
2. GREEN: Implement hashFn, identicalPred, numericEqFn in predicates.zig
3. Register in BuiltinDef table
4. Update registry count (130 → 133)
5. Add EvalEngine compare tests
6. vars.yaml update
7. Commit gate

## Log

- RED: Wrote 13 failing tests (6 hash, 5 identical?, 4 ==)
- GREEN: Implemented hashFn, identicalPred, numericEqFn in predicates.zig
- Fixed: Symbol can't use == (struct), switched to name+ns comparison
- Registered in BuiltinDef table (28 → 31 in predicates, 130 → 133 total)
- Added 2 EvalEngine compare tests (hash, ==)
- CLI verification: all 3 builtins work correctly
- vars.yaml: 3 vars marked done (245 → 248/702)
