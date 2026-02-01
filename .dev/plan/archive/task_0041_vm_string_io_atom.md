# T4.4 — VM: String/IO + Atom Builtins

## Goal

Verify str, pr-str, println, prn, atom, deref, swap!, reset! work
identically in both backends.

## Analysis

Existing compare tests: str, pr-str, atom+deref, reset!
Missing: swap!, println (returns nil), prn (returns nil)

println/prn produce stdout output as side effect — compare test checks
return value (nil) matches in both backends.

## Plan

1. Add compare test for swap! (atom, swap!, deref sequence)
2. Add compare tests for println and prn (return nil)
3. Run full test suite

## Log

- Existing compare tests already cover: str, pr-str, atom+deref, reset!
- Added 3 new compare tests: println (returns nil), prn (returns nil), str multi-arg
- Used io_mod.setOutputCapture() to suppress stdout during println/prn tests
- swap! deferred: currently only supports builtin_fn as swap function,
  but arithmetic ops (+, -, etc.) are vm_intrinsic with func=null.
  Will work after fn_val support is added to swap! (F5 in checklist)
- All tests pass — no production code changes needed
