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

- Phase 4 entry: produce a compile-time error or runtime error with the
  message "Phase N: not yet implemented, see ADR-NNNN".
- Tier D: produce a structured error referencing the rationale ADR.

## Skeleton vs no-op (boundary)

A "skeleton" is permitted when:

- Only the struct type definition exists (no function declared yet).
- A function is declared but its body is exactly
  `return error.NotImplemented;` or `@panic("Phase N: ...")`.

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
Do at Phase 4: `pub fn dosync(...) ... { return rt.err("dosync: STM activates at Phase 15, see ADR-0010"); }`
Do at Phase 15: real MVCC implementation per ADR-0010.
