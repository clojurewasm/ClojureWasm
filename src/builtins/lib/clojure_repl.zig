// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.repl — REPL utility functions.
//! Replaces clojure/repl.clj (functions only; macros handled via evalString).
//! Builtins registered eagerly; macros (doc, dir, source) loaded via evalString in bootstrap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const es = @import("../../runtime/embedded_sources.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn callNs(allocator: Allocator, ns_name: []const u8, fn_name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const ns = env.findNamespace(ns_name) orelse return error.EvalError;
    const v = ns.mappings.get(fn_name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn kw(allocator: Allocator, name: []const u8) Value {
    return Value.initKeyword(allocator, .{ .ns = null, .name = name });
}

fn str(allocator: Allocator, s: []const u8) Value {
    return Value.initString(allocator, @constCast(s));
}

/// (special-doc name-symbol) — private
fn specialDocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    const name_sym = args[0];
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const repl_ns = env.findNamespace("clojure.repl") orelse return error.EvalError;
    const sdm_var = repl_ns.mappings.get("special-doc-map") orelse return error.EvalError;
    const sdm = sdm_var.deref();

    const doc_entry = try callCore(allocator, "get", &.{ sdm, name_sym });
    const base = if (doc_entry.isTruthy()) doc_entry else blk: {
        const resolved = try callCore(allocator, "resolve", &.{name_sym});
        break :blk if (resolved.isTruthy()) try callCore(allocator, "meta", &.{resolved}) else Value.nil_val;
    };
    const result = try callCore(allocator, "assoc", &.{ base, kw(allocator, "name"), name_sym, kw(allocator, "special-form"), Value.true_val });
    return result;
}

/// (namespace-doc nspace) — private
fn namespaceDocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    const nspace = args[0];
    const m = try callCore(allocator, "meta", &.{nspace});
    const ns_name_val = try callCore(allocator, "ns-name", &.{nspace});
    return callCore(allocator, "assoc", &.{ m, kw(allocator, "name"), ns_name_val });
}

