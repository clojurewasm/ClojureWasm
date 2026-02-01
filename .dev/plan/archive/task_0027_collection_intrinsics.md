# Task 3.6: Collection Intrinsics

## Goal

Implement core collection operations as builtin functions accessible from
both TreeWalk and VM backends: first, rest, cons, conj, assoc, get, nth, count.

## Design

These functions are `runtime_fn` kind (not vm_intrinsic — no dedicated opcodes).
They are called via the standard `call` opcode path: `var_load` -> args -> `call`.

### Implementation strategy

1. Add BuiltinDef entries to registry (new `builtin/collections.zig`)
2. Add `BuiltinFn` type to BuiltinDef — function pointer for runtime dispatch
3. Implement each function in `builtin/collections.zig`
4. TreeWalk: resolve via Env, dispatch via Var's BuiltinFn
5. VM: `var_load` resolves Var, `call` dispatches BuiltinFn
6. EvalEngine compare tests

### Key change: BuiltinFn in BuiltinDef

Until now, BuiltinDef had no `func` field. Now we need it for runtime dispatch.

```zig
pub const BuiltinFn = *const fn (allocator: Allocator, args: []const Value) anyerror!Value;

pub const BuiltinDef = struct {
    name: []const u8,
    kind: VarKind,
    func: ?BuiltinFn = null,  // null for special forms
    // ... metadata fields
};
```

### Var root binding for builtins

When `registerBuiltins()` encounters a BuiltinDef with `func != null`, it:

1. Creates a Value representing the builtin function
2. Binds it as the Var's root

For this, Value needs a `.builtin_fn` variant, or we reuse `.fn_val` with
a special proto marker.

Decision: Add `builtin_fn` Value variant — simplest, cleanest.

## Plan

### Step 1: Add BuiltinFn to BuiltinDef + builtin_fn Value variant

### Step 2: Update registerBuiltins to bind func as root

### Step 3: Implement collection functions in builtin/collections.zig

### Step 4: TreeWalk dispatch for builtin_fn values

### Step 5: VM dispatch for builtin_fn values

### Step 6: EvalEngine compare tests

## Log

- Step 1: Added `BuiltinFn` type to var.zig, `func: ?BuiltinFn = null` field to BuiltinDef, `builtin_fn` variant to Value union with formatPrStr/eql support.
- Step 2: Updated `registerBuiltins()` to bind `builtin_fn` as Var root when `func != null`.
- Step 3: Implemented 8 collection functions in `builtin/collections.zig`: first, rest, cons, conj, assoc, get, nth, count. All registered as `runtime_fn` kind with func pointers.
- Step 4: Added `callBuiltinFn()` to TreeWalk — evaluates args then dispatches via BuiltinFn pointer. Tests: first and count via registry.
- Step 5: Added `builtin_fn` dispatch to VM's `performCall()` — pops args from stack, calls func, pushes result.
- Step 6: EvalEngine compare tests: count and first both produce matching results in TreeWalk and VM.
- Registry now has 33 builtins (12 arithmetic + 13 special forms + 8 collections).
- All tests pass.
