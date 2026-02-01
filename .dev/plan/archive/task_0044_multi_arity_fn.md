# T4.8 — Multi-arity fn

## Goal

Support multi-arity functions in the VM: `(fn ([x] x) ([x y] (+ x y)))`.
Currently only the first arity is compiled.

## Analysis

- Analyzer already parses multi-arity (FnNode.arities[] has N entries)
- TreeWalk dispatches via findArity() — exact match then variadic fallback
- Compiler takes only arities[0]
- FnProto has single arity/code/constants
- VM performCall checks single proto.arity

## Approach

Store multiple FnProtos per Fn. VM selects proto by arg count at call time.

### Changes

1. **value.zig**: Add `arities: ?[]const *const anyopaque` to Fn (array of FnProto\*)
2. **compiler.zig**: Compile all arities, store as array in Fn
3. **vm.zig**: performCall does arity dispatch (exact match, then variadic)
4. **chunk.zig**: No changes (FnProto stays single-arity)

### Alternative considered

Single FnProto with embedded jump table — rejected (more complex compiler,
harder to debug, no clear perf benefit for our use case).

## Plan

1. Red: Test multi-arity fn via evalStringVM
2. Green: Implement multi-arity compilation + dispatch
3. Red: Test variadic arity (fn [x & rest] ...)
4. Green: Handle variadic dispatch
5. Red: EvalEngine compare test
6. Refactor: Clean up

## Log

### Implementation

- Added `extra_arities` field to Fn struct (null for single-arity, no overhead)
- Extracted `compileArity` helper in Compiler; emitFn compiles all arities
- Added `findProtoByArity` in VM: exact match on primary then extras, variadic fallback
- VM closure opcode preserves extra_arities when capturing bindings
- EvalEngine compare test for multi-arity fn (both backends match)
- evalStringVM tests: 1-arg and 2-arg dispatch verified
- CLI: (fn ([] 0) ([x] x) ([x y] (+ x y))) works for 0/1/2 args
- Variadic multi-arity (& rest) deferred — needs VM arg-packing to list

### Done

T4.8 complete. All 563 tests pass.