/// (print-doc m) — private
fn printDocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    const m = args[0];

    _ = try callCore(allocator, "println", &.{str(allocator, "-------------------------")});

    // Print name
    const spec_val = try callCore(allocator, "get", &.{ m, kw(allocator, "spec") });
    const n = try callCore(allocator, "get", &.{ m, kw(allocator, "ns") });
    const nm = try callCore(allocator, "get", &.{ m, kw(allocator, "name") });
    if (spec_val.isTruthy()) {
        _ = try callCore(allocator, "println", &.{spec_val});
    } else {
        if (n.isTruthy()) {
            const ns_name_val = try callCore(allocator, "ns-name", &.{n});
            const full_name = try callCore(allocator, "str", &.{ ns_name_val, str(allocator, "/"), nm });
            _ = try callCore(allocator, "println", &.{full_name});
        } else {
            _ = try callCore(allocator, "println", &.{nm});
        }
    }

    // Print forms
    const forms = try callCore(allocator, "get", &.{ m, kw(allocator, "forms") });
    if (forms.isTruthy()) {
        var form_seq = try callCore(allocator, "seq", &.{forms});
        while (form_seq.isTruthy()) {
            const f = try callCore(allocator, "first", &.{form_seq});
            _ = try callCore(allocator, "print", &.{str(allocator, "  ")});
            _ = try callCore(allocator, "prn", &.{f});
            form_seq = try callCore(allocator, "next", &.{form_seq});
        }
    }

    // Print arglists
    const arglists = try callCore(allocator, "get", &.{ m, kw(allocator, "arglists") });
    if (arglists.isTruthy()) {
        _ = try callCore(allocator, "println", &.{arglists});
    }

    // Print type
    const special_form = try callCore(allocator, "get", &.{ m, kw(allocator, "special-form") });
    const macro_val = try callCore(allocator, "get", &.{ m, kw(allocator, "macro") });
    if (special_form.isTruthy()) {
        _ = try callCore(allocator, "println", &.{str(allocator, "Special Form")});
    } else if (macro_val.isTruthy()) {
        _ = try callCore(allocator, "println", &.{str(allocator, "Macro")});
    } else if (spec_val.isTruthy()) {
        _ = try callCore(allocator, "println", &.{str(allocator, "Spec")});
    }

    // Print doc
    const doc_val = try callCore(allocator, "get", &.{ m, kw(allocator, "doc") });
    if (doc_val.isTruthy()) {
        _ = try callCore(allocator, "println", &.{ str(allocator, " "), doc_val });
    }

    // Print special form URL
    if (special_form.isTruthy()) {
        const has_url = try callCore(allocator, "contains?", &.{ m, kw(allocator, "url") });
        if (has_url.isTruthy()) {
            const url = try callCore(allocator, "get", &.{ m, kw(allocator, "url") });
            if (url.isTruthy()) {
                const url_str = try callCore(allocator, "str", &.{ str(allocator, "\n  Please see http://clojure.org/"), url });
                _ = try callCore(allocator, "println", &.{url_str});
            }
        } else {
            const url_str = try callCore(allocator, "str", &.{ str(allocator, "\n  Please see http://clojure.org/special_forms#"), nm });
            _ = try callCore(allocator, "println", &.{url_str});
        }
    }

    // Print spec (if ns is present)
    if (n.isTruthy()) {
        const ns_name_val = try callCore(allocator, "ns-name", &.{n});
        const name_val = try callCore(allocator, "name", &.{nm});
        const sym = try callCore(allocator, "symbol", &.{ try callCore(allocator, "str", &.{ns_name_val}), name_val });
        // Try to get spec — may fail if spec not loaded
        const spec_result = callNs(allocator, "clojure.spec.alpha", "get-spec", &.{sym}) catch Value.nil_val;
        if (spec_result.isTruthy()) {
            _ = try callCore(allocator, "println", &.{str(allocator, "Spec")});
            const roles = [_][]const u8{ "args", "ret", "fn" };
            for (roles) |role| {
                const role_kw = kw(allocator, role);
                const role_spec = try callCore(allocator, "get", &.{ spec_result, role_kw });
                if (role_spec.isTruthy()) {
                    const desc = callNs(allocator, "clojure.spec.alpha", "describe", &.{role_spec}) catch str(allocator, "?");
                    _ = try callCore(allocator, "println", &.{ str(allocator, " "), try callCore(allocator, "str", &.{ str(allocator, role), str(allocator, ":") }), desc });
                }
            }
        }
    }

    return Value.nil_val;
}

/// (dir-fn ns)
/// (sort (map first (ns-publics (the-ns (get (ns-aliases *ns*) ns ns)))))
fn dirFnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to dir-fn", .{args.len});
    const ns_arg = args[0];
    // Get *ns* via the var
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const ns_var = core_ns.resolve("*ns*") orelse return error.EvalError;
    const current_ns_val = ns_var.deref();
    // (get (ns-aliases *ns*) ns ns)
    const aliases = try callCore(allocator, "ns-aliases", &.{current_ns_val});
    const resolved_ns = try callCore(allocator, "get", &.{ aliases, ns_arg, ns_arg });
    // (the-ns resolved_ns)
    const the_ns = try callCore(allocator, "the-ns", &.{resolved_ns});
    // (ns-publics the_ns)
    const publics = try callCore(allocator, "ns-publics", &.{the_ns});
    // (sort (map first publics)) — keys gives us the symbol names
    const keys_val = try callCore(allocator, "keys", &.{publics});
    return callCore(allocator, "sort", &.{keys_val});
}

