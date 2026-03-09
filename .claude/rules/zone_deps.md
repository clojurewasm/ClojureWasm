---
paths:
  - "src/**/*.zig"
  - "ext/**/*.zig"
---

# Zone Dependency Rules

## Zone Architecture

```
Layer 0: src/runtime/    -- Value, Collections, GC, Env, Dispatch, ExtensionDef
                            NO upward imports
Layer 1: src/eval/       -- Reader, Analyzer, Compiler, VM, TreeWalk, Evaluator
                            imports runtime/ only
Layer 2: src/lang/       -- Primitives, Interop, Bootstrap, NS Loader
                            imports runtime/ + eval/
Layer 3: src/app/, src/main.zig
                            imports anything

ext/                     -- imports runtime/ + eval/ (same as Layer 2)
                            must NOT import lang/ or app/
```

## Rules

### NEVER: Upward imports

```
runtime/  must NOT import from eval/, lang/, ext/, or app/
eval/     must NOT import from lang/, ext/, or app/
lang/     must NOT import from app/
ext/      must NOT import from lang/ or app/
```

### When you need a lower layer to call a higher layer

Use the **vtable pattern** (function pointer table initialized at startup):

```zig
// In runtime/dispatch.zig (Layer 0):
pub var callFn: *const fn(Value, []const Value) anyerror!Value = undefined;

// In eval/backend/vm.zig (Layer 1) — sets the pointer at startup:
dispatch.callFn = &vmCallFunction;
```

This preserves the dependency direction: eval/ imports runtime/ to set
the pointer. runtime/ never imports eval/.

### Extension isolation

Extensions register via `runtime/extension.zig` ExtensionDef.
Core code (`runtime/`, `eval/`, `lang/`) never imports `ext/`.
`ext/` may import `runtime/` and `eval/` but not `lang/` or `app/`.

## Common Patterns

### Adding a new builtin function

1. Implementation goes in `lang/primitive/*.zig` (Layer 2)
2. Registration goes in `lang/primitive.zig` (Layer 2)
3. If it needs runtime primitives, import from `runtime/` (Layer 0) — OK
4. If it needs the eval pipeline, import from `eval/` (Layer 1) — OK

### Adding a new Value operation

1. Implementation goes in `runtime/value.zig` or `runtime/collection/*.zig` (Layer 0)
2. Must NOT import from eval/, lang/, or app/
3. If you need evaluation, use `dispatch.callFn` (vtable in Layer 0)

### Modifying the compiler or VM

1. Changes go in `eval/backend/compiler.zig` or `eval/backend/vm.zig` (Layer 1)
2. May import from `runtime/` — OK
3. Must NOT import from `lang/` or `app/`
