# T9.5.1: VM evalStringVM fn_val lifetime fix

## Problem

In `evalStringVM` (bootstrap.zig:125-133), each form gets its own Compiler.
`defer compiler.deinit()` frees fn_protos and fn_objects after VM.run().
But `def` stores fn_val into Env (Namespace -> Var -> root), creating a
use-after-free when the next form references the previously defined function.

Single form works: `(def f (fn [x] x))` OK.
Multi form crashes: `(def f (fn [x] x)) (f 5)` -> corrupt value.

## Root Cause

Compiler.deinit() destroys:

- FnProto (code, constants, proto struct)
- Fn objects

But Env.Var.root may still hold a .fn_val pointing to these freed objects.

## Fix Strategy

Add `Compiler.transferOwnership()` that moves fn_protos and fn_objects lists
to the caller, clearing Compiler's lists so deinit() won't free them.
In `evalStringVM`, accumulate all transferred fn_protos/fn_objects across
the form loop and free them at the end (or let arena handle it).

Specifically:

1. Add `Compiler.detachFnAllocations()` -> returns owned fn_protos/fn_objects slices
2. In evalStringVM, collect detached allocations in local ArrayLists
3. After the loop, free accumulated allocations (defer)
4. Compiler.deinit() still frees chunk/locals but NOT fn objects (already detached)

## Plan

1. RED: Write test in bootstrap.zig - multi-form evalStringVM with def + call
2. GREEN: Add detachFnAllocations() to Compiler, use in evalStringVM
3. REFACTOR: Clean up, verify existing tests pass

## Log

- RED: Added test "evalStringVM - def fn then call across forms (T9.5.1)" — confirmed crash (signal 6)
- GREEN: Added Compiler.detachFnAllocations() to transfer fn_proto/fn_object ownership to caller.
  Modified evalStringVM to accumulate detached allocations across form loop, freeing at function exit.
  Added chunk_mod import to bootstrap.zig.
- Tests: All pass including new test with multiple defs + cross-form calls.
- REFACTOR: Code is clean; no further refactoring needed.
