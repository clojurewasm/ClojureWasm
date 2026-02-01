# Task 3.3: VM recur + tail_call opcodes

## Goal

Implement `recur` and `tail_call` opcode handlers in the VM,
enabling loop/recur and tail-call support.

## Context

- Compiler emits `recur` with arg_count operand + `jump_back` to loop start
- TreeWalk uses recur_pending flag + recur_args buffer
- VM returns InvalidInstruction for both opcodes
- Beta encodes `(base_offset << 8) | arg_count` in recur operand

## Design

### Compiler changes

1. Track `loop_locals_base: u16` (stack depth at loop binding start)
2. Encode recur operand as `(loop_locals_base << 8) | arg_count`
3. `emitLoop`: save current sp_depth as loop_locals_base

Problem: current compiler doesn't track sp_depth. However, the number
of locals at the point of loop entry gives us base_offset.

Simpler approach: use `locals.items.len` at loop entry as base_offset.
This works because locals count == stack slots used at that point.

### VM recur handler

1. Decode: arg_count = operand & 0xFF, base_offset = (operand >> 8) & 0xFF
2. Pop arg_count values into temp buffer (reverse order)
3. Write to stack[frame.base + base_offset .. +arg_count]
4. Reset sp = frame.base + base_offset + arg_count
5. Next instruction is jump_back which loops

### VM tail_call handler

Minimal: same as regular call for now. Optimization deferred.

## Plan

1. Red: Test VM recur in simple loop
2. Green: Fix compiler operand encoding + implement VM recur handler
3. Red: Test VM recur with let inside loop body
4. Green: Ensure SP reset is correct
5. Red: Test EvalEngine compare with loop/recur
6. Green: Verify both backends match
7. Red: Test tail_call (minimal — same as call)
8. Green: Implement tail_call as call alias
9. Refactor: Clean up

## Log

- Red: test "VM compiler+vm: loop/recur counts to 5" — FAIL (InvalidInstruction)
- Green: Fix compiler emitRecur operand encoding (base_offset << 8 | arg_count)
- Green: Implement VM recur handler (decode, pop args, rebind, reset sp)
- Green: test "EvalEngine compare loop/recur" — both backends match
- Green: Implement tail_call as regular call (TCO deferred)
- Refactor: Extract performCall() helper to share call/tail_call logic
- All tests pass (331 total)
