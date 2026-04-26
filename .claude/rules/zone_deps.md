---
paths:
  - "src/**/*.zig"
  - "modules/**/*.zig"
  - "build.zig"
---

# Zone Dependency Rules

Auto-loaded when editing Zig source. Authoritative version of the layering
contract in ROADMAP §4.1 / §A1.

## Zone architecture

```
Layer 3: src/app/, src/main.zig    -- CLI / REPL / nREPL / builder / pod
                                       imports anything below
Layer 2: src/lang/                 -- Primitives, Interop, Bootstrap
                                       imports runtime/ + eval/
Layer 1: src/eval/                 -- Reader, Analyzer, Compiler, VM, TreeWalk
                                       imports runtime/ only
Layer 0: src/runtime/              -- Value, Collections, GC, Env, Dispatch
                                       imports nothing above

modules/                           -- imports runtime/ + eval/ only
                                       must NOT import lang/ or app/
```

## NEVER: upward imports

```
runtime/  must NOT import from eval/, lang/, modules/, or app/
eval/     must NOT import from lang/, modules/, or app/
lang/     must NOT import from app/
modules/  must NOT import from lang/ or app/
```

## When a lower zone needs to call a higher zone

Use the **vtable pattern**: the lower zone declares the `VTable` type
(typically as a `struct` field on `Runtime`); the higher zone injects
function pointers at startup.

```zig
// Layer 0 declares only the type
pub const VTable = struct {
    callFn: *const fn(*Runtime, *Env, Value, []const Value) anyerror!Value,
    expandMacro: *const fn(*Runtime, *Env, Value, []const Value) anyerror!Value,
};

// Layer 1 (or higher) installs the implementation at startup
runtime.vtable = .{
    .callFn = tree_walk.callFn,
    .expandMacro = analyzer.expandMacro,
};
```

This inverts the *compile-time* dependency direction while preserving the
logical call flow.

## Module isolation

`modules/` registers external modules through `runtime/module.zig`'s
`ExternalModule` interface. Core code (`runtime/`, `eval/`, `lang/`) never
imports `modules/`.

## Enforcement

`scripts/zone_check.sh` parses every `@import("…/foo.zig")` in the source
tree and flags upward-direction violations.

- `bash scripts/zone_check.sh` — informational; always exits 0.
- `bash scripts/zone_check.sh --strict` — exit 1 on any violation.
- `bash scripts/zone_check.sh --gate` — exit 1 if violation count exceeds
  the in-script BASELINE (currently 0).

Tests are exempt: everything after the first `test "…"` line in a file is
skipped (test code may legitimately cross zones).
