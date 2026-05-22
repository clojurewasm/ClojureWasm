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
/// SSOT name for the Zig error union returned by every raise site.
/// Renamed from the original `Error` so that the `catch |err|` site
/// surface (and the failing test trace) names the project explicitly.
pub const ClojureWasmError = error_mod.ClojureWasmError;

/// One variant per distinct user-facing message.
pub const Code = enum {
    // Parse / Analysis / Macroexpand / Eval entries follow the
    // <target>_<state-adjective> naming convention (see "Code variant
    // naming conventions" below). Examples:
    delimiter_unexpected,
    string_unterminated,
    def_arity_invalid,
    type_arg_not_number,
    arity_invalid,
    // ...

    // Tier D forms: one Code per form, each with a hand-written
    // user-helpful template. No `{name}` slot — the template is
    // tailored to the specific form (per Shota's directive that
    // "implementation refusals deserve individual care").
    tier_d_gen_class,
    tier_d_gen_interface,
    tier_d_compile,
    tier_d_proxy_deep,
    tier_d_bean_deep,

    // Sub-feature staged unsupported. While a feature (e.g. STM)
    // lands incrementally across Phase 13-15, the entry-point form
    // becomes usable but specific sub-operations are still raise
    // sites. Each sub-operation gets its own Code so the user sees
    // exactly which step is missing.
    stm_dosync_not_supported,
    stm_commute_not_supported,
    // ... (one Code per sub-operation, added/removed as Phases land)

    // Generic fallback for "on the roadmap, not yet broken into
    // sub-feature Codes". Use sparingly; promote to a sub-feature
    // Code as soon as the feature's Phase planning has resolution.
    /// args: .{ .name = "<feature>" }
    feature_not_supported,
};

const Entry = struct { kind: Kind, phase: Phase, template: []const u8 };

pub fn entry(comptime code: Code) Entry {
    return switch (code) {
        .delimiter_unexpected => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unexpected delimiter '{[delim]s}'",
        },
        .type_arg_not_number => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected number, got {[actual]s}",
        },
        .tier_d_gen_class => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "gen-class requires emitting JVM bytecode classes, which is outside the scope of ClojureWasm. Use deftype + defprotocol for cw-native type definitions.",
        },
        .feature_not_supported => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "{[name]s} is not supported in ClojureWasm",
        },
        // ... (every other Code arm follows the same shape)
    };
}

