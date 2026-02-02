# T10.1: Fix VM loop/recur wrong results (F17)

## Goal

Fix the VM loop/recur bug where loop returns the wrong binding value
instead of the body result.

## Root Cause

`emitLoop` in compiler.zig uses `pop` N times to clean up loop bindings
after the body. This pops the body result off the stack first, then the
bindings — leaving the wrong value (first binding) on top.

Compare with `emitLet` which uses `pop_under` to keep the body result
on top while removing bindings beneath it.

## Fix

Change `emitLoop` cleanup from:

```
for (0..locals_to_pop) pop   // pops body result first!
```

to:

```
pop_under locals_to_pop      // keeps body result, removes bindings
```

## Plan

1. RED: Write test — `(loop [i 0 a 0 b 1] (if (= i 25) a (recur (+ i 1) b (+ a b))))` should return 75025
2. GREEN: Fix emitLoop to use pop_under instead of pop
3. RED: Write test — `(loop [i 0 sum 0] (if (= i 10) sum (recur (+ i 1) (+ sum i))))` should return 45
4. Verify with `zig build test`
5. Run benchmarks to confirm fib_loop and arith_loop produce correct results

## Log

- Confirmed root cause: emitLoop used `pop` N times (discards body result first)
  while emitLet correctly uses `pop_under` (keeps body result, removes bindings beneath)
- Existing 1-binding test passed by accident (x=5 is both the binding AND the result)
- RED: Added multi-binding test (fib with 3 bindings: i, a, b)
- GREEN: Changed emitLoop cleanup from `pop` loop to single `pop_under`
- Added arith_loop pattern test (2 bindings: i, sum)
- All 749 tests pass
- CLI verification: fib_loop=75025, arith_loop=499999500000 (both correct)
