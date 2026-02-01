# Task 3.2: VM var/def opcodes

## Goal

Implement `var_load`, `var_load_dynamic`, and `def` opcodes in the VM,
enabling Var resolution and definition at runtime. Required for non-intrinsic
builtin calls and all def-based variable binding.

## Context

- Compiler already emits `var_load` (for var_ref) and `def` (for def_node)
- TreeWalk handles both correctly via Env/Namespace
- VM currently returns `error.InvalidInstruction` for all three opcodes
- EvalEngine.runVM does not pass Env to VM

## Design

### VM changes (vm.zig)

1. Add `env: ?*Env` field to VM struct
2. Add `initWithEnv(allocator, env)` constructor
3. Implement `var_load` handler:
   - Read symbol from constants[operand]
   - Resolve via env.current_ns.resolve() / resolveQualified()
   - Push var.deref()
4. Implement `var_load_dynamic` handler:
   - Same as var_load (deref() already checks dynamic flag)
5. Implement `def` handler:
   - Pop init value from stack
   - Read symbol name from constants[operand]
   - env.current_ns.intern(name) -> Var
   - var.bindRoot(value)
   - Push symbol (ns/name) as return value

### EvalEngine changes (eval_engine.zig)

- Pass env to VM via initWithEnv when env is available

### Return value for def

Clojure's def returns the Var itself (#'ns/name), but our Value doesn't have
a var_val variant yet. For now, return a symbol `{ns: ns_name, name: sym_name}`
to match TreeWalk behavior.

## Plan

1. Red: Test VM var_load resolves a pre-defined Var
2. Green: Add env field + var_load handler
3. Red: Test VM var_load_dynamic works
4. Green: Add var_load_dynamic handler
5. Red: Test VM def creates and binds a Var
6. Green: Add def handler
7. Red: Test EvalEngine compare mode with def+var_ref
8. Green: Wire Env into EvalEngine.runVM
9. Refactor: Clean up, verify all tests pass

## Log

- Red: test "VM var_load resolves pre-defined Var" — FAIL (no initWithEnv)
- Green: Add env field, initWithEnv(), var_load handler (resolve via Env/Namespace)
- Red: test "VM def creates and binds a Var" — FAIL (InvalidInstruction)
- Green: Add def handler (pop value, intern, bindRoot, push symbol)
- Green: test "VM def then var_load round-trip" — passed immediately
- Red: test "EvalEngine compare def+var_ref" — FAIL (VM has no env)
- Green: Wire Env into EvalEngine.runVM via initWithEnv
- Green: test "VM var_load undefined var" and "without env" — error cases pass
- Green: test "VM var_load qualified symbol" — resolveQualified works
- Refactor: All tests pass (327 total), no leaks, code clean
