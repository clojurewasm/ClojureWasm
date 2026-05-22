//! Error catalog — Single Source Of Truth for cw user-facing error
//! messages. Per ADR-0018.
//!
//! Why this file exists:
//!   - `error.zig` centralises Kind / Phase / Info / call stack, but
//!     message bodies were ad-hoc `comptime fmt: []const u8` strings
//!     written at each call site (~100 sites). The catalog removes
//!     that ad-hoc surface.
//!   - User-facing text must not leak development concepts
//!     (Phase numbers, ADR identifiers, runtime file paths, URLs).
//!     A single catalog file is the easiest place to enforce that.
//!
//! Adding a new error:
//!   1. Append a variant to `Code` below.
//!   2. Append the matching `entry()` arm with kind / phase /
//!      template (named `{[field]s}` placeholders).
//!   3. Call `raise(.your_code, loc, .{ ... named args ... })` at the
//!      raise site.
//!
//! Direct `setErrorFmt(...)` calls outside this file are reserved
//! for the catalog itself. Other modules must call `raise(...)`.
//! Enforced by `.claude/rules/error_catalog_only.md`.
//!
//! Migration of the existing ~100 `setErrorFmt` call sites is
//! tracked as ROADMAP §9.6 task 4.26. The catalog ships first;
//! call sites migrate incrementally.

const std = @import("std");
const error_mod = @import("error.zig");

pub const Kind = error_mod.Kind;
pub const Phase = error_mod.Phase;
pub const SourceLocation = error_mod.SourceLocation;
pub const Error = error_mod.Error;

/// One variant per distinct user-facing message.
///
/// Conventions:
///   - Prefix indicates the phase (`parse_` / `analysis_` /
///     `macro_` / `eval_`) or the cross-phase category (`unsupported_`,
///     `tier_d_`).
///   - Names describe what the user did wrong, not how the runtime
///     classifies it internally.
pub const Code = enum {
    // --- Parse ---
    parse_unexpected_delimiter,
    parse_unexpected_eof,
    parse_invalid_token,
    parse_invalid_integer,
    parse_invalid_float,
    parse_unterminated_string,
    parse_map_literal_odd_forms,

    // --- Analysis ---
    analysis_def_arity,
    analysis_def_name_must_be_symbol,
    analysis_if_arity,
    analysis_unable_to_resolve,
    analysis_let_bindings_must_be_vector,
    analysis_let_bindings_must_be_even,

    // --- Macroexpand ---
    macro_let_requires_bindings_and_body,
    macro_cond_requires_even_forms,

    // --- Eval (type / arity) ---
    eval_type_expected_number,
    eval_type_expected_integer,
    eval_type_expected_boolean,
    eval_type_cannot_call,
    eval_arity_wrong,
    eval_arity_at_least,
    eval_arity_between,
    eval_arity_exact,

    // --- Unsupported / Tier ---
    /// Feature is on the cw roadmap but not yet implemented in this
    /// release. The user sees only the feature name; the development
    /// calendar (Phase numbers, ADR identifiers) stays internal.
    ///
    /// args: `.{ .name = "<feature>" }`
    unsupported_feature,

    /// Feature is permanently outside cw scope (Tier D per ADR-0013).
    /// Same shape as `unsupported_feature` from the user's
    /// perspective — the user sees the feature name, not the tier
    /// classification.
    ///
    /// args: `.{ .name = "<form>" }`
    tier_d_form,

    // --- System ---
    out_of_memory,
    internal_error,
};

const Entry = struct {
    kind: Kind,
    phase: Phase,
    template: []const u8,
};

