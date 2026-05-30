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
const error_mod = @import("info.zig");
const Value = @import("../value/value.zig").Value;

pub const Kind = error_mod.Kind;
pub const Phase = error_mod.Phase;
pub const SourceLocation = error_mod.SourceLocation;
pub const ClojureWasmError = error_mod.ClojureWasmError;

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
    def_name_namespace_qualified,
    if_arity_invalid,
    quote_arity_invalid,
    symbol_unresolved,
    /// args: `.{ .sym = "ns/name", .ns = "ns" }` — raised when a
    /// `^:private` var is referenced as a symbol from outside its
    /// owning namespace.
    private_access_error,
    /// args: `.{ .form = "let*"|"loop*" }`
    bindings_form_incomplete,
    /// args: `.{ .form = "let*"|"loop*" }`
    bindings_not_vector,
    /// args: `.{ .form = "let*"|"loop*" }`
    bindings_arity_odd,
    /// args: `.{ .form = "let*"|"loop*" }`
    binding_name_not_symbol,
    /// args: `.{ .form = "let*"|"loop*" }`
    binding_name_namespace_qualified,
    /// `(binding [v ...])` targeted a Var that is not `^:dynamic`.
    /// args: `.{ .var = "ns/name" }`
    binding_target_not_dynamic,
    /// loop* / recur arity exceeds the internal slot-index width.
    /// args: `.{ .form = "loop*"|"recur", .got = N, .max = 65535 }`
    arity_too_large,
    namespace_unknown,
    current_namespace_missing,
    /// `(in-ns ...)` arity. args: `.{ .got = N }`.
    in_ns_arity_invalid,
    /// `(in-ns ...)` arg shape. args: `.{ .actual = "..." }`.
    in_ns_arg_not_symbol,

    // --- Analysis (fn*) ---
    fn_star_form_incomplete,
    fn_star_params_not_vector,
    fn_star_param_not_symbol,
    fn_star_param_namespace_qualified,
    fn_star_rest_missing,
    fn_star_rest_not_symbol,
    /// `(fn name [params] body)` self-name. The `fn` macro forwards
    /// no-name forms to `fn*`, but a self-reference name needs an fn*
    /// self-name slot (a dual-backend extension, D-147). Transient.
    fn_named_not_supported,
    /// Two fixed-arity methods share the same required-arg count. JVM
    /// Clojure rule 2 per ADR-0041 / row 7.8 cycle 1. args:
    /// `.{ .arity = N }`.
    fn_star_arity_duplicate,
    /// More than one variadic `[& rest]` body. JVM rule 1 per ADR-0041
    /// / row 7.8 cycle 1.
    fn_star_variadic_duplicate,
    /// Fixed-arity method has more params than the variadic's required
    /// count — call-site dispatch would be ambiguous. JVM rule 3 per
    /// ADR-0041 / row 7.8 cycle 2. args: `.{ .fixed = N, .variadic = M }`.
    fn_star_fixed_exceeds_variadic,

    // --- Analysis (recur / throw / try / catch) ---
    recur_outside_target,
    recur_arity_mismatch,
    throw_arity_invalid,
    try_clause_after_finally,
    catch_form_incomplete,
    catch_head_invalid,
    macro_return_not_data,
    defmacro_name_not_symbol,
    defmacro_params_not_vector,
    defmacro_arity_invalid,
    macro_var_not_callable,
    promise_undelivered_error,
    future_thunk_failed,
    catch_class_unknown,
    class_name_unknown,
    catch_binding_not_symbol,
    catch_binding_namespace_qualified,

    // --- Eval (tree-walk runtime) ---
    /// args: `.{ .form = "Local"|"let*"|"loop*"|"catch", .index = N, .max = M }`
    slot_out_of_range,
    /// args: `.{ .got = N, .max = M }`
    recur_args_exceed_buffer,
    /// args: `.{ .got = N, .max = M }`
    call_args_exceed_max_locals,
    /// args: `.{ .base = N, .arity = M, .max = K }`
    fn_frame_exceeds_max_locals,

    // --- Reader macros / nesting / escapes (Phase 1 reader migration) ---
    form_nesting_too_deep,
    delimiter_unmatched_at_eof,
    quote_reader_macro_incomplete,
    symbolic_value_incomplete,
    symbolic_value_unknown,
    discard_reader_macro_incomplete,
    /// `#(... #(...) ...)` — nested anonymous-fn literals. JVM forbids
    /// this because `%` would be ambiguous across levels (D-146).
    fn_lit_nested,
    string_escape_trailing_backslash,
    unicode_escape_truncated,
    unicode_escape_invalid_hex,
    unicode_codepoint_invalid,
    string_escape_unknown,

    // --- Macroexpand ---
    let_form_incomplete,
    cond_clauses_arity_odd,
    when_form_incomplete,
    /// args: `.{ .op = "->"|"->>" }`
    thread_macro_arity_invalid,
    /// args: `.{ .actual = "..." }`
    thread_macro_step_invalid_type,
    thread_macro_step_empty_list,
    if_let_form_incomplete,
    if_let_bindings_invalid,
    if_let_binding_name_invalid,
    defn_form_incomplete,
    defn_name_invalid,
    defn_params_not_vector,
    defmulti_form_incomplete,
    defmulti_name_invalid,
    defmethod_form_incomplete,
    defmethod_params_not_vector,
    defprotocol_form_incomplete,
    defprotocol_name_invalid,
    defprotocol_method_invalid,
    defrecord_form_incomplete,
    defrecord_name_invalid,
    defrecord_fields_not_vector,
    defrecord_field_invalid,
    /// args: `.{ .name = "<field-name>" }`
    defrecord_assoc_undeclared_key,
    reify_form_incomplete,
    reify_section_invalid,
    reify_method_invalid,
    extend_type_form_incomplete,
    extend_type_method_invalid,
    extend_protocol_form_incomplete,
    extend_protocol_section_invalid,
    prefer_method_form_incomplete,
    when_let_form_incomplete,
    if_some_form_incomplete,
    if_some_bindings_invalid,
    if_some_binding_name_invalid,
    when_some_form_incomplete,
    doto_form_incomplete,
    dotimes_form_incomplete,
    dotimes_bindings_invalid,
    doseq_form_incomplete,
    doseq_bindings_invalid,
    for_form_incomplete,
    for_bindings_invalid,
    for_while_not_supported,
    format_spec_invalid,
    format_args_insufficient,
    while_form_incomplete,
    when_first_form_incomplete,
    when_first_bindings_invalid,
    case_form_incomplete,
    condp_form_incomplete,
    if_not_form_incomplete,
    when_not_form_incomplete,
    assert_form_incomplete,

    // --- Eval (type) ---
    type_arg_not_number,
    type_arg_not_integer,
    type_arg_not_boolean,
    type_arg_not_string,
    type_arg_not_ratio,
    /// args: `.{ .fn_name = "...", .expected = "...", .actual = "..." }`
    /// Generic type mismatch — used by Phase 6.16.a+ core glue
    /// primitives where the expected category is "seqable" /
    /// "counted" / "collection" rather than a single concrete type.
    type_arg_invalid,
    value_not_callable,

    // --- Eval (arithmetic) ---
    divide_by_zero,
    integer_overflow,

    // --- Eval (arity at call) ---
    arity_below_min,
    arity_out_of_range,
    arity_not_expected,
    /// Multi-arity `fn*` (ADR-0041 / row 7.8 cycle 1) reached call
    /// dispatch with no matching arity. args: `.{ .fn_name = "...",
    /// .got = N, .arities = "1, 2, or 3" }`.
    arity_not_expected_multi,

    // --- Unsupported / Tier ---
    /// Feature is on the cw roadmap but not yet implemented in this
    /// release. The user sees only the feature name; the development
    /// calendar (Phase numbers, ADR identifiers) stays internal.
    ///
    /// args: `.{ .name = "<feature>" }`
    feature_not_supported,
    /// args: `.{ .sym = "ns/name" }` — raised when an analyzer
    /// reaches a callable position whose target Var carries
    /// `^:unsupported` metadata (declare-only placeholder).
    feature_not_supported_unsupported_var,

    // --- Require / namespace loading (ADR-0035 D5/D8) ---
    /// args: `.{ .chain = "a -> b -> a" }` — raised when
    /// `requireOne` is called for a namespace already present in
    /// `Runtime.require_in_progress`. The chain string shows the
    /// load stack so the user can locate the cycle.
    circular_require,
    /// args: `.{ .ns = "..." }` — raised when the active
    /// `Runtime.require_resolver` returns `null` for a requested
    /// namespace name.
    lib_not_found,

    // --- Protocol dispatch (ADR-0008 amendment 1, Phase 7.1) ---
    /// args: `.{ .protocol = "ISeq", .method = "first",
    ///          .type_name = "user.Foo" | "<tag>" }` — raised when
    /// `dispatch` finds no `MethodEntry` for `(protocol, method)`
    /// on the receiver's `TypeDescriptor` chain.
    protocol_no_satisfies,

    // --- Multimethod dispatch (ADR-0008 amendment 2, Phase 7.2) ---
    /// args: `.{ .name = "clojure.core/print-method" }` — raised
    /// when `getMethod` finds no exact match and no `:default`
    /// method on the multimethod's method table. Mirrors JVM
    /// Clojure's `IllegalArgumentException("No method in
    /// multimethod ...")`.
    multimethod_no_method,
    /// args: `.{ .name = "user/area" }` — raised when the
    /// hierarchy walk finds more than one matching method on
    /// the multimethod's method table and `prefer-method` does
    /// not resolve the conflict. Mirrors JVM Clojure's
    /// `IllegalArgumentException("Multiple methods in
    /// multimethod ... match dispatch value ... and neither is
    /// preferred")`. cycle 3 of row 7.2 widens the template to
    /// name the conflicting keys; cycle 2 only carries the name.
    multimethod_ambiguous_dispatch,

    // --- Transient surface (Phase 8 row 8.5, D-074) ---
    /// args: `.{ .fn_name = "conj!" | "persistent!" | "pop!" | "assoc!" }`
    /// — raised when a mutating call (or `persistent!`) reaches a
    /// transient whose `consumed` flag is already set. Matches the
    /// JVM Clojure `IllegalAccessError("Transient used after
    /// persistent! call")` semantics.
    transient_used_after_persistent,
    /// args: `.{ .fn_name = "...", .expected = "transient_vector" | ...,
    /// .actual = "<tag-name>" }` — raised when a transient primitive
    /// is called with an argument whose tag does not match the
    /// transient kind (e.g. `(conj! a-vec :x)` where `a-vec` is
    /// not a transient at all, or where the transient kind does not
    /// accept the operation).
    transient_kind_mismatch,

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
        .def_name_namespace_qualified => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "def name must not be namespace-qualified: '{[ns]s}/{[name]s}'",
        },
        .if_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "if expects 2 or 3 args, got {[got]d}",
        },
        .quote_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "quote expects 1 arg, got {[got]d}",
        },
        .symbol_unresolved => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Unable to resolve symbol: '{[sym]s}'",
        },
        .private_access_error => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Var '{[sym]s}' is private to namespace '{[ns]s}'",
        },
        .circular_require => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Cyclic load dependency: {[chain]s}",
        },
        .lib_not_found => .{
            .kind = .name_error, .phase = .analysis,
            .template = "Could not locate '{[ns]s}' on the require resolver",
        },
        .protocol_no_satisfies => .{
            .kind = .type_error, .phase = .eval,
            .template = "No implementation of method '{[method]s}' on protocol '{[protocol]s}' for type '{[type_name]s}'",
        },
        .multimethod_no_method => .{
            .kind = .value_error, .phase = .eval,
            .template = "No method in multimethod '{[name]s}' for dispatch value",
        },
        .multimethod_ambiguous_dispatch => .{
            .kind = .value_error, .phase = .eval,
            .template = "Multiple methods in multimethod '{[name]s}' match dispatch value and neither is preferred",
        },
        .bindings_form_incomplete => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "{[form]s} requires a binding vector and a body",
        },
        .bindings_not_vector => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "{[form]s} bindings must be a vector",
        },
        .bindings_arity_odd => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "{[form]s} bindings must have an even number of forms",
        },
        .binding_name_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "{[form]s} binding name must be a symbol",
        },
        .binding_name_namespace_qualified => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "{[form]s} binding name must not be namespace-qualified",
        },
        .binding_target_not_dynamic => .{
            .kind = .value_error, .phase = .eval,
            .template = "Can't dynamically bind non-dynamic var: {[var]s}",
        },
        .arity_too_large => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "{[form]s} arity {[got]d} exceeds the limit of 65535",
        },
        .namespace_unknown => .{
            .kind = .name_error, .phase = .analysis,
            .template = "No namespace: '{[ns]s}'",
        },
        .current_namespace_missing => .{
            .kind = .name_error, .phase = .analysis,
            .template = "No current namespace; cannot resolve '{[sym]s}'",
        },
        .in_ns_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "in-ns expects 1 arg, got {[got]d}",
        },
        .in_ns_arg_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "in-ns arg must be a symbol or (quote sym), got {[actual]s}",
        },

        // --- Analysis (fn*) ---
        .fn_star_form_incomplete => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* requires a parameter vector and a body",
        },
        .fn_star_params_not_vector => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* parameter list must be a vector",
        },
        .fn_star_param_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* parameter must be a symbol",
        },
        .fn_star_param_namespace_qualified => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* parameter must not be namespace-qualified",
        },
        .fn_star_rest_missing => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* '&' must be followed by a rest-parameter symbol",
        },
        .fn_star_rest_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn* rest-parameter must be a symbol",
        },
        .fn_named_not_supported => .{
            .kind = .not_implemented, .phase = .macroexpand,
            .template = "fn with a name (self-reference) is not yet supported; use defn for a named function",
        },
        .fn_star_arity_duplicate => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn*: can't have two overloads with same arity ({[arity]d})",
        },
        .fn_star_variadic_duplicate => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn*: can't have more than 1 variadic overload",
        },
        .fn_star_fixed_exceeds_variadic => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "fn*: can't have fixed arity ({[fixed]d}) with more params than variadic ({[variadic]d})",
        },

        // --- Analysis (recur / throw / try / catch) ---
        .recur_outside_target => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "recur is only valid inside a loop* or fn*",
        },
        .recur_arity_mismatch => .{
            .kind = .arity_error, .phase = .analysis,
            .template = "recur of {[target]s}: expected {[expected]d} arg(s), got {[got]d}",
        },
        .throw_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "throw expects 1 arg, got {[got]d}",
        },
        .try_clause_after_finally => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "try: clauses must not appear after `finally`",
        },
        .catch_form_incomplete => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "catch requires (catch <Class> <binding> <body>...)",
        },
        .catch_head_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "catch head must be a symbol (class name) or a keyword (ex-info :type)",
        },
        .macro_return_not_data => .{
            .kind = .type_error, .phase = .macroexpand,
            .template = "macro return value of tag '{[tag]s}' cannot be re-analysed as a form",
        },
        .defmacro_name_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "defmacro: first argument must be a symbol",
        },
        .defmacro_params_not_vector => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "defmacro: parameter list must be a vector",
        },
        .defmacro_arity_invalid => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "defmacro requires (defmacro <name> [<params>...] <body>...)",
        },
        .macro_var_not_callable => .{
            .kind = .type_error, .phase = .macroexpand,
            .template = "macro Var '{[name]s}' root binding is not callable",
        },
        .promise_undelivered_error => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "deref of an undelivered promise would block forever on the single-thread runtime (Phase 15.1 lands the blocking variant)",
        },
        .future_thunk_failed => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "deref of a future whose body raised — the original error is not yet re-raised at deref time (Phase 15.1 / D-115)",
        },
        .catch_class_unknown => .{
            .kind = .name_error, .phase = .analysis,
            .template = "catch class '{[name]s}' is not a known exception type",
        },
        .class_name_unknown => .{
            .kind = .name_error, .phase = .eval,
            .template = "class '{[name]s}' is not a known class name",
        },
        .catch_binding_not_symbol => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "catch binding must be a symbol",
        },
        .catch_binding_namespace_qualified => .{
            .kind = .syntax_error, .phase = .analysis,
            .template = "catch binding must not be namespace-qualified",
        },

        // --- Eval (tree-walk runtime) ---
        .slot_out_of_range => .{
            .kind = .index_error, .phase = .eval,
            .template = "{[form]s} slot {[index]d} out of range (max {[max]d})",
        },
        .recur_args_exceed_buffer => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "recur with {[got]d} args exceeds buffer ({[max]d})",
        },
        .call_args_exceed_max_locals => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "Call with {[got]d} args exceeds the limit of {[max]d}",
        },
        .fn_frame_exceeds_max_locals => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "fn frame ({[base]d}+{[arity]d}) exceeds the limit of {[max]d}",
        },

        // --- Reader macros / nesting / escapes ---
        .form_nesting_too_deep => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Form nesting exceeds max depth ({[max]d})",
        },
        .delimiter_unmatched_at_eof => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unmatched delimiter; reached EOF before '{[delim]s}'",
        },
        .quote_reader_macro_incomplete => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Quote ' has no following form",
        },
        .symbolic_value_incomplete => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Symbolic value '##' has no following name",
        },
        .symbolic_value_unknown => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Unknown symbolic value '##{[name]s}'",
        },
        .discard_reader_macro_incomplete => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Discard '#_' has no following form",
        },
        .fn_lit_nested => .{
            .kind = .syntax_error, .phase = .parse,
            .template = "Nested #() anonymous functions are not allowed",
        },
        .string_escape_trailing_backslash => .{
            .kind = .string_error, .phase = .parse,
            .template = "Trailing '\\' in string literal",
        },
        .unicode_escape_truncated => .{
            .kind = .string_error, .phase = .parse,
            .template = "Truncated \\u escape sequence",
        },
        .unicode_escape_invalid_hex => .{
            .kind = .string_error, .phase = .parse,
            .template = "Invalid hex in \\u escape: '{[hex]s}'",
        },
        .unicode_codepoint_invalid => .{
            .kind = .string_error, .phase = .parse,
            .template = "Codepoint U+{[hex]s} is not a valid Unicode scalar",
        },
        .string_escape_unknown => .{
            .kind = .string_error, .phase = .parse,
            .template = "Unknown escape sequence '\\{[escape]c}'",
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
        .when_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when requires a test and at least one body form",
        },
        .thread_macro_arity_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "{[op]s} requires at least one argument",
        },
        .thread_macro_step_invalid_type => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "thread macro step must be a list or symbol, got {[actual]s}",
        },
        .thread_macro_step_empty_list => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "thread macro step must not be an empty list",
        },
        .if_let_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-let requires [name expr] and a then form (else optional)",
        },
        .if_let_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-let bindings must be a vector of [name expr]",
        },
        .if_let_binding_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-let binding name must be an unqualified symbol",
        },
        .if_some_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-some requires [name expr] and a then form (else optional)",
        },
        .if_some_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-some bindings must be a vector of [name expr]",
        },
        .if_some_binding_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-some binding name must be an unqualified symbol",
        },
        .when_some_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when-some requires [name expr] and at least one body form",
        },
        .doto_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "doto requires an expression to thread through the forms",
        },
        .dotimes_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "dotimes requires a [name count] binding form",
        },
        .dotimes_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "dotimes bindings must be a vector of [name count] with an unqualified symbol name",
        },
        .doseq_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "doseq requires a binding vector",
        },
        .doseq_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "doseq bindings must be an even-length vector of binding pairs with optional :let / :when / :while modifiers",
        },
        .for_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "for requires a binding vector and a body expression",
        },
        .for_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "for bindings must be an even-length vector of binding pairs with optional :let / :when modifiers",
        },
        .for_while_not_supported => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "for with :while is not yet supported; use :when, or wrap with take-while",
        },
        .format_spec_invalid => .{
            .kind = .type_error, .phase = .eval,
            .template = "format: unsupported directive '{[spec]s}' (supported: %s %d %f %.Nf %x %% %n; no width/flags yet)",
        },
        .format_args_insufficient => .{
            .kind = .type_error, .phase = .eval,
            .template = "format: not enough arguments for the format string",
        },
        .while_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "while requires a test expression",
        },
        .when_first_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when-first requires [name coll] and at least one body form",
        },
        .when_first_bindings_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when-first bindings must be a vector of [name coll] with an unqualified symbol name",
        },
        .case_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "case requires a test expression and at least one clause or default",
        },
        .condp_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "condp requires a predicate and an expression",
        },
        .if_not_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "if-not requires a test and a then form (else optional)",
        },
        .when_not_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when-not requires a test and at least one body form",
        },
        .assert_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "assert requires an expression (message optional)",
        },
        .defn_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defn requires a name, parameter vector, and at least one body form",
        },
        .defn_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defn name must be an unqualified symbol",
        },
        .defn_params_not_vector => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defn parameter list must be a vector",
        },
        .defmulti_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defmulti requires a name and a dispatch function",
        },
        .defmulti_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defmulti name must be an unqualified symbol",
        },
        .defmethod_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defmethod requires multifn, dispatch-val, params vector, and body",
        },
        .defmethod_params_not_vector => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defmethod parameter list must be a vector",
        },
        .prefer_method_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "prefer-method requires multifn, x, y",
        },
        .defprotocol_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defprotocol requires a name and at least one method signature",
        },
        .defprotocol_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defprotocol name must be an unqualified symbol",
        },
        .defprotocol_method_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defprotocol method signature must be a list `(method-name [params...])`",
        },
        .defrecord_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defrecord requires a name and a field vector",
        },
        .defrecord_name_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defrecord name must be an unqualified symbol",
        },
        .defrecord_fields_not_vector => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defrecord fields must be a vector",
        },
        .defrecord_field_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "defrecord field must be an unqualified symbol",
        },
        .defrecord_assoc_undeclared_key => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "assoc on defrecord with non-declared key '{[name]s}' is not yet supported",
        },
        .reify_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "reify requires at least one protocol symbol and one method implementation",
        },
        .reify_section_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "reify section must lead with a protocol symbol followed by one or more method-impl lists",
        },
        .reify_method_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "reify method implementation must be a list `(method-name [params...] body)`",
        },
        .extend_type_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "extend-type requires a target, a protocol, and at least one method implementation",
        },
        .extend_type_method_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "extend-type method implementation must be a list `(method-name [params...] body...)`",
        },
        .extend_protocol_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "extend-protocol requires a protocol and at least one (type method...) section",
        },
        .extend_protocol_section_invalid => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "extend-protocol section must lead with a type symbol followed by one or more method-impl lists",
        },
        .when_let_form_incomplete => .{
            .kind = .syntax_error, .phase = .macroexpand,
            .template = "when-let requires [name expr] and at least one body form",
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
        .type_arg_not_string => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected string, got {[actual]s}",
        },
        .type_arg_not_ratio => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected ratio, got {[actual]s}",
        },
        .type_arg_invalid => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected {[expected]s}, got {[actual]s}",
        },
        .value_not_callable => .{
            .kind = .type_error, .phase = .eval,
            .template = "Cannot call value of type '{[actual]s}'",
        },

        // --- Eval (arithmetic) ---
        .divide_by_zero => .{
            .kind = .arithmetic_error, .phase = .eval,
            .template = "Divide by zero",
        },
        .integer_overflow => .{
            .kind = .arithmetic_error, .phase = .eval,
            .template = "integer overflow",
        },

        // --- Eval (arity) ---
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
        .arity_not_expected_multi => .{
            .kind = .arity_error, .phase = .eval,
            .template = "Wrong number of args ({[got]d}) passed to {[fn_name]s}, expected one of: {[arities]s}",
        },

        // --- Unsupported / Tier ---
        .feature_not_supported => .{
            .kind = .not_implemented, .phase = .eval,
            .template = "{[name]s} is not supported in ClojureWasm",
        },
        .feature_not_supported_unsupported_var => .{
            .kind = .not_implemented, .phase = .analysis,
            .template = "'{[sym]s}' is declared but not yet supported in ClojureWasm",
        },
        .transient_used_after_persistent => .{
            .kind = .value_error, .phase = .eval,
            .template = "{[fn_name]s}: Transient used after persistent! call",
        },
        .transient_kind_mismatch => .{
            .kind = .type_error, .phase = .eval,
            .template = "{[fn_name]s}: expected {[expected]s}, got {[actual]s}",
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
/// `raise` returns the matching `ClojureWasmError` value directly; no
/// `try` is required at the raise site because the caller propagates it.
pub fn raise(comptime code: Code, location: SourceLocation, args: anytype) ClojureWasmError {
    const e = comptime entry(code);
    return error_mod.setErrorFmt(e.phase, e.kind, location, e.template, args);
}

// --- Type assertion helpers ---

/// Assert `val` is a number; widen to f64. Raises
/// `type_arg_not_number` on mismatch.
pub fn expectNumber(val: Value, name: []const u8, loc: SourceLocation) ClojureWasmError!f64 {
    return switch (val.tag()) {
        .integer => @floatFromInt(val.asInteger()),
        .float => val.asFloat(),
        else => raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(val.tag()) }),
    };
}

