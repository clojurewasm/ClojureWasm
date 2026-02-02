# T9.5.2: swap! with fn_val (closure dispatch)

## Problem

`swap!` only accepts `builtin_fn`, not `fn_val` (user closures).
`(swap! a (fn [x] (+ x 1)))` fails with TypeError.

## Root Cause

BuiltinFn signature `fn(Allocator, []const Value) anyerror!Value` has no
evaluator context. Calling fn_val requires TreeWalk.callValue or VM dispatch.

## Fix Strategy

Add a module-level fn_val dispatcher to atom.zig (same pattern as
macro_eval_env in bootstrap.zig — D3 known exception, single-thread only).
Set it during evalString/evalStringVM bootstrap.

1. Add `var call_fn: ?CallFnType = null` to atom.zig
2. In swapBangFn, dispatch fn_val via call_fn
3. In bootstrap.zig, set atom.call_fn before eval
4. TreeWalk sets it to tw.callValue, VM sets it to macroEvalBridge

## Plan

1. RED: Change test "swap! - type error on fn_val" to expect success
2. GREEN: Add call_fn dispatcher, wire up in bootstrap
3. REFACTOR: Clean up

## Log

- RED: Added test "swap! with fn_val closure (T9.5.2)" — confirmed EvalError (TypeError from swap!)
- GREEN: Added atom.call_fn module-level dispatcher (CallFnType). Set in setupMacroEnv alongside
  macro_eval_env and realize_fn. swap! now dispatches fn_val via call_fn when set.
- Tests: All pass — basic fn_val swap! + extra args fn_val swap!
- REFACTOR: Updated swap! docstring.
