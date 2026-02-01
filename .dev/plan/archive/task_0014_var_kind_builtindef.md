# Task 2.3: VarKind enum + BuiltinDef metadata for Var

## Context

Var basic structure (root binding, dynamic bindings, flags) is already implemented
in `src/common/var.zig` (Task 2.2). This task adds:

1. **VarKind enum** — dependency-layer classification (SS10)
2. **BuiltinDef struct** — metadata for builtin functions (SS10)
3. **Var metadata fields** — doc, arglists, added, since_cw, kind

## References

- future.md SS10: VarKind enum, BuiltinDef metadata
- Beta: `src/runtime/var.zig` (265L)
- Current: `src/common/var.zig` (257L)

## Plan

### Step 1: Add VarKind enum to var.zig

Add `VarKind` enum to classify Vars by dependency layer:
- `special_form` — Compiler-layer (if, do, let, fn, def, quote, etc.)
- `vm_intrinsic` — VM-layer (dedicated opcodes: +, -, first, rest, etc.)
- `runtime_fn` — Runtime-layer (OS API: slurp, re-find, etc.)
- `core_fn` — core.clj AOT function (map, filter, etc.)
- `core_macro` — core.clj AOT macro (defn, when, cond, etc.)
- `user_fn` — user-defined function
- `user_macro` — user-defined macro

TDD: test VarKind creation, Var with kind field.

### Step 2: Add BuiltinDef struct to var.zig

```zig
pub const BuiltinDef = struct {
    name: []const u8,
    kind: VarKind,
    doc: ?[]const u8 = null,
    arglists: ?[]const u8 = null,    // Display string, e.g. "[x y]"
    added: ?[]const u8 = null,       // Clojure :added version (e.g. "1.0")
    since_cw: ?[]const u8 = null,    // ClojureWasm version
};
```

Note: `func: BuiltinFn` field deferred to Phase 3 (Task 3.7) when actual
builtin functions exist. For now, BuiltinDef is metadata-only.

TDD: test BuiltinDef creation, comptime table construction.

### Step 3: Add metadata fields to Var struct

Add to existing Var struct:
- `kind: VarKind = .user_fn`
- `doc: ?[]const u8 = null`
- `arglists: ?[]const u8 = null`
- `added: ?[]const u8 = null`
- `since_cw: ?[]const u8 = null`

TDD: test Var metadata access, Var created from BuiltinDef.

### Step 4: Add Var.initFromBuiltinDef helper

A helper to populate a Var from BuiltinDef metadata:
```zig
pub fn applyBuiltinDef(self: *Var, def: *const BuiltinDef) void {
    self.kind = def.kind;
    self.doc = def.doc;
    self.arglists = def.arglists;
    self.added = def.added;
    self.since_cw = def.since_cw;
}
```

TDD: test round-trip BuiltinDef -> Var metadata.

### Step 5: Comptime table proof-of-concept

Demonstrate that BuiltinDef can be used in comptime arrays:
```zig
const test_builtins = [_]BuiltinDef{
    .{ .name = "+", .kind = .vm_intrinsic, .doc = "Returns the sum of nums." },
    .{ .name = "if", .kind = .special_form, .doc = "..." },
};
```

TDD: test comptime iteration, lookup by name.

## Log

- Step 1: Added VarKind enum (7 variants) — Red/Green done
- Step 2: Added BuiltinDef struct (name, kind, doc, arglists, added, since_cw) — Red/Green done
- Step 3: Added metadata fields to Var (kind, doc, arglists, added, since_cw) — Red/Green done
- Step 4: Added Var.applyBuiltinDef helper — Red/Green done
- Step 5: Comptime table proof-of-concept — comptime iteration and lookup work
- All tests pass (zig build test)