/// Assert `val` is an integer. Raises `type_arg_not_integer` on
/// mismatch.
pub fn expectInteger(val: Value, name: []const u8, loc: SourceLocation) ClojureWasmError!i48 {
    if (val.tag() == .integer) return val.asInteger();
    return raise(.type_arg_not_integer, loc, .{ .fn_name = name, .actual = @tagName(val.tag()) });
}

/// Assert `val` is a boolean. Raises `type_arg_not_boolean` on
/// mismatch.
pub fn expectBoolean(val: Value, name: []const u8, loc: SourceLocation) ClojureWasmError!bool {
    if (val.tag() == .boolean) return val.asBoolean();
    return raise(.type_arg_not_boolean, loc, .{ .fn_name = name, .actual = @tagName(val.tag()) });
}

// --- Arity check helpers ---

/// Exact arity check. Raises `arity_not_expected` (the wider template
/// that names the expected count) on mismatch.
pub fn checkArity(name: []const u8, args: []const Value, expected: usize, loc: SourceLocation) ClojureWasmError!void {
    if (args.len != expected) {
        return raise(.arity_not_expected, loc, .{ .fn_name = name, .got = args.len, .expected = expected });
    }
}

/// Minimum-arity check (variadic primitives). Raises `arity_below_min`
/// when under.
pub fn checkArityMin(name: []const u8, args: []const Value, min: usize, loc: SourceLocation) ClojureWasmError!void {
    if (args.len < min) {
        return raise(.arity_below_min, loc, .{ .got = args.len, .fn_name = name, .min = min });
    }
}