pub fn raise(comptime code: Code, location: SourceLocation, args: anytype) ClojureWasmError {
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
   are forbidden in **template strings** (i.e., the `template` field
   of an `entry()` arm). The same identifiers remain fine in ADR
   prose, rule docs, code comments — anywhere a developer reads them.
   The boundary is: anything `std.fmt.bufPrint` would render into a
   message shown to a `cljw` user must pass this rule.
4. **Two patterns for unsupported features, by intent**:
   - **Permanent exclusion (Tier D)**: one `Code` variant per form,
     hand-written user-helpful template. No `{name}` slot — the
     wording is specific to that form's reason and suggests the
     cw-native alternative. There are 5 such Codes today
     (`tier_d_gen_class`, `tier_d_gen_interface`, `tier_d_compile`,
     `tier_d_proxy_deep`, `tier_d_bean_deep`) matching
     `compat_tiers.yaml` Tier D enumeration.
   - **Roadmap-but-not-yet (sub-feature staged)**: while a feature
     lands incrementally (e.g. STM across Phase 13-15), the entry
     form is usable but specific sub-operations remain raise sites.
     Each sub-operation gets its own Code
     (`stm_dosync_not_supported`, `stm_commute_not_supported`, ...)
     so the user sees exactly which step is missing. Codes are
     added when a sub-operation is identified as unsupported and
     removed when the sub-operation is implemented.
   - **Generic fallback `feature_not_supported`**: for cases that
     have not yet been resolved into sub-feature Codes. Carries the
     `{name}` slot. Treated as a temporary state — promote to a
     concrete sub-feature Code when the feature's Phase planning
     gives resolution. The Phase 5+ audit reviews this Code's call
     sites and promotes each to a named Code.

### Code variant naming conventions

The `Code` enum's variant names use **`<target>_<state-adjective>`**
in snake_case, prioritising the form / construct the user wrote over
internal classification:

- `delimiter_unexpected`, not `parse_unexpected_delimiter` and not
  `eval_type_error_215`.
- `string_unterminated`, `integer_invalid`, `def_arity_invalid`,
  `type_arg_not_number`, `arity_invalid`, `let_bindings_invalid`.
- For Tier D: `tier_d_<form-slug>` (the only prefix-style Code names).
- For sub-feature staged unsupported: `<feature>_<sub-op>_not_supported`
  (e.g. `stm_dosync_not_supported`).
- For `feature_not_supported` (generic fallback): no prefix, this is
  the one exception.

When two raise sites express the *same* user-visible error, they
share one `Code` variant. Distinct user wording = distinct variant.

The `Phase` is **not** encoded in the Code name; the `entry()` arm
carries the Phase. This keeps the Code name focused on what the user
sees, not where in the pipeline the runtime detected it.

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
  cross-referencing source files. The `[name_error]` /
  `[type_error]` etc. labels in user-facing output give the user a
  category handle ("what kind of problem is this?") without exposing
  the catalog `Code` identifier.
- **Negative**: the existing ~116 `setErrorFmt` call sites (measured
  by `grep -rn "setErrorFmt" src/ | wc -l`, including the helper
  fns `expectNumber` / `checkArity` / `checkArityMin` /
  `checkArityRange` in `error.zig` that today carry inline
  templates) migrate to `raise(.code, loc, args)`. The migration is
  mechanical but not free; tracked as Phase 4 task 4.26. The
  count is approximate because each `error.zig` helper expands to
  one inline `setErrorFmt` call per call path, and the helpers
  themselves migrate to the catalog (their templates become
  catalog entries).
- **Negative**: the Zig error-union name change from `Error` to
  `ClojureWasmError` (full spelling preferred over `CWError`)
  cascades through every `pub fn ... !Value` signature that
  currently spells `error_mod.Error`. The change is grep-and-replace
  but the file count is non-trivial; bundled into task 4.26.
- **Neutral / follow-ups**:
  - `Kind` is intentionally kept (16 variants today). Its job is
    twofold: (i) the user-visible category label
    (`[type_error]` etc.) so the user grasps "what kind of problem
    is this?" without seeing the catalog `Code`, and (ii) the
    `catch |err|` discriminator (`error.NameError` / `error.TypeError`
    / ...) for cw runtime internal dispatch. Adding a `Kind` variant
    is allowed when an existing category does not fit; the discipline
    is to grow `Kind` rarely (every new variant has a justification
    in the amending ADR or in this one). Earlier drafts of this ADR
    considered removing `Kind` to reduce redundancy; that was
    rejected because both jobs above genuinely need it.
  - Each Tier D form has its own Code (5 today). When a new Tier D
    form is added (a MAJOR release per ADR-0013), a new Code lands
    with it; the template is hand-written and may run to multiple
    sentences to suggest the cw-native alternative.
  - Sub-feature staged unsupported Codes (`stm_*_not_supported`,
    later `host_io_*_not_supported`, etc.) are *transient*. A Code
    of this kind exists only while its sub-operation is unimplemented;
    removing it is part of the Phase that implements the
    sub-operation. The catalog's growth is therefore not monotonic —
    Codes come and go.
  - When the public docs site exists, a follow-up amends this ADR
    to add an optional `docs_anchor` field to `Entry`. The runtime
    formatter can then opt-in to render
    `"See: <base_url>/<anchor>"` at the end of each message. Until
    then, the catalog stays URL-free.
  - Task 4.26 is large (~116 sites). At task open the implementer
    splits it into sub-tasks per source-tree region (`reader.zig`,
    `analyzer.zig`, `tree_walk.zig`, `lang/macro_transforms.zig`,
    `lang/primitive/*`, `runtime/error.zig` helpers); see
    handover.md when 4.26 is the active task.
  - Crash policy (when `@panic` is acceptable, when `internal_error`
    catalog raise is required, what happens on a native crash) is
    addressed in a separate ADR-0019.

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
- 2026-05-23 (amendment 1): Rule 3 sharpened with the
  template-vs-prose boundary. Added `Code` variant naming conventions.
  Consequences expanded with (i) the rationale for `tier_d_form` and
  `unsupported_feature` sharing `Kind.not_implemented`, (ii) the
  measured ~116 site count and helper-fn migration note, (iii)
  sub-task split guidance for task 4.26. Self-review feedback.
- 2026-05-23 (amendment 2): Major reshape per user direction.
  (a) Code naming convention changed from
  `<phase>_<verb-phrase>` to `<target>_<state-adjective>` for lower
  cognitive load (`type_arg_not_number` instead of
  `eval_type_expected_number`, etc.). Phase is no longer encoded in
  the Code name; the `entry()` arm carries it.
  (b) Tier D split into one Code per form
  (`tier_d_gen_class` / `tier_d_gen_interface` / `tier_d_compile` /
  `tier_d_proxy_deep` / `tier_d_bean_deep`), each with a
  hand-written user-helpful template that explains the reason and
  suggests the cw-native alternative. The generic `tier_d_form`
  with `{name}` slot is dropped.
  (c) Sub-feature staged unsupported pattern introduced. While a
  feature lands across multiple Phases, each unimplemented
  sub-operation gets its own Code (e.g.
  `stm_dosync_not_supported`). These Codes are transient — they
  disappear when the sub-operation is implemented.
  (d) Generic `feature_not_supported` (renamed from
  `unsupported_feature`) kept as a temporary fallback for cases not
  yet resolved into sub-feature Codes.
  (e) `Kind` is kept (earlier removal proposal rejected). It serves
  both as user-visible category label and as `catch |err|`
  discriminator.
  (f) Zig error union renamed from `Error` to `ClojureWasmError`
  so the catch surface and failing test traces name the project.
  All changes are reflected in catalog source as part of task 4.26
  (the existing 28 Codes from the initial landing will be renamed
  in the same task).
