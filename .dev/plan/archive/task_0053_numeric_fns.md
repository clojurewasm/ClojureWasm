# T6.4: Numeric Functions — abs, max, min, quot, rand, rand-int

**Goal**: Add commonly used numeric utility functions.

## Plan

### Functions to implement (in src/common/builtin/numeric.zig)

1. `abs` — absolute value (int or float)
2. `max` — maximum of 2+ numbers
3. `min` — minimum of 2+ numbers
4. `quot` — integer quotient (truncated division)
5. `rand` — random float [0, 1)
6. `rand-int` — random integer [0, n)

### Dual backend

All are runtime_fn, no VM opcodes needed.

## Log

- Created numeric.zig with abs, max, min, quot, rand, rand-int
- All tests pass (16 numeric tests)
- Registered in registry (83 total builtins)
- Updated vars.yaml