/// Per-`Code` metadata. Comptime-evaluated; the switch arms hold the
/// authoritative template strings.
pub fn entry(comptime code: Code) Entry {
    return switch (code) {
        // --- Parse ---
        .parse_unexpected_delimiter => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unexpected delimiter '{[delim]s}'",
        },
        .parse_unexpected_eof => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unexpected EOF while reading form",
        },
        .parse_invalid_token => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Invalid token '{[token]s}'",
        },
        .parse_invalid_integer => .{
            .kind = .number_error, .phase = .parse,
            .template = "Invalid integer literal '{[text]s}'",
        },
        .parse_invalid_float => .{
            .kind = .number_error, .phase = .parse,
            .template = "Invalid float literal '{[text]s}'",
        },
        .parse_unterminated_string => .{
            .kind = .string_error, .phase = .parse,
            .template = "Unterminated string literal",
        },
        .parse_map_literal_odd_forms => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Map literal must contain an even number of forms",
        },

        // --- Analysis ---
        .analysis_def_arity => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "def expects 1 or 2 args, got {[got]d}",
        },
        .analysis_def_name_must_be_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "First argument to def must be a symbol",
        },
        .analysis_if_arity => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "if expects 2 or 3 args, got {[got]d}",
        },
        .analysis_unable_to_resolve => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Unable to resolve symbol: '{[sym]s}'",
        },
        .analysis_let_bindings_must_be_vector => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "let* bindings must be a vector",
        },
        .analysis_let_bindings_must_be_even => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "let* bindings must have an even number of forms",
        },

        // --- Macroexpand ---
        .macro_let_requires_bindings_and_body => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "let requires bindings vector and at least one body form",
        },
        .macro_cond_requires_even_forms => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "cond requires an even number of forms (got {[got]d})",
        },

        // --- Eval (type) ---
        .eval_type_expected_number => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected number, got {[actual]s}",
        },
        .eval_type_expected_integer => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected integer, got {[actual]s}",
        },
        .eval_type_expected_boolean => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected boolean, got {[actual]s}",
        },
        .eval_type_cannot_call => .{
            .kind = .type_error, .phase = .eval,
            .template = "Cannot call value of type '{[actual]s}'",
        },

        // --- Eval (arity) ---
        .eval_arity_wrong => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}",
        },
        .eval_arity_at_least => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected at least {[min]d}",
        },
        .eval_arity_between => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected {[min]d} to {[max]d}",
        },
        .eval_arity_exact => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected {[expected]d}",
        },

        // --- Unsupported / Tier ---
        .unsupported_feature => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "{[name]s} is not supported in ClojureWasm",
        },
        .tier_d_form => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "{[name]s} is not part of ClojureWasm",
        },

        // --- System ---
        .out_of_memory => .{
            .kind = .out_of_memory, .phase = .eval,
            .template = "Out of memory",
        },
        .internal_error => .{
            .kind = .internal_error, .phase = .eval,
            .template = "Internal error: {[detail]s}",
        },
    };
}

/// Raise the catalog error identified by `code`. `args` is a struct
/// whose fields match the named placeholders in the corresponding
/// `entry()` template (e.g., `.{ .fn_name = "+", .actual = "keyword" }`).
///
/// On message buffer overflow `setErrorFmt` truncates with a trailing
/// "..." per the existing convention in `error.zig`.
pub fn raise(comptime code: Code, location: SourceLocation, args: anytype) Error {
    const e = comptime entry(code);
    return error_mod.setErrorFmt(e.phase, e.kind, location, e.template, args);
}

// --- Tests ---

const testing = std.testing;

test "raise produces matching Kind / Phase and renders template" {
    const err = raise(.eval_type_expected_number, .{ .file = "t.clj", .line = 1, .column = 0 }, .{
        .fn_name = "+",
        .actual = "keyword",
    });
    try testing.expectEqual(Error.TypeError, err);

    const info = error_mod.getLastError().?;
    try testing.expectEqual(Kind.type_error, info.kind);
    try testing.expectEqual(Phase.eval, info.phase);
    try testing.expectEqualStrings("+: expected number, got keyword", info.message);
    try testing.expectEqualStrings("t.clj", info.location.file);
}

test "unsupported_feature uses .name slot, no Phase or ADR leak" {
    _ = raise(.unsupported_feature, .{}, .{ .name = "dosync" }) catch {};
    const info = error_mod.getLastError().?;
    try testing.expectEqualStrings("dosync is not supported in ClojureWasm", info.message);
    // The user-facing message must not contain development markers.
    try testing.expect(std.mem.indexOf(u8, info.message, "Phase") == null);
    try testing.expect(std.mem.indexOf(u8, info.message, "ADR-") == null);
    try testing.expect(std.mem.indexOf(u8, info.message, "http") == null);
}

test "tier_d_form names the form, never the tier classification" {
    _ = raise(.tier_d_form, .{}, .{ .name = "gen-class" }) catch {};
    const info = error_mod.getLastError().?;
    try testing.expectEqualStrings("gen-class is not part of ClojureWasm", info.message);
    try testing.expect(std.mem.indexOf(u8, info.message, "Tier") == null);
    try testing.expect(std.mem.indexOf(u8, info.message, "ADR-") == null);
}

test "arity templates render all three variants" {
    _ = raise(.eval_arity_wrong, .{}, .{ .got = 3, .fn_name = "inc" }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (3) passed to inc",
        error_mod.getLastError().?.message,
    );

    _ = raise(.eval_arity_at_least, .{}, .{ .got = 1, .fn_name = "+", .min = 2 }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (1) passed to +, expected at least 2",
        error_mod.getLastError().?.message,
    );

    _ = raise(.eval_arity_between, .{}, .{ .got = 0, .fn_name = "subs", .min = 2, .max = 3 }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (0) passed to subs, expected 2 to 3",
        error_mod.getLastError().?.message,
    );
}
