---
paths:
  - src/**/*.zig
---

# Error catalog is the only message source

## Rule

User-facing error messages come from `src/runtime/error_catalog.zig`
only. Other modules call `error_catalog.raise(.code, loc, args)`;
direct `setErrorFmt(...)` calls are reserved for the catalog itself.

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

## How to apply

### Adding a new error

1. Append a variant to `Code` in `src/runtime/error_catalog.zig`.
   Name it after what the user did wrong, not the internal
   classification (e.g., `eval_type_expected_number`, not
   `type_error_eval_215`).
2. Append the matching `entry()` arm with `kind`, `phase`, and a
   `template` using named placeholders
   (`"{[fn_name]s}: expected number, got {[actual]s}"`).
3. Call `raise(.your_code, loc, .{ ... named args ... })` at the
   raise site.

### Template hygiene

Templates must NOT contain:

- Phase numbers (`"Phase 5: ..."`).
- ADR identifiers (`"see ADR-0010"`).
- Tier classification names (`"Tier D: ..."`).
- URLs (`"https://..."`).
- cw internal file paths (`"src/eval/analyzer.zig"`).

Templates SHOULD:

- Name the construct the user wrote (`"dosync"`, `"gen-class"`).
- Use the same wording as comparable errors (consistency).
- Quote string-like arguments (`'{[token]s}'`).

### Unsupported features and Tier D forms

For "not yet supported" features use `Code.unsupported_feature` and
pass the form name via args:

```zig
return error_catalog.raise(.unsupported_feature, loc, .{ .name = "dosync" });
// → "dosync is not supported in ClojureWasm"
```

For Tier D forms (permanently out of scope) use `Code.tier_d_form`:

```zig
return error_catalog.raise(.tier_d_form, loc, .{ .name = "gen-class" });
// → "gen-class is not part of ClojureWasm"
```

Both shapes name the specific form so the user sees what they wrote,
not a coarse category.

## Counter-examples

Don't add a new `setErrorFmt(.eval, .type_error, loc, "...", args)`
call outside `error_catalog.zig`. Add a `Code` variant instead.

Don't write `"Tier D: dosync, see ADR-0013"` — the user does not
care which tier or ADR. They care that `dosync` did not work.

Don't write `"Phase 15: STM not yet wired"` — Phase 15 is a cw
development concept.

## Enforcement

- ADR-0018 specifies the contract.
- Phase 5+: `scripts/check_no_op_stub.sh` extends to flag bare
  `setErrorFmt(...)` calls outside `error_catalog.zig` (heuristic
  grep). Phase 4 entry: informational only.
- Reviewers reject `setErrorFmt(...)` introductions outside the
  catalog.
