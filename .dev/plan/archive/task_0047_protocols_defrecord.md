# T4.11 — Protocols + defrecord

## Goal

Implement `defprotocol`, `extend-type`, `satisfies?`, and `defrecord`
for polymorphic dispatch on type.

## Design

### Data structures (new Value variants)

- `Value.protocol` — points to Protocol struct
- `Value.protocol_fn` — points to ProtocolFn struct (dispatches on first arg type)

```
Protocol {
    name: []const u8,
    method_sigs: []MethodSig,   // {name, arity}
    impls: *PersistentArrayMap, // type_key -> method_map
}

ProtocolFn {
    protocol: *Protocol,
    method_name: []const u8,
}
```

### Type keys

Map runtime Value tags to string keys for impl dispatch:
nil, boolean, integer, float, string, keyword, symbol,
list, vector, map, set, function, atom

### Special forms (Analyzer)

- `defprotocol` — creates Protocol, defines Var for each method as ProtocolFn
- `extend-type` — looks up Protocol, adds impl for a type
- `defrecord` — expands to `->Name` constructor fn (stub, like Beta)

### Dispatch (TreeWalk + VM)

When calling a ProtocolFn:

1. Get type key of first arg
2. Lookup `protocol.impls[type_key][method_name]`
3. Call the found fn with all args

### Dependencies

- PersistentArrayMap already exists (used for hash-map)
- Need new Value variants: `.protocol`, `.protocol_fn`

## Plan

1. Red: Test `(defprotocol IFoo (bar [this]))` — fails (unknown special form)
2. Green: Add Protocol/ProtocolFn to Value, add analyzeDefprotocol
3. Red: Test `(extend-type :string IFoo (bar [this] (str "bar:" this)))` — fails
4. Green: Add analyzeExtendType
5. Red: Test `(bar "hello")` — protocol dispatch
6. Green: Implement protocol_fn call dispatch in TreeWalk
7. Red: Test `(satisfies? IFoo "hello")` — fails
8. Green: Add satisfies? builtin
9. Red: Test `(defrecord Point [x y])` / `(->Point 1 2)`
10. Green: Add analyzeDefrecord (expand to constructor fn)
11. VM dispatch for protocol_fn
12. Refactor

## Log

### Session 1

1. Added Protocol, ProtocolFn, MethodSig structs to value.zig
2. Added .protocol and .protocol_fn Value variants
3. Added DefProtocolNode, ExtendTypeNode to node.zig
4. Implemented analyzeDefprotocol, analyzeExtendType, analyzeDefrecord in analyzer
5. Implemented runDefprotocol, runExtendType in TreeWalk
6. Added protocol_fn call dispatch in TreeWalk.runCall
7. Added keyword-as-function support: (:key map) => (get map :key)
8. Added satisfies? builtin predicate
9. defrecord expands to (def ->Name (fn ...)) via Form re-analysis
10. All 580 tests pass (3 new test groups + existing)
