# T6.1: Sequence Utilities — range, repeat, iterate, empty?, contains?, keys, vals

**Goal**: Add fundamental sequence/collection functions as Zig builtins.

## Plan

### Zig builtins to add (in src/common/builtin/sequences.zig)

1. `range` — 0-3 arity: `(range)` = error, `(range n)` = 0..n, `(range start end)`, `(range start end step)`
   - Returns a PersistentList (eager, not lazy)
   - Integer output when all args are integers
2. `repeat` — `(repeat n x)` = list of n copies of x
3. `iterate` — `(iterate f x n)` = take n from iterate (eager, extra arity for limit)
   - Clojure's iterate is lazy; ours needs a limit parameter
4. `empty?` — `(empty? coll)` = true if count is 0 (resolves F9)
5. `contains?` — `(contains? coll key)` = map has key, vector has index, set has member
6. `keys` — `(keys map)` = list of keys
7. `vals` — `(vals map)` = list of values

### Implementation order (TDD)

1. empty? (simplest, resolves F9)
2. range (highest value, resolves F10)
3. repeat
4. contains?
5. keys, vals
6. iterate (most complex)

### Dual backend

All are runtime_fn (BuiltinFn dispatch), so both TreeWalk and VM handle
them identically through var_load + call. No VM opcodes needed.

## Log

- Created sequences.zig with empty? (Green)
- Added range with 1-3 arity support (Green)
- Added repeat (n, x) -> list (Green)
- Added contains? for map/set/vector (Green)
- Added keys, vals for map (Green)
- All 6 functions registered in registry, all tests pass
- Updated vars.yaml (6 vars: done)
- Resolved F9 (empty?), F10 (range) in checklist
- Skipped iterate (better as core.clj with take+loop)
