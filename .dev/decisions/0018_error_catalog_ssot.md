# 0018 — Error catalog as Single Source Of Truth

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, error, ssot, catalog, user-facing-message

## Context

`src/runtime/error.zig` already centralises the *categorisation* axis
of errors: `Kind` (16 semantic categories), `Phase` (parse / analysis
/ macroexpand / eval), 1:1 mapping to a Zig error union, threadlocal
`Info` payload, 64-frame call stack. That part is fine.

What is **not** centralised is the *message body*. Each call site
writes its own `comptime fmt: []const u8` directly into
`setErrorFmt(.eval, .type_error, loc, "{s}: expected number, got {s}", args)`.
There are about 80 such call sites across `src/eval/`, `src/lang/`,
and `src/runtime/`. Three problems compound:

1. **Drift**: the same semantic error appears with slightly different
   wording in different files (e.g., the four variants of "Wrong
   number of args ..." in `error.zig`, `core.zig`, `error.zig`
   inside `lang/primitive/`, and `tree_walk.zig`).
2. **Development calendar leaks into user-facing text**. The current
   scaffolding documents and earlier ADR drafts illustrated
   not-yet-implemented errors with strings such as
   `"dosync: STM activates at Phase 15, see ADR-0010"` or
   `"Phase 5: deftype not yet implemented, see ADR-0007"`. "Phase 15"
   and "ADR-0010" are cw v1 development concepts; a user running
   `cljw -e '(dosync ...)'` should not see them.
3. **No grep surface for the message catalog**. There is no single
   file that answers "what user-facing errors does cljw produce".
   A grep across `setErrorFmt` works but mixes templates with
   surrounding code.

URL-style references (`See: https://...`) were considered for the
"see also" slot. They are excluded from the catalog at this stage —
no public docs site exists yet, and per-message URLs would either
hard-code a domain that does not exist or carry empty placeholders.
Until the docs site is up, the user sees the structured error message
only.

## Decision

Introduce `src/runtime/error_catalog.zig` as the Single Source Of
Truth for every user-facing error message in the cw runtime.

### Shape

```zig
//! src/runtime/error_catalog.zig
const std = @import("std");
const error_mod = @import("error.zig");

pub const Kind = error_mod.Kind;
pub const Phase = error_mod.Phase;
pub const SourceLocation = error_mod.SourceLocation;
pub const Error = error_mod.Error;

/// One variant per distinct user-facing message.
pub const Code = enum {
    // parser / analyzer / macroexpand / eval entries
    eval_type_expected_number,
    eval_arity_wrong,
    // ...
    /// Feature is on the roadmap but not yet implemented.
    /// args: .{ .name = "<feature>" }
    unsupported_feature,
    /// Feature is permanently excluded (Tier D, ADR-0013).
    /// args: .{ .name = "<form>" }
    tier_d_form,
    // ...
};

const Entry = struct { kind: Kind, phase: Phase, template: []const u8 };

pub fn entry(comptime code: Code) Entry {
    return switch (code) {
        .eval_type_expected_number => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected number, got {[actual]s}",
        },
        .unsupported_feature => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "{[name]s} is not supported in ClojureWasm",
        },
        .tier_d_form => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "{[name]s} is not part of ClojureWasm",
        },
        // ...
    };
}

pub fn raise(comptime code: Code, location: SourceLocation, args: anytype) Error {
    const e = comptime entry(code);
    return error_mod.setErrorFmt(e.phase, e.kind, location, e.template, args);
}
```

### Rules

1. **`error_catalog.zig` is the only file allowed to call
   `setErrorFmt` directly.** Every other module calls
   `error_catalog.raise(.your_code, loc, args)`. This is enforced by
   `.claude/rules/error_catalog_only.md` and (Phase 5+) by
   `scripts/check_no_op_stub.sh` style heuristic grep.
2. **Adding a new error is two edits**: append a `Code` variant +
   append the matching `entry()` arm. Never write a new `setErrorFmt`
   call outside this file.
3. **Templates must not name development concepts**. "Phase N",
   "ADR-NNNN", internal opcode names, file paths inside cw, and URLs
   are forbidden in template strings. A reviewer who is not the
   author has to be able to read the template and understand what
   the user did wrong.
4. **Unsupported features and Tier D forms use a `{name}` slot**.
   The form / feature name (`dosync`, `gen-class`, `deftype`, ...)
   is supplied via the args struct so that the same Code entry
   covers every concrete form. No per-form Code variants.

### Named format args

Zig 0.16 `std.fmt.bufPrint` accepts `{[field_name]<specifier>}`
syntax against a struct args value
(`std.fmt.zig:1304-1305` carries the canonical example). The catalog
relies on this so callers pass `.{ .fn_name = "+", .actual = "keyword" }`
rather than positional tuples. Named slots are self-documenting at
the call site and make adding / removing slots non-breaking when the
slot is not yet used by other callers.

## Alternatives considered

### Alternative A — YAML or ZON data file

- **Sketch**: `error_catalog.yaml` or `.zon` at repo root, parsed at
  build time.
- **Why rejected**: introduces a build step (codegen) for a value
  that Zig comptime already expresses well. `compat_tiers.yaml` is
  YAML because it is consumed by multiple tools (test runner, REPL,
  future `cljw --list-vars`); the error catalog is consumed only by
  the runtime, so the cheap path is a Zig switch.

### Alternative B — One Zig function per error

- **Sketch**: `error_catalog.zig` exports
  `raiseTypeExpectedNumber(loc, fn_name, actual_type)` per error.
- **Why rejected**: 80+ functions, each with hand-written parameter
  lists. The `raise(comptime Code, args)` shape covers the same
  surface in one function and keeps the type / phase / template in
  one place per error.

### Alternative C — Per-call-site URL reference

- **Sketch**: each template ends with
  `"\nSee: https://cw.org/errors#<slug>"`.
- **Why rejected at this stage**: no docs site exists yet. Hard-coded
  URLs would either point at a 404 or carry placeholders that age
  badly. The catalog stays URL-free until the public docs site is
  defined.

## Consequences

- **Positive**: every user-facing error is one grep away. Adding a
  new error is mechanical. The user no longer sees development
  calendar text. The reviewer can audit the message catalog without
  cross-referencing source files.
- **Negative**: existing 80 `setErrorFmt` call sites migrate to
  `raise(.code, loc, args)`. The migration itself is mechanical but
  not free; tracked as Phase 4 task 4.26.
- **Neutral / follow-ups**: when the public docs site exists, a
  follow-up ADR amends this one to add an optional `docs_anchor`
  field to `Entry`. The runtime formatter can then opt-in to render
  `"See: <base_url>/<anchor>"` at the end of each message. Until
  then, the catalog stays URL-free.

## References

- `src/runtime/error.zig` (existing `Kind` / `Phase` / `Info` /
  `setErrorFmt` infrastructure)
- ROADMAP §2 P6 (Error quality is non-negotiable)
- ROADMAP §A11 (day-1 enum reservation — the catalog `Code` enum is
  the error-axis equivalent)
- ROADMAP §9.6 task 4.26 (migration task)
- Related ADRs: 0009, 0010, 0013, 0017 (error message examples in
  those ADRs have been amended to remove development-calendar leaks)
- Rule: `.claude/rules/error_catalog_only.md`
- Zig 0.16 `std.fmt.bufPrint` named placeholder syntax
  (`zig/lib/std/fmt.zig:1304-1305`)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