/// (apropos str-or-pattern)
fn aproposFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to apropos", .{args.len});
    const pattern = args[0];

    // Build matches? function based on type
    const pat_type = try callCore(allocator, "type", &.{pattern});
    const is_regex = try callCore(allocator, "=", &.{ pat_type, kw(allocator, "regex") });

    const all_nses = try callCore(allocator, "all-ns", &.{});
    var results = std.ArrayList(Value).empty;

    var ns_seq = try callCore(allocator, "seq", &.{all_nses});
    while (ns_seq.isTruthy()) {
        const ns = try callCore(allocator, "first", &.{ns_seq});
        const ns_name_val = try callCore(allocator, "str", &.{ns});
        const publics = try callCore(allocator, "ns-publics", &.{ns});
        const pub_keys = try callCore(allocator, "keys", &.{publics});

        var key_seq = try callCore(allocator, "seq", &.{pub_keys});
        while (key_seq.isTruthy()) {
            const k = try callCore(allocator, "first", &.{key_seq});
            const k_str = try callCore(allocator, "str", &.{k});

            const matches = if (is_regex.isTruthy())
                try callCore(allocator, "re-find", &.{ pattern, k_str })
            else blk: {
                const pat_str = try callCore(allocator, "str", &.{pattern});
                break :blk try callNs(allocator, "clojure.string", "includes?", &.{ k_str, pat_str });
            };

            if (matches.isTruthy()) {
                const sym = try callCore(allocator, "symbol", &.{ ns_name_val, try callCore(allocator, "str", &.{k}) });
                results.append(allocator, sym) catch return error.EvalError;
            }

            key_seq = try callCore(allocator, "next", &.{key_seq});
        }
        ns_seq = try callCore(allocator, "next", &.{ns_seq});
    }

    // Build list and sort
    if (results.items.len == 0) return try callCore(allocator, "list", &.{});
    var result_list = Value.nil_val;
    var i = results.items.len;
    while (i > 0) {
        i -= 1;
        result_list = try callCore(allocator, "cons", &.{ results.items[i], result_list });
    }
    return callCore(allocator, "sort", &.{result_list});
}

/// (find-doc re-string-or-pattern)
fn findDocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-doc", .{args.len});
    const re = try callCore(allocator, "re-pattern", &.{args[0]});

    // Iterate all namespaces
    const all_nses = try callCore(allocator, "all-ns", &.{});
    var ns_seq = try callCore(allocator, "seq", &.{all_nses});
    while (ns_seq.isTruthy()) {
        const ns = try callCore(allocator, "first", &.{ns_seq});

        // Check all interns in this namespace
        const interns = try callCore(allocator, "ns-interns", &.{ns});
        const intern_vals = try callCore(allocator, "vals", &.{interns});
        var val_seq = try callCore(allocator, "seq", &.{intern_vals});
        while (val_seq.isTruthy()) {
            const v = try callCore(allocator, "first", &.{val_seq});
            const m = try callCore(allocator, "meta", &.{v});
            if (m.isTruthy()) {
                const doc_val = try callCore(allocator, "get", &.{ m, kw(allocator, "doc") });
                const name_val = try callCore(allocator, "get", &.{ m, kw(allocator, "name") });
                if (doc_val.isTruthy()) {
                    const doc_match = try callCore(allocator, "re-find", &.{ re, doc_val });
                    const name_match = if (name_val.isTruthy()) try callCore(allocator, "re-find", &.{ re, try callCore(allocator, "str", &.{name_val}) }) else Value.nil_val;
                    if (doc_match.isTruthy() or name_match.isTruthy()) {
                        _ = try printDocFn(allocator, &.{m});
                    }
                }
            }
            val_seq = try callCore(allocator, "next", &.{val_seq});
        }

        // Check namespace doc
        const ns_doc_map = try namespaceDocFn(allocator, &.{ns});
        const ns_doc = try callCore(allocator, "get", &.{ ns_doc_map, kw(allocator, "doc") });
        if (ns_doc.isTruthy()) {
            const ns_doc_match = try callCore(allocator, "re-find", &.{ re, ns_doc });
            const ns_name_match = try callCore(allocator, "re-find", &.{ re, try callCore(allocator, "str", &.{try callCore(allocator, "get", &.{ ns_doc_map, kw(allocator, "name") })}) });
            if (ns_doc_match.isTruthy() or ns_name_match.isTruthy()) {
                _ = try printDocFn(allocator, &.{ns_doc_map});
            }
        }

        ns_seq = try callCore(allocator, "next", &.{ns_seq});
    }

    // Check special-doc-map entries
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const repl_ns = env.findNamespace("clojure.repl") orelse return error.EvalError;
    if (repl_ns.mappings.get("special-doc-map")) |sdm_var| {
        const sdm = sdm_var.deref();
        const sdm_keys = try callCore(allocator, "keys", &.{sdm});
        var key_seq = try callCore(allocator, "seq", &.{sdm_keys});
        while (key_seq.isTruthy()) {
            const k = try callCore(allocator, "first", &.{key_seq});
            const sd = try specialDocFn(allocator, &.{k});
            const sd_doc = try callCore(allocator, "get", &.{ sd, kw(allocator, "doc") });
            if (sd_doc.isTruthy()) {
                const sd_doc_match = try callCore(allocator, "re-find", &.{ re, sd_doc });
                const sd_name_match = try callCore(allocator, "re-find", &.{ re, try callCore(allocator, "str", &.{k}) });
                if (sd_doc_match.isTruthy() or sd_name_match.isTruthy()) {
                    _ = try printDocFn(allocator, &.{sd});
                }
            }
            key_seq = try callCore(allocator, "next", &.{key_seq});
        }
    }

    return Value.nil_val;
}

