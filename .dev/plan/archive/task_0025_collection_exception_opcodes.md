# Task 3.4: VM collection + exception opcodes

## Goal

Implement collection construction (list_new, vec_new, map_new, set_new)
and exception handling (try_begin, catch_begin, try_end, throw_ex) in the VM.

## Context

- Collection opcodes: pop N values, create collection, push result
- Exception opcodes: handler stack for try/catch, throw unwinds to handler
- Compiler already emits all these opcodes correctly
- TreeWalk has full implementations for reference
- Beta also has InvalidInstruction for collections but full exception handling

## Design

### Collection opcodes (vm.zig)

Each opcode: pop N values from stack, allocate collection, push.

- list_new: operand = element count, allocate PersistentList
- vec_new: operand = element count, allocate PersistentVector
- map_new: operand = pair count (pop pair_count\*2 values), allocate PersistentArrayMap
- set_new: operand = element count, allocate PersistentHashSet

Memory: use VM allocator. GC cleanup deferred.

### Exception opcodes (vm.zig)

Add handler stack (ExceptionHandler array) to VM struct.

- try_begin: push handler with catch_ip, saved_sp, saved_frame_count
- catch_begin: pop handler (try body succeeded, skip to end)
- try_end: marker (nop)
- throw_ex: pop value, find handler, restore state, push exception, jump to catch

### VM struct additions

- `handlers: [HANDLERS_MAX]ExceptionHandler`
- `handler_count: usize`
- `allocated_lists: ArrayList(...)` etc. for cleanup (or use arena)

## Plan

1. Red: Test VM list_new
2. Green: Implement collection opcodes
3. Red: Test VM try/catch basic
4. Green: Implement exception opcodes
5. Red: Test throw without handler
6. Green: Return error on unhandled throw
7. Red: EvalEngine compare tests
8. Green: Verify parity
9. Refactor

## Log

- Red: test "VM vec_new", "VM list_new", "VM map_new" — FAIL (InvalidInstruction)
- Green: Implement buildCollection() helper + 4 collection opcodes
- Red: test "VM try/catch handles throw" — FAIL (InvalidInstruction)
- Green: Add ExceptionHandler struct + handler stack, implement try_begin/catch_begin/try_end/throw_ex
- Green: test "VM throw without handler returns UserException"
- Green: test "VM set_new creates set", "VM empty vec_new"
- All tests pass (338 total), no leaks
