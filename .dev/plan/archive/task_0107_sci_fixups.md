# T13.1: list?, int?, reduce/2, set-as-fn, deref-delay

SCI test fix-ups: implement missing Zig builtins to fix 4 skipped tests
and 15 skipped assertions.

## Plan

1. **list?** predicate — add to predicates.zig
   - Check for `.list` variant (same pattern as seq?, set?, etc.)
   - Fixes: macroexpand-detail-test (skip → pass)

2. **int?** predicate — add to predicates.zig
   - Alias for integer? (checks `.integer` variant)
   - Clojure semantics: int? checks for fixed-precision integer
   - Fixes: basic-predicates-test, type-predicates-test (skipped assertions)

3. **reduce/2** — update core.clj reduce to multi-arity
   - Add 2-arity: `(reduce f coll)` → uses (first coll) as init
   - Keep 3-arity: `(reduce f init coll)` as-is
   - Fixes: sequences-test, higher-order-fns-test (workaround removal)

4. **set-as-function** — add set dispatch in tree_walk.zig callValue
   - `(#{:a :b} :a)` → `:a`, `(#{:a :b} :c)` → `nil`
   - `(#{:a :b} :c :default)` → `:default` (2-arity with default)
   - Add `.set` case in callValue and runCall
   - Fixes: calling-ifns-test (1 skipped assertion)

5. **deref on delay** — extend atom.zig derefFn
   - Delay is a map with `:__delay` key (current core.clj impl)
   - In derefFn, check for map with :\_\_delay → call force logic
   - Fixes: delay-and-defn-private-test (workaround removal)

## Log

- Added list? predicate (predicates.zig) — isList checks .list variant
- Added int? predicate (predicates.zig) — reuses isInteger check
- Updated reduce in core.clj to multi-arity (2-arity uses first as init)
- Added set-as-function in tree_walk.zig callValue + runCall
- Added deref on delay maps in atom.zig derefFn (detects :\_\_delay key)
- Added conj on map with vector pairs in collections.zig conjOne
- Enabled SCI tests: macroexpand-detail-test, int?, set-as-fn, reduce/2, deref delay, into {}
- Registry: 154 builtins, 268/702 vars done
- SCI: 71/74 tests pass, 257 assertions (was 70/74, 248)
