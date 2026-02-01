# Task 2.7: Create VM Execution Loop

## Goal

Create a stack-based bytecode VM in `src/native/vm/vm.zig` that executes
compiled bytecode (Chunk). Instantiated design (D3), no threadlocal.

## References

- Beta: `src/vm/vm.zig` (1858L) — full VM with all opcodes
- Production: `src/common/bytecode/opcodes.zig` — 30 OpCodes
- Production: `src/common/bytecode/chunk.zig` — Chunk, FnProto
- Production: `src/common/bytecode/compiler.zig` — Compiler
- Production: `src/common/env.zig` — Env (global environment)
- Roadmap: "Stack-based VM. Start with: const_load, call, ret, jump, local_load/store, arithmetic"

## Plan

### Architecture

Single file `src/native/vm/vm.zig` with VM struct:
- Fixed-size stack array (Value[STACK_MAX])
- CallFrame stack (frames[FRAMES_MAX])
- Env reference for Var resolution
- execute() main loop with switch on OpCode

### Scope: Essential opcodes only

Phase 1 opcodes to implement:
1. Constants: const_load, nil, true_val, false_val
2. Stack: pop, dup
3. Locals: local_load, local_store
4. Control: jump, jump_if_false, jump_back
5. Functions: call, ret (closure deferred to Task 2.8)
6. Arithmetic: add, sub, mul, div, lt, le, gt, ge
7. Collections: list_new, vec_new, map_new, set_new (create literals)
8. Var: var_load, def
9. Debug: nop
10. Exceptions: throw_ex, try_begin, catch_begin, try_end (basic)

Deferred to Task 2.8: closure, upvalue_load/store, tail_call
Deferred: var_load_dynamic, recur, debug_print

### Key design decisions
- No threadlocal (D3): VM is an explicit struct, receives Env as parameter
- Arena GC (D2): VM uses Env's allocator, no GC safe points yet
- Arithmetic operates on integer/float Values directly (no type coercion framework yet)

### TDD steps

#### Part A: VM structure + constants
1. Red: Test VM.run with nil constant -> returns nil
2. Green: VM struct, run(), execute(), push/pop, const_load/nil/true/false

#### Part B: Stack + locals
3. Red: Test local_load/local_store
4. Green: Implement local_load/store with frame.base

#### Part C: Control flow
5. Red: Test jump_if_false (if expression)
6. Green: Implement jump/jump_if_false/jump_back

#### Part D: Arithmetic
7. Red: Test add/sub on integers
8. Green: Implement add/sub/mul/div with int/float dispatch
9. Red: Test comparison lt/gt
10. Green: Implement lt/le/gt/ge

#### Part E: Var operations
11. Red: Test def + var_load
12. Green: Implement def (intern Var in Env) + var_load

#### Part F: Function call
13. Red: Test call + ret (simple function)
14. Green: Implement call (push frame) + ret (pop frame)

#### Part G: Collections
15. Red: Test vec_new
16. Green: Implement list_new/vec_new/map_new/set_new

## Log

### Part A: VM structure + constants
- Red: 5 tests (nil, true/false, const_load, pop, dup) -> VM not defined
- Green: VM struct with stack, frames, push/pop/peek, execute loop
  - Constants: const_load, nil, true_val, false_val
  - Stack: pop, dup

### Part B-D: Locals, control flow, arithmetic
- Red: 8 more tests (local_load, if true/false, add/sub/mul, lt/gt, float, mixed)
- Green: All pass
  - Locals: local_load, local_store (frame.base-relative)
  - Control: jump, jump_if_false, jump_back (signed operand)
  - Arithmetic: add/sub/mul/div with int fast path, float promotion
  - Comparison: lt/le/gt/ge -> boolean result
  - nop, debug_print (pop and discard)

### Summary
- 13 VM tests covering: constants, stack ops, locals, if/else branching,
  integer arithmetic, float arithmetic, mixed int/float, comparisons, nop
- Deferred: call/ret (function frames), var_load/def, collections, closures,
  exceptions, recur (these require Env integration or more complex setup)
