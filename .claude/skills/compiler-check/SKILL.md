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

- [ ] **Push (+1)**: any instruction that places a value on the stack
  - `emitOp(.nil)`, `.true_val`, `.false_val`, `emit(.const_load, _)`,
    `emit(.local_load, _)`, `emit(.var_load, _)`, `emit(.closure, _)`
- [ ] **Pop (-1)**: any instruction that consumes a value
  - `emitOp(.pop)`, `emitOp(.throw_ex)`, `jump_if_false` (consumes test)
- [ ] **Binary ops (2 -> 1)**: `add`, `sub`, `mul`, `div`, `mod`, `rem_`,
      `lt`, `le`, `gt`, `ge`, `eq`, `neq` — net effect is `-= 1`
- [ ] **Call**: `emit(.call, N)` — net effect is `-= N` (pops callee + N args, pushes 1 result)
- [ ] **Recur**: `emit(.recur, _)` — pops arg_count values
- [ ] **pop_under(N)**: removes N values below top — `-= N`
- [ ] **def**: replaces top value with symbol — net 0, no depth change needed

### Branch Balance

- [ ] **if-then-else**: both branches produce identical net stack effect.
      Save `branch_base` before branches, reset `stack_depth` for else path.
- [ ] **try/catch**: normal and exception paths converge to same depth (`body_depth`).

### Scope Management

- [ ] **scope_depth**: `+= 1` and `-= 1` are always paired (let, loop, try-catch).
- [ ] **locals cleanup**: save `base_locals` before adding locals,
      call `shrinkRetainingCapacity(base_locals)` when scope ends.

### Loop Context

- [ ] **Save/restore**: `loop_start`, `loop_binding_count`, `loop_locals_base`
      must be saved before and restored after any construct that sets them.

### Sub-Compiler (fn compilation)

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
```

## User Instructions

$ARGUMENTS
