//! Error catalog — Single Source Of Truth for cw user-facing error
//! messages. Per ADR-0018 (amendment 2 — `<target>_<state-adjective>`
//! naming convention; phase no longer encoded in the Code name).
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
/// Naming convention (ADR-0018 amendment 2):
/// `<target>_<state-adjective>` — name the construct the user wrote
/// and the way it is wrong, not how the runtime classifies it
/// internally. `Phase` is no longer encoded in the name; it lives
/// on the `entry()` arm.
///
/// Exceptions: `tier_d_<form-slug>` for Tier D forms (one Code per
/// form), `<feature>_<sub-op>_not_supported` for sub-feature staged
/// unsupported, and the generic `feature_not_supported` fallback.
pub const Code = enum {
    // --- Parse / read ---
    delimiter_unexpected,
    eof_unexpected,
    token_invalid,
    integer_literal_invalid,
    float_literal_invalid,
    string_unterminated,
    map_literal_arity_odd,

    // --- Analysis (def / if / let / symbol resolution / arity) ---
    def_arity_invalid,
    def_name_not_symbol,
    if_arity_invalid,
    symbol_unresolved,
    let_bindings_not_vector,
    let_bindings_arity_odd,
    /// loop* / recur arity exceeds the internal slot-index width.
    /// args: `.{ .form = "loop*"|"recur", .got = N, .max = 65535 }`
    arity_too_large,

    // --- Macroexpand ---
    let_form_incomplete,
    cond_clauses_arity_odd,

    // --- Eval (type) ---
    type_arg_not_number,
    type_arg_not_integer,
    type_arg_not_boolean,
    value_not_callable,

    // --- Eval (arity at call) ---
    arity_invalid,
    arity_below_min,
    arity_out_of_range,
    arity_not_expected,

    // --- Unsupported / Tier ---
    /// Feature is on the cw roadmap but not yet implemented in this
    /// release. The user sees only the feature name; the development
    /// calendar (Phase numbers, ADR identifiers) stays internal.
    ///
    /// args: `.{ .name = "<feature>" }`
    feature_not_supported,

    /// Tier D forms — permanently outside cw scope (ADR-0013). One
    /// Code per form, each with a hand-written multi-sentence
    /// template that explains the reason and suggests the
    /// cw-native alternative. No `.name` slot: the form name is
    /// baked into the template.
    tier_d_gen_class,
    tier_d_gen_interface,
    tier_d_compile,
    tier_d_proxy_deep,
    tier_d_bean_deep,

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
        // --- Parse / read ---
        .delimiter_unexpected => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unexpected delimiter '{[delim]s}'",
        },
        .eof_unexpected => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unexpected EOF while reading form",
        },
        .token_invalid => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Invalid token '{[token]s}'",
        },
        .integer_literal_invalid => .{
            .kind = .number_error, .phase = .parse,
            .template = "Invalid integer literal '{[text]s}'",
        },
        .float_literal_invalid => .{
            .kind = .number_error, .phase = .parse,
            .template = "Invalid float literal '{[text]s}'",
        },
        .string_unterminated => .{
            .kind = .string_error, .phase = .parse,
            .template = "Unterminated string literal",
        },
        .map_literal_arity_odd => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Map literal must contain an even number of forms",
        },

        // --- Analysis ---
        .def_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "def expects 1 or 2 args, got {[got]d}",
        },
        .def_name_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "First argument to def must be a symbol",
        },
        .if_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "if expects 2 or 3 args, got {[got]d}",
        },
        .symbol_unresolved => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Unable to resolve symbol: '{[sym]s}'",
        },
        .let_bindings_not_vector => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "let* bindings must be a vector",
        },
        .let_bindings_arity_odd => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "let* bindings must have an even number of forms",
        },
        .arity_too_large => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "{[form]s} arity {[got]d} exceeds the limit of {[max]d}",
        },

        // --- Macroexpand ---
        .let_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "let requires bindings vector and at least one body form",
        },
        .cond_clauses_arity_odd => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "cond requires an even number of forms (got {[got]d})",
        },

        // --- Eval (type) ---
        .type_arg_not_number => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected number, got {[actual]s}",
        },
        .type_arg_not_integer => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected integer, got {[actual]s}",
        },
        .type_arg_not_boolean => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected boolean, got {[actual]s}",
        },
        .value_not_callable => .{
            .kind = .type_error, .phase = .eval,
            .template = "Cannot call value of type '{[actual]s}'",
        },

        // --- Eval (arity) ---
        .arity_invalid => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}",
        },
        .arity_below_min => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected at least {[min]d}",
        },
        .arity_out_of_range => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected {[min]d} to {[max]d}",
        },
        .arity_not_expected => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected {[expected]d}",
        },

        // --- Unsupported / Tier ---
        .feature_not_supported => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "{[name]s} is not supported in ClojureWasm",
        },
        .tier_d_gen_class => .{
            .kind = .not_implemented, .phase = .analysis,
            .template =
                "gen-class is not part of ClojureWasm. " ++
                "gen-class emits JVM bytecode classes, which are not produced by the cw runtime. " ++
                "Use deftype + defprotocol for cw-native type definitions.",
        },
        .tier_d_gen_interface => .{
            .kind = .not_implemented, .phase = .analysis,
            .template =
                "gen-interface is not part of ClojureWasm. " ++
                "gen-interface emits JVM bytecode interfaces, which are not produced by the cw runtime. " ++
                "Use defprotocol to declare an interface in cw.",
        },
        .tier_d_compile => .{
            .kind = .not_implemented, .phase = .analysis,
            .template =
                "compile is not part of ClojureWasm. " ++
                "compile triggers JVM bytecode emission to ahead-of-time .class files. " ++
                "cw binaries are produced by `cljw build` from source; per-namespace AOT is not on the roadmap.",
        },
        .tier_d_proxy_deep => .{
            .kind = .not_implemented, .phase = .analysis,
            .template =
                "proxy against this base class is not part of ClojureWasm. " ++
                "proxy targeting AWT, Swing, Apache HttpComponents, or java.util.logging requires deep JVM class extension. " ++
                "Use reify against cw-native protocols for anonymous instances; GUI, HTTP, and logging have cw-native replacements.",
        },
        .tier_d_bean_deep => .{
            .kind = .not_implemented, .phase = .analysis,
            .template =
                "bean's deep reflection is not part of ClojureWasm. " ++
                "Reflecting JVM property names beyond what TypeDescriptor exposes is not supported. " ++
                "Use explicit :keys destructuring on records and hash-maps; basic field walk via TypeDescriptor stays available.",
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
///
/// Call-site idiom: `return error_catalog.raise(.code, loc, args);`.
/// `raise` returns the matching `Error` value directly; no `try` is
/// required at the raise site because the caller propagates it.
pub fn raise(comptime code: Code, location: SourceLocation, args: anytype) Error {
    const e = comptime entry(code);
    return error_mod.setErrorFmt(e.phase, e.kind, location, e.template, args);
}

// --- Tests ---

const testing = std.testing;

test "raise produces matching Kind / Phase and renders template" {
    const err = raise(.type_arg_not_number, .{ .file = "t.clj", .line = 1, .column = 0 }, .{
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

test "feature_not_supported uses .name slot, no Phase or ADR leak" {
    _ = raise(.feature_not_supported, .{}, .{ .name = "dosync" }) catch {};
    const info = error_mod.getLastError().?;
    try testing.expectEqualStrings("dosync is not supported in ClojureWasm", info.message);
    // The user-facing message must not contain development markers.
    try testing.expect(std.mem.find(u8, info.message, "Phase") == null);
    try testing.expect(std.mem.find(u8, info.message, "ADR-") == null);
    try testing.expect(std.mem.find(u8, info.message, "http") == null);
}

test "tier_d_gen_class template names the form + suggests cw alternative" {
    _ = raise(.tier_d_gen_class, .{}, .{}) catch {};
    const info = error_mod.getLastError().?;
    try testing.expect(std.mem.find(u8, info.message, "gen-class is not part of ClojureWasm") != null);
    try testing.expect(std.mem.find(u8, info.message, "deftype") != null);
    // User-facing message never names the tier or ADR.
    try testing.expect(std.mem.find(u8, info.message, "Tier") == null);
    try testing.expect(std.mem.find(u8, info.message, "ADR-") == null);
}

test "tier_d_proxy_deep template explains the deep-extension constraint" {
    _ = raise(.tier_d_proxy_deep, .{}, .{}) catch {};
    const info = error_mod.getLastError().?;
    try testing.expect(std.mem.find(u8, info.message, "proxy") != null);
    try testing.expect(std.mem.find(u8, info.message, "reify") != null);
    try testing.expect(std.mem.find(u8, info.message, "Tier") == null);
}

test "tier_d_bean_deep keeps basic TypeDescriptor field walk available in the wording" {
    _ = raise(.tier_d_bean_deep, .{}, .{}) catch {};
    const info = error_mod.getLastError().?;
    try testing.expect(std.mem.find(u8, info.message, "bean") != null);
    try testing.expect(std.mem.find(u8, info.message, "TypeDescriptor") != null);
}

test "arity templates render all three variants" {
    _ = raise(.arity_invalid, .{}, .{ .got = 3, .fn_name = "inc" }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (3) passed to inc",
        error_mod.getLastError().?.message,
    );

    _ = raise(.arity_below_min, .{}, .{ .got = 1, .fn_name = "+", .min = 2 }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (1) passed to +, expected at least 2",
        error_mod.getLastError().?.message,
    );

    _ = raise(.arity_out_of_range, .{}, .{ .got = 0, .fn_name = "subs", .min = 2, .max = 3 }) catch {};
    try testing.expectEqualStrings(
        "Wrong number of args (0) passed to subs, expected 2 to 3",
        error_mod.getLastError().?.message,
    );
}
