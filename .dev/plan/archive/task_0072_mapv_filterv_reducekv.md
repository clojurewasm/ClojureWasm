# T9.6: mapv, filterv, reduce-kv

## Goal

Add vector-returning variants and key-value reduce to core.clj:

- `mapv` — like map but returns a vector
- `filterv` — like filter but returns a vector
- `reduce-kv` — reduce over map entries with (f acc k v)

## Plan

1. **Red**: Write test for `mapv` in bootstrap.zig
2. **Green**: Add `mapv` to core.clj
3. **Red**: Write test for `filterv` in bootstrap.zig
4. **Green**: Add `filterv` to core.clj
5. **Red**: Write test for `reduce-kv` in bootstrap.zig
6. **Green**: Add `reduce-kv` to core.clj
7. **Refactor**: Clean up if needed
8. Update vars.yaml

## Implementation Notes

- `mapv`: `(defn mapv [f coll] (vec (map f coll)))`
- `filterv`: `(defn filterv [pred coll] (vec (filter pred coll)))`
- `reduce-kv`: Needs to iterate map entries — use `(seq m)` to get pairs,
  then destructure `(first pair)` / `(first (rest pair))` for key/value.
  Standard Clojure: `(reduce (fn [acc [k v]] (f acc k v)) init m)` but
  our destructuring may not support `[k v]` in fn args with map seq.
  Alternative: use explicit key/val extraction per entry.

## Log

- Red/Green: mapv test + impl (vec (map f coll)) — pass
- Red/Green: filterv test + impl (vec (filter pred coll)) — pass
- Red/Green: reduce-kv tests (sum values, build new map) + impl via keys+get loop — pass
- All 709+ tests pass, no regressions
- vars.yaml updated: mapv, filterv, reduce-kv → done
