# T16.1: clojure.set namespace + test port

## Plan

1. Create `src/clj/clojure/set.clj` based on upstream
   - `map-invert`: replace transient/persistent! with reduce-based version
   - `bubble-max-key`: use `defn` instead of `defn-` (defn- may not be impl'd)
   - All other functions should work as-is (pure Clojure)

2. Add `loadSet` to bootstrap.zig (follow `loadWalk` pattern)
   - @embedFile `src/clj/clojure/set.clj`
   - Create clojure.set namespace, refer core, eval, refer back to user ns

3. Port test file to `test/clojure/clojure_set.clj`
   - Exclude sorted-set tests (not implemented)
   - Exclude hash-set tests (not distinct from #{})
   - Exclude char literal tests if needed
   - Adjust exception type for intersection 0-arg test

4. Run both VM and TreeWalk, fix issues

5. Update vars.yaml (12 functions → done)

## Log

- Implemented max-key, min-key in core.clj (reduce-based, avoiding F76 loop/recur issue)
- Created src/clj/clojure/set.clj with all 12 functions from upstream
  - UPSTREAM-DIFF: bubble-max-key removed (identical? doesn't work with copied values)
  - UPSTREAM-DIFF: map-invert uses reduce-kv instead of transient/persistent!
  - UPSTREAM-DIFF: project/rename don't preserve meta
- Added loadSet to bootstrap.zig (same pattern as loadWalk)
- Added loadSet calls to main.zig (2 places) and nrepl.zig
- Fixed in-ns to copy current_ns.refers to new namespace (D57)
  - Without this, `are` macro failed after `(ns ...)` because postwalk-replace was unreachable
- Added map-as-function IFn dispatch to TreeWalk callValue/runCall (D57)
  - VM already had this at performCall line 501-509
- Added first/rest on set support (F40 resolved)
- Results: VM 12 tests/104 assertions, TW 12 tests/104 assertions
