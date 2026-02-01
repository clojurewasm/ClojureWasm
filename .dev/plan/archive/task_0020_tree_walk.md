# Task 2.9: Create TreeWalk Evaluator (Reference Implementation)

## Goal

Implement a tree-walk evaluator that directly interprets Node AST to Value.
This serves as the "semantics reference implementation" (SS9.2) for --compare mode.
Correct behavior is the priority; performance is not a concern.

## References

- future.md SS9.2: Dual backend --compare mode
- decisions.md D6: TreeWalk from Phase 2
- Beta: src/runtime/evaluator.zig (~1200 lines)
- Beta: src/runtime/engine.zig (EvalEngine abstraction)

## Plan

### Scope

The TreeWalk evaluator directly interprets Node -> Value without bytecode.
It needs to handle all 14 Node variants that the current Analyzer produces.

### File location

`src/native/evaluator/tree_walk.zig`

### Design

TreeWalk struct holds allocator and Env pointer.
A run() method takes a Node pointer and returns a Value or error.
Local bindings are tracked in a stack-like array.

### Node handling

1. **constant** -> return value directly
2. **var_ref** -> resolve via Env namespace lookup
3. **local_ref** -> lookup in local bindings array
4. **if_node** -> run test, branch on truthiness
5. **do_node** -> run all statements, return last
6. **let_node** -> run bindings sequentially, run body with extended locals
7. **loop_node** -> like let but with recur support
8. **recur_node** -> compute args, signal Recur
9. **fn_node** -> create a closure Value (TreeWalkFn)
10. **call_node** -> run callee + args, dispatch call
11. **def_node** -> intern var in current namespace, bind value
12. **quote_node** -> return quoted Value
13. **throw_node** -> run expr, return error
14. **try_node** -> run body, catch/finally

### Key difference from VM

- No bytecode compilation step
- Local bindings stored in a dynamic array (not fixed slots)
- Closures capture the entire local binding array
- Recur implemented via sentinel error + retry loop

### Arithmetic builtins

TreeWalk needs to handle calls to builtin arithmetic ("+", "-", "\*", "/", "<", ">", "<=", ">=").
These are resolved as var_ref in the Node AST. The evaluator will check for known builtin names
and dispatch to Zig implementations.

### TDD steps

1. Red: constant node
2. Red: if_node
3. Red: do_node
4. Red: let_node
5. Red: fn_node + call_node (simple function)
6. Red: var_ref with Env lookup (def_node)
7. Red: arithmetic builtins (+, -, \*, /)
8. Red: comparison builtins (<, >, <=, >=)
9. Red: loop_node + recur_node
10. Red: closures (fn capturing locals)
11. Red: quote_node
12. Red: throw_node + try_node
13. Refactor: extract helpers, clean up

## Log

- Created `src/native/evaluator/tree_walk.zig` with TreeWalk struct
- TDD step 1: constant node — Green
- TDD step 2: if_node, do_node — Green
- TDD step 3: let_node, local_ref, quote_node — Green
- TDD step 4: fn_node, call_node, var_ref, def_node, arithmetic builtins,
  comparison builtins, loop/recur, closures, throw/try — Green
- Bug fix: callClosure resets local_count to 0 before restoring captured locals
  (fn body uses local_ref idx from 0, not relative to caller's frame)
- Bug fix: track allocated Fn objects in allocated_fns for proper cleanup
- All 306 tests pass (including 21 new TreeWalk tests)