/// Inclusive arity-range check. Raises `arity_out_of_range` when
/// outside `[min, max]`.
pub fn checkArityRange(name: []const u8, args: []const Value, min: usize, max: usize, loc: SourceLocation) ClojureWasmError!void {
    if (args.len < min or args.len > max) {
        return raise(.arity_out_of_range, loc, .{ .got = args.len, .fn_name = name, .min = min, .max = max });
    }
}

/// Raise an `internal_error` with the given `detail`. Convenience
/// wrapper that collapses the `raise(.internal_error, loc, .{ .detail
/// = ... })` shape into a single call. Pass `.{}` for unknown
/// locations (VM bytecode-level errors); pass the form's source
/// location for AST-level invariant violations (analyzer / tree_walk).
///
/// Lifted from `eval/backend/vm.zig::raiseInternal` per D-041 (c) so
/// every backend / pass reaches the helper through one canonical site.
pub fn raiseInternal(loc: SourceLocation, detail: []const u8) ClojureWasmError {
    return raise(.internal_error, loc, .{ .detail = detail });
}

// --- Tests ---

const testing = std.testing;

test "raise produces matching Kind / Phase and renders template" {
    const err = raise(.type_arg_not_number, .{ .file = "t.clj", .line = 1, .column = 0 }, .{
        .fn_name = "+",
        .actual = "keyword",
    });
    try testing.expectEqual(ClojureWasmError.TypeError, err);

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

test "arity templates render all variants" {
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

// --- Helper tests (moved from error.zig in 4.26.d region 6) ---

test "checkArity exact pass" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArity("+", &args, 2, .{});
}

test "checkArity exact fail" {
    error_mod.clearLastError();
    const args = [_]Value{Value.initInteger(1)};
    try testing.expectError(ClojureWasmError.ArityError, checkArity("+", &args, 2, .{}));
    const info = error_mod.getLastError().?;
    try testing.expectEqualStrings("Wrong number of args (1) passed to +, expected 2", info.message);
}

test "checkArityMin pass and fail" {
    const args2 = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityMin("str", &args2, 1, .{});

    const args0 = [_]Value{};
    try testing.expectError(ClojureWasmError.ArityError, checkArityMin("str", &args0, 1, .{}));
}

test "checkArityRange pass and fail (low/high)" {
    const args2 = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityRange("subs", &args2, 2, 3, .{});

    const args1 = [_]Value{Value.initInteger(1)};
    try testing.expectError(ClojureWasmError.ArityError, checkArityRange("subs", &args1, 2, 3, .{}));

    const args4 = [_]Value{ .nil_val, .nil_val, .nil_val, .nil_val };
    try testing.expectError(ClojureWasmError.ArityError, checkArityRange("subs", &args4, 2, 3, .{}));
}

test "expectNumber accepts int and float, rejects nil" {
    error_mod.clearLastError();
    try testing.expectEqual(@as(f64, 42.0), try expectNumber(Value.initInteger(42), "f", .{}));
    try testing.expectApproxEqRel(@as(f64, 3.14), try expectNumber(Value.initFloat(3.14), "f", .{}), 1e-10);

    try testing.expectError(ClojureWasmError.TypeError, expectNumber(.nil_val, "f", .{}));
    const info = error_mod.getLastError().?;
    try testing.expectEqualStrings("f: expected number, got nil", info.message);
}

test "expectInteger pass; float fails" {
    try testing.expectEqual(@as(i48, -7), try expectInteger(Value.initInteger(-7), "nth", .{}));
    try testing.expectError(ClojureWasmError.TypeError, expectInteger(Value.initFloat(1.5), "nth", .{}));
}

test "expectBoolean pass; nil fails" {
    try testing.expect(try expectBoolean(.true_val, "t", .{}));
    try testing.expectError(ClojureWasmError.TypeError, expectBoolean(.nil_val, "t", .{}));
}
