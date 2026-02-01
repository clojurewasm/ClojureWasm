# Task 1.11: Analyzer — loop/recur, try/catch/throw

## Goal

Add loop, recur, try, catch, throw as special form handlers in the Analyzer.
Node types (LoopNode, RecurNode, ThrowNode, TryNode, CatchClause) already exist in node.zig.

## Plan

### Special forms to add to comptime table

| Form  | Handler      | Notes                                       |
| ----- | ------------ | ------------------------------------------- |
| loop  | analyzeLoop  | Like let: bindings + body. Recur target.    |
| recur | analyzeRecur | Args only. No arity check at analysis time. |
| throw | analyzeThrow | Exactly 1 argument.                         |
| try   | analyzeTry   | Body + optional catch/finally clauses.      |

### Detailed semantics

**loop**: `(loop [x 0 y 1] body...)`

- Same binding structure as let (vector, even pairs, symbol names)
- Body wrapped in do if multiple forms
- Locals scoped to body

**recur**: `(recur arg1 arg2 ...)`

- Analyze all args as Nodes
- No arity validation at analysis time (deferred to runtime, per Beta)

**throw**: `(throw expr)`

- Exactly 1 argument required (arity_error otherwise)
- Analyze the expression

**try**: `(try body... (catch ExType e handler...) (finally cleanup...))`

- Walk items[1..] to separate body forms from catch/finally
- catch: `(catch ExType name body*)` — at least 4 elements
  - ExType ignored in Phase 1c (no class hierarchy)
  - binding_name must be symbol
  - Scoped local for catch handler body
- finally: `(finally body*)` — at least 2 elements
- Multiple body forms wrapped in do

### TDD steps (1 test → 1 impl each)

1. Red: `(loop [x 0] x)` → loop_node with 1 binding, body = local_ref
2. Green: implement analyzeLoop
3. Red: `(recur 1 2)` → recur_node with 2 args
4. Green: implement analyzeRecur
5. Red: `(throw "error")` → throw_node with constant expr
6. Green: implement analyzeThrow
7. Red: `(try 1 (catch Exception e 2))` → try_node with catch
8. Green: implement analyzeTry (catch path)
9. Red: `(try 1 (finally 3))` → try_node with finally
10. Green: add finally path to analyzeTry
11. Red: `(try 1 (catch Exception e 2) (finally 3))` → both
12. Green: verify combined path works
13. Red: error cases (loop odd bindings, throw wrong arity, catch missing symbol, etc.)
14. Green: error validation
15. Refactor: cleanup

### Files to modify

| File         | Changes                                  |
| ------------ | ---------------------------------------- |
| analyzer.zig | Add 4 handlers + 4 table entries + tests |

## Log

- Added analyzeLoop, analyzeRecur, analyzeThrow, analyzeTry to special_forms table
- loop: same structure as let (binding vector + body), scoped locals
- recur: args only, no arity check at analysis (deferred to runtime)
- throw: exactly 1 arg, arity_error otherwise
- try: walks items to separate body/catch/finally
  - catch: (catch ExType name body\*), 4+ elements, ExType ignored in Phase 1c
  - catch binding scoped to handler body
  - finally: (finally body\*), 2+ elements
- Tests: 10 new tests (happy paths + error cases + scoping)
- All tests pass
