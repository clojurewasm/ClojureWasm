# Task 2.5: Define OpCode Enum

## Goal

Define OpCode enum and Instruction struct in `src/common/bytecode/opcodes.zig`.
Fixed 3-byte format: u8 opcode + u16 operand.
Start with ~30 essential opcodes needed for Phase 2 VM.

## References

- Beta: `src/compiler/bytecode.zig` (543L) — full OpCode enum with 60+ opcodes
- Roadmap: Task 2.5 — "Fixed 3-byte instructions (u8 opcode + u16 operand)"
- future.md SS2 (Phase 2: Native VM)

## Plan

### What to implement

1. **OpCode enum(u8)** — ~30 essential opcodes grouped by category:
   - Constants/Literals: const_load, nil, true_val, false_val
   - Stack: pop, dup
   - Locals: local_load, local_store
   - Upvalues: upvalue_load, upvalue_store
   - Vars: var_load, var_load_dynamic, def
   - Control flow: jump, jump_if_false, jump_back
   - Functions: call, tail_call, ret, closure
   - Loop/recur: recur
   - Collections: list_new, vec_new, map_new, set_new
   - Arithmetic: add, sub, mul, div
   - Comparison: lt, le, gt, ge
   - Exception: try_begin, catch_begin, try_end, throw_ex
   - Debug: nop, debug_print

2. **Instruction struct** — op: OpCode + operand: u16
   - signedOperand() for jump offsets

3. **OpCode helper methods**:
   - hasOperand() — returns true if the opcode uses the operand field
   - name() — returns human-readable name (@tagName wrapper)

### Category ranges (same as Beta)

```
0x00-0x0F: Constants/Literals
0x10-0x1F: Stack operations
0x20-0x2F: Local variables
0x30-0x3F: Upvalues (closures)
0x40-0x4F: Var operations
0x50-0x5F: Control flow
0x60-0x6F: Functions
0x70-0x7F: Loop/recur
0x80-0x8F: Collection construction
0xA0-0xAF: Exception handling
0xB0-0xBF: Arithmetic/comparison
0xF0-0xFF: Reserved/debug
```

### Deferred from Beta

- Optimized variants (int_0, int_1, local_load_0..3, call_0..3, scope_exit)
- Collection operations (nth, get, first, rest, conj, assoc, count, lazy_seq)
- Metadata (with_meta, meta)
- Advanced Var ops (def_macro, defmulti, defmethod, defprotocol, extend_type_method, def_doc)
- jump_if_true, jump_if_nil (only jump_if_false needed initially)
- swap (stack), inc/dec (arithmetic)
- closure_multi, letfn_fixup, loop_start
- finally_begin

These can be added incrementally when the compiler/VM needs them.

### TDD steps

1. Red: Test OpCode values are in correct ranges
2. Green: Define OpCode enum with explicit u8 values
3. Red: Test Instruction creation and signedOperand
4. Green: Define Instruction struct
5. Red: Test hasOperand classification
6. Green: Implement hasOperand
7. Refactor: Ensure file layout matches convention

### No dependencies

OpCode is a pure data definition. No imports from value.zig or other modules needed.
(Unlike Beta, we separate opcodes from Chunk/FnProto — those go in later tasks.)

## Log

- Red: Wrote test for 30 OpCode category ranges -> compile error (only nop defined)
- Green: Defined all 30 opcodes in OpCode enum with explicit u8 values
- Red: Wrote test for Instruction signedOperand + OpCode.hasOperand -> compile error
- Green: Added signedOperand() to Instruction, hasOperand() to OpCode
- Refactor: File layout confirmed (imports -> pub types -> tests). Clean.
- All tests pass. 30 opcodes across 11 categories, matching Beta ranges.
