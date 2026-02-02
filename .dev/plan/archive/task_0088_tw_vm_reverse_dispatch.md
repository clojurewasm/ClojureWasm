# T10.2 — Unified fn_val proto: TreeWalk→VM reverse dispatch (F8)

## Problem

When VM calls a core.clj HOF (e.g., `map`), the TreeWalk-compiled `map` closure
receives a VM-compiled callback (e.g., `(fn [x] (* x x))`). TreeWalk's `callValue`
and `runCall` blindly cast `fn_val.proto` to `*const Closure`, causing a segfault
because the proto is actually `*const FnProto` (bytecode).

VM→TreeWalk direction already works via `fn_val_dispatcher` / `macroEvalBridge`.
The reverse direction (TreeWalk→VM) is missing.

## Plan

### 1. Add `bytecode_dispatcher` callback to TreeWalk struct

Symmetric with VM's `fn_val_dispatcher`:

```zig
// TreeWalk struct field:
bytecode_dispatcher: ?*const fn (Allocator, Value, []const Value) anyerror!Value = null,
```

### 2. Guard `callValue` and `runCall` with `fn_val.kind` check

In `callValue` — when `fn_val.kind == .bytecode`, use `bytecode_dispatcher` callback
instead of casting to Closure.

In `runCall` — same guard before the existing `@ptrCast` to Closure.

### 3. Implement `bytecodeCallBridge` in bootstrap.zig

Similar to `macroEvalBridge` but goes TreeWalk→VM:

```zig
fn bytecodeCallBridge(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    var vm = VM.initWithEnv(allocator, macro_eval_env.?);
    defer vm.deinit();
    vm.fn_val_dispatcher = &macroEvalBridge; // VM may call back to TreeWalk
    // Push fn + args onto stack, performCall, return result
    ...
}
```

### 4. Wire up: set `tw.bytecode_dispatcher = &bytecodeCallBridge` in bootstrap.zig

Wherever TreeWalk is created in bootstrap.zig (macroEvalBridge, evalString), set
the dispatcher.

### 5. Tests

- EvalEngine compare test: `(map (fn [x] (* x x)) [1 2 3])` -> `(1 4 9)`
- Direct test: VM-compiled fn called through TreeWalk
- Benchmark: `bench/benchmarks/05_map_filter_reduce/bench.clj` should work

## Log

### Red

- Added test `evalStringVM - TreeWalk→VM reverse dispatch (T10.2)` in bootstrap.zig
- Test crashes with signal 6 (segfault via abort) — confirmed Red

### Green

1. Added `bytecode_dispatcher` callback field to TreeWalk struct (symmetric with VM's fn_val_dispatcher)
2. Guarded `callValue` and `runCall` with `fn_ptr.kind == .bytecode` check
3. Implemented `bytecodeCallBridge` in bootstrap.zig — creates temp VM, pushes fn+args, calls performCall+execute
4. Made VM's `push`, `performCall`, `execute` public (needed by bridge)
5. Wired `tw.bytecode_dispatcher = &bytecodeCallBridge` in macroEvalBridge
6. Fixed pre-existing bug: named fn self-reference in callClosure created fn_val with default kind=.bytecode instead of .treewalk

### Validation

- All 750 tests pass (749 existing + 1 new)
- CLI: `(map (fn [x] (* x x)) [1 2 3 4 5])` → `(1 4 9 16 25)`
- Benchmark 05_map_filter_reduce runs successfully (was segfaulting before)
