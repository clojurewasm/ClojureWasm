# Task 2.10: Wire up --compare mode

## Goal

Create an evaluation engine that runs both TreeWalk and VM backends on the
same Node AST, compares results, and reports mismatches. This is the key
regression detection tool (SS9.2, D6).

## References

- future.md SS9.2: --compare mode
- decisions.md D6: Dual backend with --compare from Phase 2
- Beta: src/runtime/engine.zig (EvalEngine)
- Task 2.9: TreeWalk evaluator (completed)
- Task 2.7/2.8: VM + Compiler (completed)

## Plan

### File location

`src/common/eval_engine.zig` — shared between backends, used by tests and CLI.

### Design

```
pub const Backend = enum { tree_walk, vm, compare };

pub const CompareResult = struct {
    tw_result: ?Value,    // TreeWalk result or null on error
    vm_result: ?Value,    // VM result or null on error
    tw_error: ?[]const u8,
    vm_error: ?[]const u8,
    match: bool,
};

pub const EvalEngine = struct {
    allocator: Allocator,
    env: *Env,

    pub fn runTreeWalk(node: *const Node) !Value;
    pub fn runVM(node: *const Node) !Value;
    pub fn compare(node: *const Node) CompareResult;
};
```

### Scope

- EvalEngine wraps Compiler + VM and TreeWalk
- compare() runs both, catches errors, compares with Value.eql()
- Test: basic expressions produce matching results
- Test: intentionally wrong VM output is detected

### TDD steps

1. Red: EvalEngine.runTreeWalk returns correct result
2. Red: EvalEngine.runVM returns correct result
3. Red: EvalEngine.compare detects match
4. Red: EvalEngine.compare detects mismatch (if we can produce one)
5. Refactor: clean up

## Log

- Created `src/common/eval_engine.zig` with EvalEngine struct
- Backend enum: tree_walk, vm, compare
- CompareResult: tw_value/vm_value, tw_error/vm_error, match flag
- runTreeWalk: wraps TreeWalk evaluator
- runVM: wraps Compiler -> VM pipeline
- compare: runs both, catches errors, compares with Value.eql()
- 9 tests: constant, nil, bool, if, do, let, mismatch detection, fn+call
- Mismatch test: (+ 1 2) succeeds in TreeWalk (builtin), fails in VM (var_load not yet implemented)
- All 315 tests pass
