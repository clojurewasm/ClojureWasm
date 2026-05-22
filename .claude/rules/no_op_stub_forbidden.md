---
paths:
  - src/**/*.zig
  - src/lang/clj/**
  - src/runtime/host/**
---

# No-op stub forbidden

## Rule

When implementing a Tier A / B / C feature, do NOT use a no-op stub
that pretends to work.

A no-op stub is any of:

- Function body that returns the input unchanged when semantics require
  transformation.
- Body that wraps the argument in `(do body)` when semantics require
  effect tracking (e.g., snapshot isolation for `dosync`, lock for
  `locking`).
- Macro that expands to `nil` or to its body without intended semantics.

When the feature is genuinely not yet implemented:

- Phase 4 entry: raise `Code.unsupported_feature` via the catalog
  (`src/runtime/error_catalog.zig`, per ADR-0018) with the feature
  name supplied as `.{ .name = "<feature>" }`.
- Tier D: raise `Code.tier_d_form` via the catalog with the same
  shape.

The user-facing messages are
`"<feature> is not supported in ClojureWasm"` and
`"<form> is not part of ClojureWasm"`. Phase numbers and ADR
identifiers stay internal — the user sees only the form name they
wrote.

## Skeleton vs no-op (boundary)

A "skeleton" is permitted when:

- Only the struct type definition exists (no function declared yet).
- A function is declared but its body is exactly
  `return error_catalog.raise(.unsupported_feature, loc, .{ .name = "<form>" });`
  (per ADR-0018), or for genuinely internal-only paths
  `return error.NotImplemented;` / `@panic("...")` with a
  developer-visible comment.

A "no-op stub" is forbidden when:

- A function is declared and executes the argument without the intended
  semantics (e.g., `dosync` body executed without snapshot isolation).
- A function returns a default value that masks the missing feature.

## Why (Shota's directive)

- A stub that "works" misleads users into building code that breaks
  later.
- STM (`dosync` body executed without snapshot isolation) and locking
  (`locking` body executed without lock) are common offenders in
  JVM-non-equivalent runtimes.
- cw v1 commits to either a real implementation or an explicit error.

## How to apply

- New feature: implement the real semantics, or fail clearly.
- Pre-commit gate: `scripts/check_no_op_stub.sh`
  (heuristic, becomes hard at Phase 5+).
- ADR for any deliberate stub (Phase 4 entry has none).

## Examples

Don't: `pub fn dosync(rt: *Runtime, body: Value) !Value { return eval(rt, body); }`

Do at Phase 4:

```zig
pub fn dosync(rt: *Runtime, loc: SourceLocation, body: Value) !Value {
    _ = rt;
    _ = body;
    return error_catalog.raise(.unsupported_feature, loc, .{ .name = "dosync" });
}
```

Renders to the user as: `dosync is not supported in ClojureWasm`.

Do at Phase 15: real MVCC implementation per ADR-0010.
