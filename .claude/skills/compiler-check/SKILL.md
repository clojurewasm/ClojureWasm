---
name: compiler-check
description: >
  Verify compiler.zig modifications against the bytecode compiler checklist.
  Use after editing compiler.zig to catch stack_depth errors, missing cleanup,
  and dual-backend sync issues. Triggered automatically by PostToolUse hook.
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

# Compiler.zig Modification Checklist

Verify recent changes to `src/common/bytecode/compiler.zig` against this checklist.

## How to Use

1. Read the diff or recent edits to compiler.zig
2. For each modified emit method, verify every item below
3. Report any violations found

## Checklist

### Stack Depth Tracking

Every emit method must maintain correct `self.stack_depth`:

- [ ] **Push (+1)**: instructions that place a value on the stack
  - `emitOp(.nil)`, `.true_val`, `.false_val`
  - `emit(.const_load, _)`, `emit(.local_load, _)`, `emit(.var_load, _)`
  - `emit(.upvalue_load, _)`
  - `emit(.closure, _)` — also needs `capture_slots` (see Closures below)
  - `emitOp(.dup)`
- [ ] **Pop (-1)**: instructions that consume a value
  - `emitOp(.pop)`, `emitOp(.throw_ex)`
  - `jump_if_false` (consumes test value)
- [ ] **Binary ops (2 → 1)**: `add`, `sub`, `mul`, `div`, `mod`, `rem_`,
      `lt`, `le`, `gt`, `ge`, `eq`, `neq` — net effect is `-= 1`
- [ ] **Call**: `emit(.call, N)` — pops callee + N args, pushes 1 result.
      Net: `-= N`
- [ ] **Recur**: `emit(.recur, N)` — pops N arg values, jumps back
- [ ] **pop_under(N)**: removes N values below top — `-= N`
- [ ] **def / def_macro**: replaces top value with Var — net 0
- [ ] **Collection literals**: `list_new(N)`, `vec_new(N)`, `set_new(N)` pop
      N elements, push 1. `map_new(N)` pops 2N elements, pushes 1
- [ ] **defmulti**: stack [dispatch_fn] → [multi_fn] — net 0
- [ ] **defmethod**: stack [dispatch_val, method_fn] → [method_fn] — net -1
- [ ] **lazy_seq**: stack [thunk_fn] → [lazy_seq_value] — net 0

### Branch Balance

- [ ] **if-then-else**: both branches produce identical net stack effect.
      Save `branch_base` before branches, reset `stack_depth` for else path.
- [ ] **try/catch**: `try_begin` → body → `try_end` / `catch_begin` → handler → `try_end`.
      Normal and exception paths must converge to same depth.
      Exception path: catch_begin pushes exception value (+1 local).

### Scope Management

- [ ] **scope_depth**: `+= 1` and `-= 1` are always paired (let, loop, try-catch).
- [ ] **locals cleanup**: save `base_locals` before adding locals,
      call `shrinkRetainingCapacity(base_locals)` when scope ends.

### Loop Context

- [ ] **Save/restore**: `loop_start`, `loop_binding_count`, `loop_locals_base`
      must be saved before and restored after any construct that sets them.

### Closures

- [ ] **capture_slots**: per-slot array mapping captured variables to parent
      stack slots (D56). All arities share the same `capture_slots`.
- [ ] **Allocation transfer**: call `detachFnAllocations()` on sub-compiler
      and transfer results to parent before sub-compiler `deinit()`.

### Dual Backend Sync

- [ ] **New opcode**: if a new `OpCode` variant was added, implement the
      corresponding handler in `vm.zig` (`executeInstruction` switch).
- [ ] **Intrinsic tables**: if a new builtin is compiled as a direct opcode,
      add it to `variadicArithOp()` or `binaryOnlyIntrinsic()` as appropriate.
- [ ] **TreeWalk parity**: ensure `tree_walk.zig` handles the equivalent
      operation via its builtin dispatch.
- [ ] **EvalEngine test**: add a `compare()` test to verify both backends
      produce the same result for the new feature.

## Verification

```bash
zig build test -- "EvalEngine"
./zig-out/bin/cljw --dump-bytecode -e '(your-expression)'
```

Use `--dump-bytecode` to visually inspect compiled bytecode when stack
depth or control flow looks wrong.

## User Instructions

$ARGUMENTS
