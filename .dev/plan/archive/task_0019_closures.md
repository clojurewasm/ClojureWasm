# Task 2.8: Implement Closures and Upvalues in VM

## Goal

Enable function creation, function calls, and closure capture.
After this task, the following should work via hand-crafted bytecode:

- Simple function call: `((fn [x] x) 42)` -> 42
- Closure capture: `((fn [x] (fn [y] (+ x y))) 1 2)` -> 3  (conceptual)
- Named fn self-reference for recursion

## Context

- OpCodes already defined: `closure` (0x68), `call` (0x60), `ret` (0x67),
  `upvalue_load` (0x30), `upvalue_store` (0x31)
- `FnProto` exists in chunk.zig with `capture_count` field
- Compiler's `emitFn` currently emits `nil` placeholder
- VM's `call`, `closure`, `upvalue_load/store` return `InvalidInstruction`

## Design (following Beta pattern)

### Value type extension

Add `fn_val` variant to Value:

```zig
// In value.zig
fn_val: *const Fn,

pub const Fn = struct {
    proto: *const FnProto,
    closure_bindings: ?[]const Value = null,
};
```

### Stack layout for function calls

```
Before call:  [..., fn_val, arg0, arg1]
After frame:  frame.base -> [closure0, closure1, ..., arg0, arg1, locals...]
```

- `closure` opcode: create Fn from FnProto, capture values from current frame
- `call` opcode: push new CallFrame, inject closure_bindings before args
- `ret` opcode: already works for single frame; extend for multi-frame

### Compiler changes

- `emitFn`: store compiled FnProto as constant, emit `closure` opcode
- Track `capture_count` based on parent locals at fn creation time

## Plan

### Step 1: Add Fn struct and fn_val to Value
- Add `Fn` struct (proto + closure_bindings)
- Add `fn_val` variant to Value union
- Update formatPrStr, eql, isTruthy for fn_val
- Update dumpValue in chunk.zig

### Step 2: Implement `closure` opcode in VM
- Read FnProto from constants
- Allocate Fn with captured values from stack
- Push fn_val onto stack

### Step 3: Implement `call` opcode in VM
- Pop fn_val from stack
- Inject closure_bindings into stack before args
- Push new CallFrame
- Handle arity checking

### Step 4: Fix `ret` for multi-frame returns
- Already partially works; verify caller stack restoration

### Step 5: Update Compiler emitFn
- Store FnProto in constant pool (need fn_proto Value variant or embed in fn_val)
- Emit `closure` opcode with constant index
- Calculate capture_count from parent scope

### Step 6: End-to-end tests
- Hand-crafted bytecode: simple function call
- Hand-crafted bytecode: closure capture
- Compiler+VM integration: `(fn [x] x)` called with arg
- Compiler+VM integration: nested fn with capture

## Log

### Step 1: Fn struct + fn_val variant (Done)
- Added `Fn` struct to value.zig: `proto: *const anyopaque`, `closure_bindings: ?[]const Value`
- Added `fn_val: *const Fn` variant to Value union
- Updated formatPrStr (prints `#<fn>`), eql (pointer identity), isTruthy (always true)
- Updated dumpValue in chunk.zig

### Step 2: closure opcode in VM (Done)
- `closure` reads fn_val template from constants
- If capture_count > 0: allocates new Fn + copies values from current frame stack
- If capture_count == 0: pushes template directly
- VM tracks allocated Fns for cleanup (allocated_fns list + deinit)

### Step 3: call opcode in VM (Done)
- Pops fn_val from stack, checks arity
- Injects closure_bindings before args on stack (shift args right)
- Pushes new CallFrame with base pointing to closure_bindings/args

### Step 4: ret for multi-frame (Done)
- Fixed ret to set sp = base - 1 (removes fn_val slot) before pushing result

### Step 5: Compiler emitFn (Done)
- Creates child compiler with parent locals as captured slots
- Heap-allocates FnProto + code/constants copies
- Creates Fn template, stores as constant, emits `closure` opcode
- Tracks allocations for cleanup (fn_protos + fn_objects lists)

### Step 6: Tests (Done)
- VM: closure creates fn_val, simple call (0 args), call with args, closure with capture
- Compiler+VM: `(fn [x] x)` identity fn called with 42
- Compiler: fn_node emits closure opcode, closure capture via let (compilation check)

