# T4.5 — VM: EvalEngine Compare-Mode Parity Validation

## Goal

Run all 18 SCI tests with EvalEngine.compare() to validate VM-TreeWalk parity.

## Analysis

### Blocker: core.clj bootstrap dependency

All 18 SCI tests call `loadCore()` which evaluates core.clj via TreeWalk,
defining macros (when, and, or, defn, cond, ->, ->>) and functions (inc, dec,
map, filter, reduce, etc.) as TreeWalk closures (fn_val nodes).

**Key constraint**: VM cannot execute TreeWalk closures. VM's `performCall`
expects Fn objects with FnProto (compiled bytecode), not Node-based closures
from TreeWalk.

### What works now

The 67+ EvalEngine.compare() tests in eval_engine.zig verify VM parity for:

- All arithmetic operations (variadic +, -, \*, /)
- All 21 predicates + not
- All 16 collection operations
- String/IO/atom builtins
- Control flow (if, do, let, loop/recur, fn, closures)

These tests construct Node ASTs directly and do NOT depend on core.clj.

### What's blocked

SCI tests that use core.clj features cannot be compared until:

1. T4.6 (AOT pipeline) — compile core.clj to bytecode
2. T4.7 (VM bootstrap) — load compiled core.clj in VM

### Decision

Mark T4.5 as **deferred until T4.7 completion**. The 67+ existing compare
tests provide strong confidence in VM parity for all builtins. Full SCI
comparison requires the AOT pipeline.

Proceed to Phase 4c (T4.6/T4.7) next.

## Plan

1. Document the blocker analysis
2. Update checklist/roadmap
3. Proceed to T4.6

## Log

- Analysis complete: SCI tests depend on core.clj bootstrap (TreeWalk closures)
- VM cannot execute TreeWalk closures — needs AOT pipeline (T4.6/T4.7)
- 67+ EvalEngine.compare tests already validate all builtin parity
- T4.5 deferred to after T4.7; proceeding to Phase 4c
