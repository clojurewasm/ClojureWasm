---
paths:
  - src/common/bytecode/compiler.zig
---

# Compiler.zig Modification Checklist

Before committing changes to compiler.zig, verify every item below.

## Stack Depth Tracking

Every emit method must maintain correct `self.stack_depth`:

- **Push (+1)**: `nil`, `true_val`, `false_val`, `const_load`, `local_load`,
  `var_load`, `upvalue_load`, `closure`, `dup`
- **Pop (-1)**: `pop`, `throw_ex`, `jump_if_false` (consumes test)
- **Binary ops (2 → 1)**: `add`, `sub`, `mul`, `div`, `mod`, `rem_`,
  `lt`, `le`, `gt`, `ge`, `eq`, `neq` — net `-= 1`
- **Call**: `emit(.call, N)` — net `-= N` (pops callee + N args, pushes 1)
- **Recur**: `emit(.recur, N)` — pops N arg values
- **pop_under(N)**: removes N values below top — `-= N`
- **def / def_macro**: net 0
- **Collection literals**: `list_new(N)`, `vec_new(N)`, `set_new(N)` pop N push 1.
  `map_new(N)` pops 2N push 1
- **defmulti**: [dispatch_fn] → [multi_fn] — net 0
- **defmethod**: [dispatch_val, method_fn] → [method_fn] — net -1
- **lazy_seq**: [thunk_fn] → [lazy_seq_value] — net 0

## Branch Balance

- **if-then-else**: both branches must produce identical net stack effect.
  Save `branch_base`, reset `stack_depth` for else path.
- **try/catch**: `try_begin` → body → `try_end` / `catch_begin` → handler → `try_end`.
  Normal and exception paths converge to same depth.

## Scope Management

- **scope_depth**: `+= 1` and `-= 1` always paired (let, loop, try-catch).
- **locals cleanup**: save `base_locals`, `shrinkRetainingCapacity(base_locals)` on exit.

## Loop Context

- **Save/restore**: `loop_start`, `loop_binding_count`, `loop_locals_base`
  must be saved before and restored after any construct that sets them.

## Closures

- **capture_slots**: per-slot array mapping captured vars to parent stack slots (D56).
  All arities share the same `capture_slots`.
- **Allocation transfer**: `detachFnAllocations()` on sub-compiler before `deinit()`.

## Dual Backend Sync

- **New opcode** → implement in `vm.zig` (`executeInstruction` switch)
- **New intrinsic** → add to `variadicArithOp()` or `binaryOnlyIntrinsic()`
- **TreeWalk parity** → ensure `tree_walk.zig` handles via builtin dispatch
- **EvalEngine test** → `compare()` test for both backends

## Verification

```bash
zig build test -- "EvalEngine"
./zig-out/bin/cljw --dump-bytecode -e '(expression)'
```
