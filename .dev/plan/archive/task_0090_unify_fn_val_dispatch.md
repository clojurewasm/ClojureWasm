# T10.4: Unify fn_val dispatch into single callFnVal

## Goal

Replace 5 scattered fn_val dispatch mechanisms with a single `callFnVal` entry point
in bootstrap.zig. Eliminates redundant module vars, Fn.kind default footgun, and
inconsistent kind-checking across call sites.

## Plan

### Analysis

Current 5 dispatch mechanisms (all do: call fn_val with args):

| #   | Location         | Type       | Kind check | Wired to           |
| --- | ---------------- | ---------- | ---------- | ------------------ |
| 1   | vm.zig:84        | Field      | Yes        | macroEvalBridge    |
| 2   | tree_walk.zig:63 | Field      | Yes        | bytecodeCallBridge |
| 3   | atom.zig:17      | Module var | No         | macroEvalBridge    |
| 4   | value.zig:100    | Module var | No         | macroEvalBridge    |
| 5   | analyzer.zig:36  | Field      | N/A        | macroEvalBridge    |

All converge on `macroEvalBridge` (bootstrap.zig:187). The new `callFnVal` will:

1. Check fn_val kind (bytecode vs treewalk)
2. Route bytecode → bytecodeCallBridge, treewalk → macroEvalBridge
3. Handle builtin_fn as well for completeness

### Steps

1. Create `callFnVal(allocator, fn_val, args) anyerror!Value` in bootstrap.zig
   - Handles all fn kinds: builtin_fn, fn_val(.bytecode), fn_val(.treewalk)
   - Uses existing macroEvalBridge and bytecodeCallBridge internally

2. Create a single module-level var `pub var call_fn_val: ?CallFnType = null` in bootstrap.zig
   - Set during evalString/evalStringVM initialization

3. Replace atom.zig `call_fn` → use bootstrap.call_fn_val
4. Replace value.zig `realize_fn` → use bootstrap.call_fn_val
5. Replace analyzer.zig `macro_eval_fn` field → use bootstrap.call_fn_val
6. Replace vm.zig `fn_val_dispatcher` field → use bootstrap.call_fn_val internally
7. Replace tree_walk.zig `bytecode_dispatcher` field → use bootstrap.call_fn_val internally
8. Run tests, verify all 748+ tests pass
9. Clean up: remove unused vars, callbacks, and wiring code

### Key constraint

- vm.zig and tree_walk.zig still need to know whether to dispatch to the other
  backend. But they can call `callFnVal` which handles the routing internally,
  instead of each maintaining its own callback.

## Log

### Implementation

Created `callFnVal` in bootstrap.zig as the unified dispatch entry point:

- `builtin_fn` -> direct call
- `fn_val(.bytecode)` -> bytecodeCallBridge (new VM instance)
- `fn_val(.treewalk)` -> treewalkCallBridge (renamed from macroEvalBridge)

All 5 callback sites now receive `&callFnVal`:

1. vm.zig `fn_val_dispatcher` <- `&callFnVal` (was `&macroEvalBridge`)
2. tree_walk.zig `bytecode_dispatcher` <- `&callFnVal` (was `&bytecodeCallBridge`)
3. atom.zig `call_fn` <- `&callFnVal` (was `&macroEvalBridge`)
4. value.zig `realize_fn` <- `&callFnVal` (was `&macroEvalBridge`)
5. analyzer.zig `macro_eval_fn` <- `&callFnVal` (was `&macroEvalBridge`)

Module var pattern retained (no circular import). The callback fields in
vm.zig/tree_walk.zig/analyzer.zig and module vars in atom.zig/value.zig
still exist but all point to the same function. Further removal would
require breaking circular imports which is not worth the complexity.

All 748+ tests pass. VM benchmarks verified (sieve works).
