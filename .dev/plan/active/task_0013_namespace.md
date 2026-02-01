# Task 2.2: Create Namespace

## Goal

Implement Namespace type in `src/common/namespace.zig`.
Namespace manages Symbol -> Var mappings and supports intern/find/refer/alias.
Integrate Namespace registry into Env.

## References

- Beta: `src/runtime/namespace.zig` (221L) — SymbolNameContext, VarMap, Namespace struct
- Beta: `src/runtime/var.zig` (266L) — Var struct with root/dynamic bindings
- Roadmap: "intern/find/refer. Namespace owns Vars"
- Env (Task 2.1): `src/common/env.zig` — ready for namespace registry

## Design Decisions

- **Path**: `src/common/namespace.zig` (not `value/namespace.zig` — matches existing flat structure)
- **Var**: Create `src/common/var.zig` as prerequisite (Namespace needs Var)
- **Env integration**: Add namespace registry (name -> *Namespace HashMap) to Env
- **No threadlocal**: Var dynamic bindings use global frame stack (single-thread, Wasm target) — same as Beta
- **Instantiated**: Namespace instances owned by Env, not global

## Plan

### Step 1: Create Var (`src/common/var.zig`)
- Var struct: sym (Symbol), ns_name, root (Value), flags (dynamic, macro, private, const)
- Methods: deref, bindRoot, getRawRoot, qualifiedName
- Dynamic binding: BindingFrame, push/pop/get/set thread bindings
- Register in root.zig

### Step 2: Create Namespace (`src/common/namespace.zig`)
- SymbolNameContext for string-keyed HashMap
- VarMap, NsAliasMap type aliases
- Namespace struct: name, allocator, mappings, aliases, refers
- Methods: intern, refer, setAlias, getAlias, resolve, resolveQualified
- Utility: unmap, removeAlias, getAllVars, getAllRefers, getAllAliases
- Register in root.zig

### Step 3: Integrate Namespace registry into Env
- Add `namespaces: NsMap` (name -> *Namespace) to Env
- Methods: findOrCreateNamespace, findNamespace
- Auto-create "clojure.core" and "user" on init
- Proper cleanup in deinit

### Step 4: Wire up and verify
- `zig build test` — all tests pass
- Clean up, commit

## Log

