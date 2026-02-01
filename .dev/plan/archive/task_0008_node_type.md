# Task 0008: Define Node type for Analyzer AST

## Context
- Phase: 1c (Analyzer)
- Depends on: task_0007 (Reader)
- References: Beta src/analyzer/node.zig (605L), future.md SS1

## Plan
1. Create src/common/analyzer/node.zig
2. Core 14 Node variants: constant, var_ref, local_ref, if, do, let, loop, recur, fn, call, def, quote, throw, try
3. Helper constructors: constantNode, nilNode, trueNode, falseNode
4. Advanced variants deferred: defmulti, defmethod, defprotocol, extend-type, lazy-seq, letfn

## Log

### 2026-02-01
- Created src/common/analyzer/node.zig with 14 Node variants:
  - Literals: constant (wraps Value)
  - References: var_ref (VarRefNode -- name-based for Phase 1), local_ref (LocalRefNode)
  - Control flow: if_node, do_node, let_node, loop_node, recur_node
  - Functions: fn_node (multi-arity), call_node
  - Definitions: def_node (with is_macro/is_dynamic/is_private/is_const/doc flags)
  - Quote: quote_node (holds Value)
  - Exceptions: throw_node, try_node (with CatchClause, finally)
- Design differences from Beta:
  - `source` field instead of `stack` (clearer naming)
  - `callee` instead of `fn_node` in CallNode (avoids name collision with FnNode)
  - VarRefNode uses ns+name strings (no *Var yet, deferred to Phase 2)
  - Advanced variants deferred: defmulti, defmethod, defprotocol, extend-type, lazy-seq, letfn
  - deepClone deferred to TreeWalk evaluator implementation
- Helper constructors: constantNode, nilNode, trueNode, falseNode
- 12 tests covering all node types. All passing
- Commit: f919c02 "Add Node type for Analyzer AST (Task 1.9)"

## Status: done
