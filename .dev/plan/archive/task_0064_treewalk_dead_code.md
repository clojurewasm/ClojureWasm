# T8.R1: TreeWalk Dead Code Removal (D26 Sentinel Dispatch)

## Goal

Remove ~180 lines of dead code from `tree_walk.zig` that remained after D26
abolished sentinel dispatch. This code was unreachable in normal operation
but created confusion for future maintenance.

## Removed Code

| Code                                        | Purpose (obsolete)                 |
| ------------------------------------------- | ---------------------------------- |
| `builtinLookup()`                           | Sentinel name -> keyword lookup    |
| `isBuiltin()`                               | Keyword sentinel type check        |
| `isBuiltin(callee)` branch in `runCall()`   | Sentinel dispatch entry point      |
| env-less fallback in `resolveVar()`         | builtinLookup when env was null    |
| `callBuiltin()`, `variadicArith/Cmp/Eq()`   | Sentinel-based arithmetic dispatch |
| `ArithOp`, `arith()`, `arithDiv()`, `CmpOp` | Private arithmetic helpers         |
| `cmp()`, `arithMod()`, `arithRem()`         | Private comparison/mod helpers     |
| `numToFloat()`                              | Private float conversion           |

## Test Updates

22 tests were updated from env-less `TreeWalk.init()` pattern to
Env+registry pattern (`TreeWalk.initWithEnv()` with `registerBuiltins()`):

- 7 TreeWalk tests (arithmetic, subtraction, multiplication, division,
  comparison, loop/recur, closure captures locals)
- 15 EvalEngine compare tests (arithmetic, division, mod, equality,
  loop/recur, variadic add/mul/sub/div)

## Verification

- `zig build test` — all green
- CLI: `(+ 1 2 3)` => 6, `(apply + [1 2 3])` => 6
- Benchmark: fib_recursive — 563ms (no regression)

## Log

1. Verified green baseline
2. Removed dead code (~180 lines) from tree_walk.zig
3. Fixed 15 EvalEngine tests to use Env+registry pattern
4. Fixed 7 TreeWalk tests to use Env+registry pattern
5. All tests green, CLI verified, benchmark clean
6. Updated D26 in decisions.md ("remains" -> "removed in T8.R1")
