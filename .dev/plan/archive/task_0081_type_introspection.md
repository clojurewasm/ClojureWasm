# T9.15: type, class, instance?, isa?

## Goal

Add type introspection functions:

- `type` — returns a keyword indicating the type of a value
- `class` — alias for type (in Clojure returns Java class, here same as type)
- `instance?` — check if value is of given type
- `isa?` — simplified: same as instance? (no hierarchy)

## Plan

1. Add `type` builtin in predicates.zig that returns keyword (:integer, :float, :string, etc.)
2. Add `class` as alias
3. `instance?` and `isa?` can be core.clj since they compare type results
4. Tests and vars.yaml

## Implementation Notes

type returns keywords matching Value tag names:

- nil -> :nil, boolean -> :boolean, integer -> :integer, float -> :float
- string -> :string, keyword -> :keyword, symbol -> :symbol
- list -> :list, vector -> :vector, map -> :map, set -> :set
- builtin_fn/fn_val -> :function, atom -> :atom

## Log

- Added type/class as Zig builtins in predicates.zig (returns keyword)
- Added instance?, isa? to core.clj
- type covers all Value tags (nil, boolean, integer, float, char, string, symbol, keyword, list, vector, map, set, function, atom, protocol, protocol-fn, multi-fn, lazy-seq, cons)
- Registry count: 103 → 105
- All tests pass, no regressions
- vars.yaml updated: type, class, instance?, isa? → done
