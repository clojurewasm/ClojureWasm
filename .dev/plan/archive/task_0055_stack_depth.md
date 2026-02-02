# T7.1: TreeWalk Stack Depth Fix (F11)

## Goal

Fix the stack overflow issue in TreeWalk for deep recursion (ack(3,6) etc.).

## Problem

TreeWalk's `callClosure` saves all 256 locals + 256 recur_args as stack
variables on each function call. Each call consumes ~8KB of Zig thread stack.
With macOS default 8MB stack, this limits recursion to ~1000 levels.

ack(3,6) requires ~512+ levels of non-tail recursion, which crashes.

## Plan

1. Add `call_depth` counter to TreeWalk with MAX_CALL_DEPTH = 4096
2. Add `StackOverflow` to TreeWalkError
3. Check depth in `callClosure`, increment/decrement with defer
4. Reduce per-frame stack usage: shrink saved_locals to only needed count
   (don't copy full MAX_LOCALS array onto stack — use sliced arrays)
5. Add test: deep recursion produces error, not crash
6. Add test: ack(3,6) works (if stack allows) or returns clear error

## Log

- Starting T7.1
- Root cause: run() and callClosure() stack frame sizes (saved_locals[256], arg_vals[256])
- Solution: heap-allocate saved_locals, saved_recur_args, arg_vals in callClosure/runCall/callBuiltinFn
- Added call_depth counter with MAX_CALL_DEPTH=512 and StackOverflow error
- Test: (deep 100) succeeds, (deep 520) returns EvalError
- All 656 tests pass
- DONE
