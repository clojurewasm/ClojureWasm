# Task 3.13: Higher-order functions in core.clj

## Goal

Define map, filter, reduce, take, drop as Clojure functions in core.clj.
These are eager (non-lazy) implementations using loop/recur.

## Dependencies

- T3.10 (core.clj bootstrap) — completed
- list, seq, concat, first, rest, cons, conj builtins — all available

## Plan

### Step 1: apply function (builtin)

`apply` is needed for variadic HOFs. It takes a fn and a list of args,
calling the fn with those args spread out. Implement as a Zig builtin
since it requires runtime fn dispatch.

### Step 2: map in core.clj

Eager map: `(defn map [f coll] (loop [...] ...))`
Collects results into a list via conj + reverse (or build reversed then reverse).
Need `reverse` — either as builtin or in core.clj.

### Step 3: filter in core.clj

`(defn filter [pred coll] (loop [...] ...))`
Similar structure to map but conditionally includes elements.

### Step 4: reduce in core.clj

`(defn reduce [f init coll] (loop [...] ...))`
Two-arity version (no init) uses (first coll) as initial value.

### Step 5: take / drop in core.clj

Eager versions using loop/recur on the sequence.

### Step 6: reverse in core.clj or as builtin

Needed by map/filter to build result in correct order.

### Step 7: Tests

- Bootstrap tests for each function
- EvalEngine compare tests where applicable

## Notes

- T3.11/T3.12 (AOT pipeline) are deferred — core.clj is evaluated at
  runtime via TreeWalk for now.
- Lazy sequences are deferred to a future phase.
- cons needs to prepend to a list for efficient accumulation.

## Log

### Builtins added (collections.zig)

- `reverse` — reverses list/vector items
- `into` — conjoins items from one collection onto another
- `apply` — calls fn with args from collection

### core.clj functions

- `next` — returns nil for empty sequences (seq (rest coll))
- `map` — eager map using loop/recur + cons + reverse
- `filter` — eager filter using loop/recur
- `reduce` — 3-arity (f init coll) using loop/recur
- `take` — takes first n elements
- `drop` — drops first n elements

### Bugs fixed

- TreeWalk `callClosure` missing variadic param binding (rest args into PersistentList)
- TreeWalk `callClosure` missing fn_name self-recursion binding
- TreeWalk `callClosure` missing local frame save/restore (nested calls clobbered locals)
- core.clj map/filter/reduce used `rest` instead of `next` (infinite loop on empty seq)
- bootstrap.zig `evalString` must not `defer tw.deinit()` — closures def'd into Vars outlive the TreeWalk instance
- Removed debug prints from tree_walk.zig

### Tests

- bootstrap.zig: next, map, filter, reduce, take, drop
- All 454+ tests pass
