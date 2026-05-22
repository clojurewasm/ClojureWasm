---
paths:
  - src/**/*.zig
---

# Error catalog is the only message source

## Rule

User-facing error messages come from `src/runtime/error_catalog.zig`
only. Other modules call `error_catalog.raise(.code, loc, args)`;
direct `error_mod.setErrorFmt(...)` calls are reserved for the
catalog itself. The Zig error union returned is `ClojureWasmError`
(full spelling) so the catch surface and failing test traces name
the project.

## Why

- Single grep surface for every message the runtime produces.
- Templates stay consistent (no drift between similar errors written
  in two files).
- Development concepts (Phase numbers, ADR identifiers, internal
  file paths, URLs) cannot leak into user-facing text because the
  catalog template is the only place those would live, and the
  catalog forbids them.
- Adding a new error is two edits in one file rather than a fresh
  `setErrorFmt(...)` call somewhere new.
- `Kind` (16 variants today) is the user-visible category label
  (`[name_error]` / `[type_error]` / ...) so the user grasps what
  kind of problem they hit without seeing the catalog `Code`. It is
  also the `catch |err|` discriminator for cw internal dispatch.

## How to apply

### Adding a new error

1. Append a variant to `Code` in `src/runtime/error_catalog.zig`.
   Naming follows the `<target>_<state-adjective>` convention
   (see below).
2. Append the matching `entry()` arm with `kind`, `phase`, and a
   `template` using named placeholders
   (`"{[fn_name]s}: expected number, got {[actual]s}"`).
3. Call `raise(.your_code, loc, .{ ... named args ... })` at the
   raise site. The return type is `ClojureWasmError`.

### Code variant naming convention

`<target>_<state-adjective>` in snake_case, prioritising the form /
construct the user wrote over internal classification:

- `delimiter_unexpected`, not `parse_unexpected_delimiter`.
- `string_unterminated`, not `parse_unterminated_string`.
- `def_arity_invalid`, not `analysis_def_arity`.
- `type_arg_not_number`, not `eval_type_expected_number`.
- `arity_invalid`, `let_bindings_invalid`,
  `if_let_bindings_not_pair`, ...

Exceptions (Tier D and sub-feature staged unsupported keep a prefix):

- Tier D: `tier_d_<form-slug>` — `tier_d_gen_class`,
  `tier_d_gen_interface`, `tier_d_compile`, `tier_d_proxy_deep`,
  `tier_d_bean_deep`. One Code per form, with a hand-written
  user-helpful template (often multiple sentences) that explains
  the reason and suggests the cw-native alternative.
- Sub-feature staged: `<feature>_<sub-op>_not_supported` —
  `stm_dosync_not_supported`, `stm_commute_not_supported`, ...
  Transient Codes that disappear when the sub-operation lands.
- Generic fallback: `feature_not_supported` (no prefix; the sole
  exception). Use only when the feature has not yet been broken
  down into sub-feature Codes.

The `Phase` is **not** encoded in the Code name; the `entry()` arm
carries it.

### Template hygiene

Templates must NOT contain:

- Phase numbers (`"Phase 5: ..."`).
- ADR identifiers (`"see ADR-0010"`).
- Tier classification labels (`"Tier D: ..."`).
- URLs (`"https://..."`).
- cw internal file paths (`"src/eval/analyzer.zig"`).

Templates SHOULD:

- Name the construct the user wrote (`"dosync"`, `"gen-class"`).
- Use the same wording as comparable errors (consistency).
- Quote string-like arguments (`'{[token]s}'`).
- For Tier D Codes specifically: a 1-3 sentence template that
  explains *why* (the technical reason) and *what to use instead*
  (the cw-native alternative).

### Tier D forms

For Tier D forms (permanently out of scope), each form has its own
Code with a hand-written template:

```zig
return error_catalog.raise(.tier_d_gen_class, loc, .{});
// → "gen-class requires emitting JVM bytecode classes, which is
//    outside the scope of ClojureWasm. Use deftype + defprotocol
//    for cw-native type definitions."
```

The form name appears in the template itself (no `{name}` slot).

### Sub-feature staged unsupported

For features landing across multiple Phases (STM, atom watchers,
agent action queue, ...), each unimplemented sub-operation gets its
own Code:

```zig
return error_catalog.raise(.stm_dosync_not_supported, loc, .{});
// → "dosync is not yet supported in ClojureWasm."
```

When the sub-operation lands (e.g. Phase 15.1 implements `dosync`),
the Code is removed from `error_catalog.zig` and the raise site is
deleted.

### Generic fallback

`feature_not_supported` carries a `{name}` slot and renders
`"<name> is not yet supported in ClojureWasm."`. Use only when the
feature has not been resolved into specific sub-feature Codes yet.
Each call site is a candidate for promotion to a named Code as
Phase planning resolves.

## Counter-examples

Don't add a new `setErrorFmt(.eval, .type_error, loc, "...", args)`
call outside `error_catalog.zig`. Add a `Code` variant instead.

Don't write `"Tier D: dosync, see ADR-0013"` — the user does not
care which tier or ADR.

Don't write `"Phase 15: STM not yet wired"` — Phase 15 is a cw
development concept.

Don't reuse `tier_d_gen_class` for a different form. One Code per
Tier D form.

## Enforcement

- ADR-0018 specifies the contract.
- Phase 5+: `scripts/check_no_op_stub.sh` extends to flag bare
  `setErrorFmt(...)` calls outside `error_catalog.zig` (heuristic
  grep). Phase 4 entry: informational only.
- Reviewers reject `setErrorFmt(...)` introductions outside the
  catalog.