/// (source-fn x)
fn sourceFnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to source-fn", .{args.len});
    const x = args[0];
    const v = try callCore(allocator, "resolve", &.{x});
    if (!v.isTruthy()) return Value.nil_val;

    const m = try callCore(allocator, "meta", &.{v});
    const filepath = try callCore(allocator, "get", &.{ m, kw(allocator, "file") });
    if (!filepath.isTruthy()) return Value.nil_val;

    const no_source = str(allocator, "NO_SOURCE_FILE");
    const eq = try callCore(allocator, "=", &.{ filepath, no_source });
    if (eq.isTruthy()) return Value.nil_val;

    const line_val = try callCore(allocator, "get", &.{ m, kw(allocator, "line") });
    const line_or_zero = if (line_val.isTruthy()) line_val else Value.initInteger(0);
    const is_pos = try callCore(allocator, "pos?", &.{line_or_zero});
    if (!is_pos.isTruthy()) return Value.nil_val;

    // Read file content
    const content = try callCore(allocator, "slurp", &.{filepath});
    const lines = try callNs(allocator, "clojure.string", "split", &.{ content, try callCore(allocator, "re-pattern", &.{str(allocator, "\n")}) });
    const start = line_val.asInteger() - 1;
    const line_count = try callCore(allocator, "count", &.{lines});
    if (start >= line_count.asInteger()) return Value.nil_val;

    // Read from start line, find matching parens
    var i: i64 = start;
    var depth: i64 = 0;
    var seen_open = false;
    var result = std.ArrayList(Value).empty;
    const total = line_count.asInteger();

    while (i < total) {
        const line = try callCore(allocator, "nth", &.{ lines, Value.initInteger(i) });
        const line_str = line.asString();

        var has_open = false;
        var new_depth = depth;
        for (line_str) |c| {
            if (c == '(') {
                has_open = true;
                new_depth += 1;
            } else if (c == ')') {
                new_depth -= 1;
            }
        }

        const new_seen = seen_open or has_open;
        result.append(allocator, line) catch return error.EvalError;

        if (new_seen and new_depth <= 0) {
            // Done — join result lines
            var result_list = Value.nil_val;
            var j = result.items.len;
            while (j > 0) {
                j -= 1;
                result_list = try callCore(allocator, "cons", &.{ result.items[j], result_list });
            }
            return callNs(allocator, "clojure.string", "join", &.{ str(allocator, "\n"), result_list });
        }

        depth = new_depth;
        seen_open = new_seen;
        i += 1;
    }

    // Reached end of file
    var result_list = Value.nil_val;
    var j = result.items.len;
    while (j > 0) {
        j -= 1;
        result_list = try callCore(allocator, "cons", &.{ result.items[j], result_list });
    }
    return callNs(allocator, "clojure.string", "join", &.{ str(allocator, "\n"), result_list });
}

/// (demunge fn-name)
fn demungeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to demunge", .{args.len});
    return callCore(allocator, "str", &.{args[0]});
}

/// (root-cause t)
fn rootCauseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to root-cause", .{args.len});
    var t = args[0];
    while (true) {
        const cause = try callCore(allocator, "ex-cause", &.{t});
        if (!cause.isTruthy()) return t;
        t = cause;
    }
}

