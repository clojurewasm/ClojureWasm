# T4.9 — Destructuring (sequential + map)

## Goal

Add destructuring support to `let`, `fn`, and `loop` binding forms.

## Scope

### Sequential destructuring

- `(let [[a b c] [1 2 3]] ...)` — positional binding via `(nth coll i)`
- `(let [[a b & rest] [1 2 3 4]] ...)` — rest binding via chained `rest` calls
- `(let [[a b :as all] [1 2 3]] ...)` — `:as` whole-collection binding
- Nested: `(let [[[a b] c] [[1 2] 3]] ...)`

### Map destructuring

- `(let [{:keys [a b]} {:a 1 :b 2}] ...)` — keyword keys
- `(let [{:strs [a b]} {"a" 1 "b" 2}] ...)` — string keys
- `(let [{a :a b :b} {:a 1 :b 2}] ...)` — explicit key binding
- `(let [{:keys [a] :or {a 0}} {}] ...)` — default values
- `(let [{:keys [a] :as m} {:a 1}] ...)` — `:as` whole-map binding

### Forms affected

- `let` / `let*` — binding vector
- `fn` / `fn*` — parameter vector (generates synthetic params + let wrapper)
- `loop` — binding vector

## Design

Destructuring is expanded at **Analyzer** phase, same as Beta.
Pattern bindings are expanded into multiple simple LetBinding entries
using calls to `nth`, `get`, `rest` builtins.

### Key functions to add to Analyzer

1. `expandBindingPattern(pattern_form, init_node, bindings_list)` — dispatch on form type
2. `expandSequentialPattern(vector_elems, init_node, bindings_list)` — vector patterns
3. `expandMapPattern(map_entries, init_node, bindings_list)` — map patterns
4. Helper: `makeNthCall(coll_node, idx)` — generate `(nth coll idx)` call node
5. Helper: `makeNthRest(coll_node, pos)` — generate chained rest calls
6. Helper: `makeGetCall(coll_node, key_node, default_node)` — generate `(get coll key)` or `(get coll key default)`

### Changes to existing functions

- `analyzeLet`: Replace symbol-only check with `expandBindingPattern` call, use ArrayList for bindings
- `analyzeLoop`: Same pattern as let
- `analyzeFnArity`: For non-symbol params, generate synthetic param name + let wrapper in body

## Dependencies

All runtime functions already exist: `nth`, `get`, `first`, `rest`, `seq`, `count`.

## Plan

1. Red: Write test for sequential destructuring in `let` — `(let [[a b] [1 2]] (+ a b))`
2. Green: Implement `expandBindingPattern` + `expandSequentialPattern`, modify `analyzeLet`
3. Red: Test `& rest` pattern — `(let [[a & r] [1 2 3]] r)`
4. Green: Add `&` handling in `expandSequentialPattern`
5. Red: Test `:as` pattern — `(let [[a :as all] [1 2]] all)`
6. Green: Add `:as` handling
7. Red: Test map destructuring — `(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))`
8. Green: Implement `expandMapPattern`
9. Red: Test `:or` defaults — `(let [{:keys [a] :or {a 42}} {}] a)`
10. Green: Add default value support
11. Red: Test fn destructuring — `((fn [[a b]] (+ a b)) [1 2])`
12. Green: Modify `analyzeFnArity` for destructuring params
13. Red: Test loop destructuring
14. Green: Modify `analyzeLoop`
15. Red: Test nested destructuring
16. Green: Verify recursive expansion works
17. Refactor: Clean up, verify both TreeWalk and VM pass

## Log

- Implemented expandBindingPattern, expandSequentialPattern, expandMapPattern in Analyzer
- Modified analyzeLet to use expandBindingPattern (ArrayList-based bindings)
- Modified analyzeLoop same way
- Modified analyzeFnArity: non-symbol params get synthetic names (**p0** etc), body wrapped in let
- Helper functions: makeNthCall, makeNthRest, makeGetKeywordCall, makeGetStringCall, makeGetCallNode, findDefault, makeTempLocalRef, makeSyntheticParamName
- Fixed makeBuiltinCall to use ns=null (was "clojure.core" which broke qualified resolution)
- All tests pass: TreeWalk + VM, sequential + map + nested + fn params + loop
- 13 new tests added in bootstrap.zig
