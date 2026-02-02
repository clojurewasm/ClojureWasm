# T8.R3: Arithmetic/Comparison Helper Consolidation

## Goal

Unify arithmetic/comparison helpers across arithmetic.zig and vm.zig.
Fix wrapping operator bug (+%, -%, _% -> +, -, _) in arithmetic.zig.

## Changes

### arithmetic.zig (single source of truth)

- Made `toFloat`, `binaryArith`, `compareFn` public
- Added public `ArithOp`, `CompareOp` enum types
- Added public `binaryDiv`, `binaryMod`, `binaryRem` helpers
- Fixed wrapping operators: `+%` -> `+`, `-%` -> `-`, `*%` -> `*`
- `divFn`, `modFn`, `remFn` now delegate to shared helpers

### vm.zig (consumer)

- Imported `arith` module
- Replaced `binaryArith`, `binaryCompare`, `binaryMod`, `binaryRem`,
  `numToFloat`, `ArithOp`, `CmpOp` with thin wrappers calling `arith.*`
- ~50 lines removed

## Verification

- `zig build test` — all green
- CLI: `(+ 1 2 3)` => 6, `(apply + [1 2 3])` => 6
- Benchmark: fib_recursive — 611ms (no significant regression)

## Log

1. Verified green baseline (post T8.R2)
2. Made arithmetic.zig helpers public, fixed wrapping ops
3. Added binaryDiv/binaryMod/binaryRem public helpers
4. Replaced VM private helpers with calls to arithmetic module
5. All tests green, CLI verified, benchmark clean
6. Recorded D30 in decisions.md