/// (stack-element-str el)
fn stackElementStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stack-element-str", .{args.len});
    const el = args[0];
    const is_map = try callCore(allocator, "map?", &.{el});
    if (is_map.isTruthy()) {
        const fn_val = try callCore(allocator, "get", &.{ el, kw(allocator, "fn") });
        const file_val = try callCore(allocator, "get", &.{ el, kw(allocator, "file") });
        const line_val = try callCore(allocator, "get", &.{ el, kw(allocator, "line") });
        return callCore(allocator, "str", &.{ fn_val, str(allocator, " ("), file_val, str(allocator, ":"), line_val, str(allocator, ")") });
    }
    return callCore(allocator, "str", &.{el});
}

/// (pst) (pst e-or-depth) (pst e depth)
fn pstFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        return pstFn(allocator, &.{Value.initInteger(12)});
    }
    if (args.len == 1) {
        const is_num = try callCore(allocator, "number?", &.{args[0]});
        if (is_num.isTruthy()) {
            // Get *e
            const e_var = try callCore(allocator, "resolve", &.{Value.initSymbol(allocator, .{ .ns = null, .name = "*e" })});
            if (!e_var.isTruthy()) return Value.nil_val;
            const e_val = try callCore(allocator, "deref", &.{e_var});
            if (!e_val.isTruthy()) return Value.nil_val;
            return pstFn(allocator, &.{ e_val, args[0] });
        }
        return pstFn(allocator, &.{ args[0], Value.initInteger(12) });
    }
    if (args.len == 2) {
        const e = args[0];
        const depth = args[1];
        const type_val = try callCore(allocator, "type", &.{e});
        const msg = try callCore(allocator, "ex-message", &.{e});
        _ = try callCore(allocator, "println", &.{try callCore(allocator, "str", &.{ type_val, str(allocator, ": "), msg })});

        const data = try callCore(allocator, "ex-data", &.{e});
        if (data.isTruthy()) {
            const trace = try callCore(allocator, "get", &.{ data, kw(allocator, "trace") });
            if (trace.isTruthy()) {
                const frames = try callCore(allocator, "vec", &.{try callCore(allocator, "take", &.{ depth, trace })});
                var frame_seq = try callCore(allocator, "seq", &.{frames});
                while (frame_seq.isTruthy()) {
                    const frame = try callCore(allocator, "first", &.{frame_seq});
                    const fn_val = try callCore(allocator, "get", &.{ frame, kw(allocator, "fn") });
                    const file_val = try callCore(allocator, "get", &.{ frame, kw(allocator, "file") });
                    const line_val = try callCore(allocator, "get", &.{ frame, kw(allocator, "line") });
                    _ = try callCore(allocator, "println", &.{try callCore(allocator, "str", &.{ str(allocator, "  "), fn_val, str(allocator, " ("), file_val, str(allocator, ":"), line_val, str(allocator, ")") })});
                    frame_seq = try callCore(allocator, "next", &.{frame_seq});
                }
            }
        }
        return Value.nil_val;
    }
    return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pst", .{args.len});
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "special-doc", .func = &specialDocFn, .doc = "Returns special doc map for a given name symbol." },
    .{ .name = "namespace-doc", .func = &namespaceDocFn, .doc = "Returns namespace doc map." },
    .{ .name = "print-doc", .func = &printDocFn, .doc = "Prints documentation from a doc map." },
    .{ .name = "dir-fn", .func = &dirFnFn, .doc = "Returns a sorted seq of symbols naming public vars in a namespace." },
    .{ .name = "apropos", .func = &aproposFn, .doc = "Given a pattern, return matching public definitions." },
    .{ .name = "find-doc", .func = &findDocFn, .doc = "Prints documentation for any var matching the pattern." },
    .{ .name = "source-fn", .func = &sourceFnFn, .doc = "Returns a string of the source code for the given symbol." },
    .{ .name = "demunge", .func = &demungeFn, .doc = "Given a fn class name, returns a readable version." },
    .{ .name = "root-cause", .func = &rootCauseFn, .doc = "Returns the initial cause of an exception." },
    .{ .name = "stack-element-str", .func = &stackElementStrFn, .doc = "Returns a string representation of a stack trace element." },
    .{ .name = "pst", .func = &pstFn, .doc = "Prints a stack trace of the most recent exception." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.repl",
    .builtins = &builtins,
    .loading = .eager_eval,
    .embedded_source = es.repl_macros_source,
    .extra_aliases = &.{.{ "clojure.string", "clojure.string" }},
};
