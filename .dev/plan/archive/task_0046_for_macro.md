# T4.10 — for macro (list comprehension)

## Goal

Implement the `for` list comprehension macro with `:let`, `:when`, `:while` modifiers.

## Design

Pure Clojure macro in core.clj — no Zig changes needed.

### Dependencies

- `mapcat` — not yet defined (add to core.clj)
- `map`, `filter`, `concat`, `apply` — all exist

### Expansion strategy (like Beta)

- Single binding: `(for [x coll] body)` → `(map (fn [x] body) coll)`
- Nested: `(for [x c1 y c2] body)` → `(mapcat (fn [x] (for [y c2] body)) c1)`
- `:when test` → wrap body in `(when test ...)`
- `:let [bindings]` → wrap body in `(let [bindings] ...)`
- `:while test` → TODO (deferred if complex)

## Plan

1. Red: Test `(mapcat f coll)` — not yet defined
2. Green: Add `mapcat` to core.clj
3. Red: Test basic `(for [x [1 2 3]] (* x 2))`
4. Green: Add `for` macro to core.clj
5. Red: Test nested `(for [x [1 2] y [10 20]] (+ x y))`
6. Green: Verify nested works (recursive macro expansion)
7. Red: Test `:when` modifier
8. Green: Add `:when` support
9. Red: Test `:let` modifier
10. Green: Add `:let` support
11. Add VM tests
12. Refactor

## Log

### Session 1

1. Added `mapcat` to core.clj: `(defn mapcat [f coll] (apply concat (map f coll)))`
2. Implemented `analyzeFor` as analyzer special form (not a macro in core.clj)
   - Single binding: `(for [x coll] body)` → `(map (fn [x] body) coll)`
   - Nested: `(for [x c1 y c2] body)` → `(apply concat (map (fn [x] <inner-for>) c1))`
   - `:when test` → wraps body in `(if test (list body) (list))` + flatten
   - `:let [binds]` → wraps body in `(let [binds] body)`
3. Found and fixed critical bug: nested fn calls (e.g. nested `map`) corrupted
   outer loop's `recur_args` because TreeWalk's `callClosure` didn't save/restore
   `recur_pending`, `recur_arg_count`, and `recur_args`. Fixed in tree_walk.zig.
4. VM tests deferred: VM-compiled fn_vals have FnProto proto, but TreeWalk's
   `callClosure` expects Closure proto. Cross-boundary callback unsupported.
5. All 578 tests pass.
