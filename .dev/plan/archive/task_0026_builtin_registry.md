# Task 3.5: BuiltinDef Registry with Metadata

## Goal

Create a comptime-driven BuiltinDef registry that:

1. Defines builtin tables per domain (arithmetic, special forms)
2. Aggregates them with comptime duplicate checking
3. Provides `registerBuiltins()` to intern Vars with metadata in Env
4. Replaces hardcoded intrinsic tables in Compiler and TreeWalk

## References

- SS10 (future.md): VarKind, BuiltinDef metadata design
- D4 (decisions.md): Special forms as comptime table
- D14 (decisions.md): BuiltinDef moved before builtins
- Beta: src/lib/core/registry.zig (comptime table aggregation pattern)
- Beta: src/lib/core/arithmetic.zig (per-domain builtins table)

## Context

### Current state

- `BuiltinDef` struct defined in `src/common/var.zig` with metadata fields
- `Var.applyBuiltinDef()` already implemented
- Compiler uses hardcoded `intrinsicOpCode()` tuple table
- TreeWalk uses hardcoded `builtinLookup()` + `callBuiltin()` string arrays
- No `func` field yet in BuiltinDef (deferred to when actual implementations exist)

### Design decisions

- No `func` field in BuiltinDef yet — registry is metadata-only for now
- Compiler intrinsic mapping stays separate (opcode-level, not func-level)
- TreeWalk builtin dispatch stays separate (direct implementation, not func ptr)
- Registry provides: intern Vars + apply metadata + refer to user ns
- Special forms get their own comptime table (D4)

## Plan

### Step 1: Create registry module with arithmetic builtins table

- New file: `src/common/builtins/arithmetic.zig`
- Define `pub const builtins: []const BuiltinDef` for +, -, \*, /, mod, rem, =, not=, <, >, <=, >=
- Include doc, arglists, added metadata from Clojure reference

### Step 2: Create special_forms table

- New file: `src/common/builtins/special_forms.zig`
- Define table for: if, do, let, fn, def, quote, defmacro, loop, recur, try, catch, finally, throw, var, set!
- kind = .special_form, with doc strings

### Step 3: Create registry aggregator

- New file: `src/common/builtins/registry.zig`
- Aggregate all domain tables with comptime `++`
- Comptime duplicate name validation
- `pub fn registerBuiltins(env: *Env) !void` — intern Vars + applyBuiltinDef + set current_ns

### Step 4: Integrate with Compiler intrinsic lookup

- Add `isIntrinsic()` to registry that Compiler can use
- Or keep Compiler's own `intrinsicOpCode()` (it maps name->opcode, different concern)
- Decision: keep separate — Compiler needs name->OpCode, not name->BuiltinDef

### Step 5: Integrate with TreeWalk builtin lookup

- TreeWalk resolveVar should check Env first (registered Vars)
- Builtin sentinel value pattern can remain for dispatch
- But lookup should go through Env->Namespace->Var resolution

### Step 6: EvalEngine integration test

- Compare mode test: builtin registered via registry, both backends produce same result

## Log

- Step 1: Created `src/common/builtin/arithmetic.zig` — 12 BuiltinDef entries for +,-,\*,/,mod,rem,=,not=,<,>,<=,>= with doc/arglists/added metadata. All vm_intrinsic kind.
- Step 2: Created `src/common/builtin/special_forms.zig` — 13 BuiltinDef entries for if,do,let*,fn*,def,quote,var,loop\*,recur,throw,try,set!,defmacro. All special_form kind.
- Step 3: Created `src/common/builtin/registry.zig` — comptime aggregation (25 total), duplicate validation, `comptimeLookup`/`lookup` functions, `registerBuiltins()` that interns Vars in clojure.core and refers them to user ns.
- Step 4: Compiler intrinsicOpCode() kept separate (maps name->OpCode, different concern from BuiltinDef).
- Step 5: Updated TreeWalk `resolveVar` to check Env first; vm_intrinsic/special_form Vars return sentinel for dispatch, fallback to hardcoded table when no Env.
- Step 6: Added EvalEngine compare test with registry-registered Env — both backends produce same result via registered builtins.
- Changed `Var.applyBuiltinDef` to accept `BuiltinDef` by value (not pointer) for comptime array iteration compatibility.
- All tests pass (zig build test).
