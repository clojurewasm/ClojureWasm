# T12.6: Namespace ops I: all-ns, find-ns, ns-name, create-ns

## Goal

Implement 4 namespace introspection builtins + the-ns helper.

## Design Decision (D47)

Namespace is represented as a symbol (its name) in Value, not a new Value variant.
This avoids the cost of adding a 22nd Value variant (8+ switch exhaustive updates).
`find-ns` returns the namespace name as a symbol, `ns-name` accepts a symbol.
`the-ns` accepts either a symbol or a namespace (for now, symbol only).

Limitation: No true namespace identity — two namespaces with the same name are
indistinguishable. Acceptable since namespace names are unique in Env.

## Plan

### 1. Create `src/common/builtin/ns_ops.zig`

5 builtins:

**the-ns** `([x])`:

- If x is a symbol, find namespace by name, return symbol (or error)
- Acts as namespace validator

**all-ns** `([])`:

- Return list of all namespace names as symbols

**find-ns** `([sym])`:

- Look up namespace by symbol name, return symbol or nil

**ns-name** `([ns])`:

- Return ns name as symbol (identity for our representation)

**create-ns** `([sym])`:

- Find or create namespace, return symbol

### 2. Register in registry.zig

### 3. Tests

- all-ns returns list containing clojure.core and user
- find-ns with existing ns returns symbol
- find-ns with nonexistent ns returns nil
- ns-name returns namespace name
- create-ns creates new namespace
- the-ns errors on nonexistent

## Log

- Created `src/common/builtin/ns_ops.zig` with 5 builtins
- D47: Namespace represented as symbol (no new Value variant)
- Registered in registry.zig (141 -> 146 builtins)
- Unit tests: 7 tests (find-ns existing/nonexistent, all-ns, ns-name, create-ns, the-ns existing/error)
- CLI verified: all 5 builtins work end-to-end
- All tests pass (full suite)
