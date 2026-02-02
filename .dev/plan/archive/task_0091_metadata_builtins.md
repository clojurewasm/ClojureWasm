# T11.1: meta, with-meta, vary-meta, alter-meta!

## Goal

Add metadata system builtins: meta, with-meta, vary-meta, alter-meta!
This enables Clojure metadata idioms on collections, fns, symbols, and Vars.

## Context

- Collections (List, Vector, Map, Set) already have `meta: ?*const Value = null`
- Fn and Atom structs lack meta field — need to add
- Var has specialized fields (doc, arglists, etc.) but no generic meta map
- Symbol/Keyword metadata is less common; defer to later if needed

## Plan

### Step 1: Add meta field to Fn and Atom structs

- Fn: add `meta: ?*const Value = null`
- Atom: add `meta: ?*const Value = null`

### Step 2: Implement `meta` builtin (Zig)

- Register as `meta` in builtin registry
- Switch on Value type, return metadata map or nil
- For Var: construct a map from its specialized fields (doc, arglists, etc.)

### Step 3: Implement `with-meta` builtin (Zig)

- Takes (obj, meta-map), returns new obj with metadata attached
- For immutable types (collections): create copy with new meta
- For fn_val: create copy with new meta
- Error on types that don't support metadata (numbers, strings, etc.)

### Step 4: Implement `vary-meta` in core.clj

- `(defn vary-meta [obj f & args] (with-meta obj (apply f (meta obj) args)))`
- Pure Clojure, depends on meta + with-meta

### Step 5: Implement `alter-meta!` builtin (Zig)

- Mutates metadata on Var and Atom (reference types)
- `(alter-meta! var f & args)` — applies f to current meta + args

### Step 6: Implement `reset-meta!` builtin (Zig)

- `(reset-meta! var new-meta)` — replaces metadata entirely
- Simpler than alter-meta!

### Step 7: Dual backend tests

- TreeWalk + VM compare-mode tests
- Test meta round-trip on all supported types

## Log

### Step 1: Added meta field to Fn and Atom

- Fn: `meta: ?*const Value = null`
- Atom: `meta: ?*Value = null` (mutable for alter-meta!/reset-meta!)

### Step 2: Implemented `meta` builtin

- New file: src/common/builtin/metadata.zig
- getMeta() dispatches on list, vector, map, set, fn_val, atom
- Registered in registry.zig

### Step 3: Implemented `with-meta` builtin

- Creates shallow copy of collection/fn with new metadata pointer
- Supports: list, vector, map, set, fn_val
- nil meta removes metadata

### Step 4: Implemented `vary-meta` in core.clj

- `(defn vary-meta [obj f & args] (with-meta obj (apply f (meta obj) args)))`

### Step 5: Implemented `alter-meta!` builtin

- Atom-only (Var lacks Value representation)
- Uses bootstrap.callFnVal for function application

### Step 6: Implemented `reset-meta!` builtin

- Simple replacement of metadata on Atom

### Tests

- 9 unit tests in metadata.zig (all pass)
- E2E: meta, with-meta, vary-meta, alter-meta!, reset-meta! verified on both backends
- vars.yaml: 211 -> 216 done (5 new)

### Deferred

- Var metadata (alter-meta!/reset-meta! on Vars): Var is not a Value variant,
  needs separate mechanism. Tracked as future work.
