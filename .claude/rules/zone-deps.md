# Zone Dependency Rules (D109)

Auto-load paths: `src/**/*.zig`

## Zone Architecture

CW uses a strict 4-zone layered architecture:

```
Layer 0: src/runtime/, src/regex/ — foundational types, NO upward imports
Layer 1: src/engine/    — processing pipeline, imports runtime/ only
Layer 2: src/lang/      — Clojure builtins/interop, imports runtime/ + engine/
Layer 3: src/app/, src/main.zig, src/cache_gen.zig — application, imports anything
```

**NOTE**: `src/main.zig` and `src/cache_gen.zig` are Layer 3 entry points at `src/` root
(Zig module path constraints require entry points to reach all zones via relative imports).

## Rules

### NEVER: Upward imports

```
runtime/ must NOT import from engine/, lang/, or app/
engine/  must NOT import from lang/ or app/
lang/    must NOT import from app/
```

### When you need a lower layer to call a higher layer

Use the **vtable pattern** (function pointer table initialized at startup):

```zig
// In runtime/dispatch.zig (Layer 0):
pub var someFn: *const fn(...) !Value = undefined;

// In engine/init.zig (Layer 1) — sets the pointer at startup:
dispatch.someFn = &actualImplementation;
```

This preserves the dependency direction: engine/ imports runtime/ to set
the pointer. runtime/ never imports engine/.

### Verification (hard block)

Run zone check before committing changes to src/:
```bash
bash scripts/zone_check.sh --gate
```

**Hard block**: Violations must not increase from baseline (126).
If violations decrease, update `BASELINE` in `scripts/zone_check.sh`.
New upward imports are forbidden — use vtable pattern instead.

## Common Patterns

### Adding a new builtin function

1. Implementation goes in `lang/builtins/` (Layer 2)
2. Registration goes in `lang/registry.zig` (Layer 2)
3. If it needs runtime primitives, import from `runtime/` (Layer 0) — OK
4. If it needs the evaluation pipeline, import from `engine/` (Layer 1) — OK

### Adding a new Value operation

1. Implementation goes in `runtime/value.zig` or `runtime/collections.zig` (Layer 0)
2. Must NOT import from engine/, lang/, or app/
3. If you need evaluation, use `dispatch.callFnVal` (vtable in Layer 0)

### Modifying the compiler or VM

1. Changes go in `engine/compiler/` or `engine/vm/` (Layer 1)
2. May import from `runtime/` — OK
3. Must NOT import from `lang/` or `app/`
