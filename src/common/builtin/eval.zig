// eval builtins — read-string, eval, macroexpand-1, macroexpand.
//
// Provides runtime eval pipeline and macro expansion introspection.
// These builtins bridge the reader/analyzer/evaluator pipeline into
// callable Clojure functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../value.zig").Value;
const Reader = @import("../reader/reader.zig").Reader;
const Form = @import("../reader/form.zig").Form;
const macro = @import("../macro.zig");
const Analyzer = @import("../analyzer/analyzer.zig").Analyzer;
const Node = @import("../analyzer/node.zig").Node;
const bootstrap = @import("../bootstrap.zig");
const TreeWalk = @import("../../native/evaluator/tree_walk.zig").TreeWalk;
const err = @import("../error.zig");
const Env = @import("../env.zig").Env;

// ============================================================
// read-string
// ============================================================

/// (read-string s)
/// Reads one object from the string s. Returns nil if string is empty.
pub fn readStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read-string", .{args.len});
    const s = switch (args[0]) {
        .string => |str| str,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "read-string expects a string, got {s}", .{@tagName(args[0])}),
    };
    if (s.len == 0) return .nil;

    var reader = Reader.init(allocator, s);
    const form_opt = reader.read() catch return error.EvalError;
    const form = form_opt orelse return .nil;
    return macro.formToValue(allocator, form);
}

// ============================================================
// eval
// ============================================================

/// (eval form)
/// Evaluates the form data structure and returns the result.
/// For (do ...) forms, evaluates each sub-form sequentially so that
/// side effects (def, declare) are visible to subsequent forms.
pub fn evalFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to eval", .{args.len});
    const env = bootstrap.macro_eval_env orelse return error.EvalError;

    // Convert Value -> Form
    const form = try macro.valueToForm(allocator, args[0]);

    // Special case: (do ...) — evaluate each body form sequentially
    // so that def/declare side effects are visible to later forms.
    // This matches JVM Clojure's eval behavior.
    if (isDoForm(form)) {
        const body = form.data.list[1..]; // skip 'do symbol
        var result: Value = .nil;
        for (body) |sub_form| {
            result = try evalOneForm(allocator, env, sub_form);
        }
        return result;
    }

    return evalOneForm(allocator, env, form);
}

fn evalOneForm(allocator: Allocator, env: *Env, form: Form) anyerror!Value {
    var analyzer = Analyzer.initWithEnv(allocator, env);
    defer analyzer.deinit();
    const node = analyzer.analyze(form) catch return error.AnalyzeError;

    var tw = TreeWalk.initWithEnv(allocator, env);
    return tw.run(node) catch return error.EvalError;
}

fn isDoForm(form: Form) bool {
    const items = switch (form.data) {
        .list => |l| l,
        else => return false,
    };
    if (items.len == 0) return false;
    const head = items[0].data;
    return switch (head) {
        .symbol => |s| s.ns == null and std.mem.eql(u8, s.name, "do"),
        else => false,
    };
}

// ============================================================
// macroexpand-1
// ============================================================

/// (macroexpand-1 form)
/// If form is a list whose first element resolves to a macro Var,
/// expands it once and returns the result. Otherwise returns form unchanged.
pub fn macroexpand1Fn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to macroexpand-1", .{args.len});
    return macroexpand1(allocator, args[0]);
}

fn macroexpand1(allocator: Allocator, form: Value) anyerror!Value {
    // Only expand list forms starting with a symbol
    const lst = switch (form) {
        .list => |l| l,
        else => return form,
    };
    if (lst.items.len == 0) return form;

    const head = lst.items[0];
    const sym = switch (head) {
        .symbol => |s| s,
        else => return form,
    };

    // Resolve symbol to Var
    const env = bootstrap.macro_eval_env orelse return form;
    const ns = env.current_ns orelse return form;
    const v = if (sym.ns) |ns_name|
        ns.resolveQualified(ns_name, sym.name)
    else
        ns.resolve(sym.name);

    const var_ref = v orelse return form;
    if (!var_ref.isMacro()) return form;

    // Call macro function with remaining list elements as args
    const macro_fn = var_ref.deref();
    return bootstrap.callFnVal(allocator, macro_fn, lst.items[1..]);
}

// ============================================================
// macroexpand
// ============================================================

/// (macroexpand form)
/// Repeatedly calls macroexpand-1 until the form no longer changes.
pub fn macroexpandFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to macroexpand", .{args.len});

    var current = args[0];
    var i: usize = 0;
    const max_expansions = 1000;
    while (i < max_expansions) : (i += 1) {
        const expanded = try macroexpand1(allocator, current);
        // If expansion didn't change the form, we're done
        if (expanded.eql(current)) break;
        current = expanded;
    }
    return current;
}

// ============================================================
// load-string
// ============================================================

/// (load-string s)
/// Sequentially read and evaluate the set of forms contained in the string.
pub fn loadStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to load-string", .{args.len});
    const s = switch (args[0]) {
        .string => |str| str,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "load-string expects a string, got {s}", .{@tagName(args[0])}),
    };
    if (s.len == 0) return .nil;

    const env = bootstrap.macro_eval_env orelse return error.EvalError;

    var reader = Reader.init(allocator, s);
    var result: Value = .nil;
    while (true) {
        const form_opt = reader.read() catch return error.EvalError;
        const form = form_opt orelse break;
        const val = macro.formToValue(allocator, form) catch return error.EvalError;
        const eval_form = macro.valueToForm(allocator, val) catch return error.EvalError;

        if (isDoForm(eval_form)) {
            const body = eval_form.data.list[1..];
            for (body) |sub_form| {
                result = try evalOneForm(allocator, env, sub_form);
            }
        } else {
            result = try evalOneForm(allocator, env, eval_form);
        }
    }
    return result;
}

// ============================================================
// clojure.edn/read-string
// ============================================================

/// (clojure.edn/read-string s)
/// (clojure.edn/read-string opts s)
/// Reads one object from the string s in EDN format.
/// opts is an optional map (currently ignored — reader is already EDN-safe).
/// Returns nil when s is nil or empty.
pub fn ednReadStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    switch (args.len) {
        1 => {
            // (edn/read-string s)
            if (args[0] == .nil) return .nil;
            const s = switch (args[0]) {
                .string => |str| str,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.edn/read-string expects a string, got {s}", .{@tagName(args[0])}),
            };
            if (s.len == 0) return .nil;
            var reader = Reader.init(allocator, s);
            const form_opt = reader.read() catch return error.EvalError;
            const form = form_opt orelse return .nil;
            return macro.formToValue(allocator, form);
        },
        2 => {
            // (edn/read-string opts s) — opts map currently ignored
            if (args[1] == .nil) return .nil;
            const s = switch (args[1]) {
                .string => |str| str,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.edn/read-string expects a string as second arg, got {s}", .{@tagName(args[1])}),
            };
            if (s.len == 0) return .nil;
            var reader = Reader.init(allocator, s);
            const form_opt = reader.read() catch return error.EvalError;
            const form = form_opt orelse return .nil;
            return macro.formToValue(allocator, form);
        },
        else => return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.edn/read-string", .{args.len}),
    }
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "read-string",
        .func = readStringFn,
        .doc = "Reads one object from the string s. Returns nil for empty string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "eval",
        .func = evalFn,
        .doc = "Evaluates the form data structure (not text!) and returns the result.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "macroexpand-1",
        .func = macroexpand1Fn,
        .doc = "If form represents a macro form, returns its expansion, else returns form.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "load-string",
        .func = loadStringFn,
        .doc = "Sequentially read and evaluate the set of forms contained in the string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "macroexpand",
        .func = macroexpandFn,
        .doc = "Repeatedly calls macroexpand-1 on form until it no longer represents a macro form, then returns it.",
        .arglists = "([form])",
        .added = "1.0",
    },
};

/// clojure.edn namespace builtins.
pub const edn_builtins = [_]BuiltinDef{
    .{
        .name = "read-string",
        .func = ednReadStringFn,
        .doc = "Reads one object from the string s. Returns nil when s is nil or empty.",
        .arglists = "([s] [opts s])",
        .added = "1.5",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "read-string - integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "42" }});
    try testing.expectEqual(Value{ .integer = 42 }, result);
}

test "read-string - string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "\"hello\"" }});
    try testing.expectEqualStrings("hello", result.string);
}

test "read-string - symbol" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "foo" }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("foo", result.symbol.name);
}

test "read-string - keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = ":bar" }});
    try testing.expect(result == .keyword);
    try testing.expectEqualStrings("bar", result.keyword.name);
}

test "read-string - vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "[1 2 3]" }});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.items.len);
}

test "read-string - empty string returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "" }});
    try testing.expectEqual(Value.nil, result);
}

test "read-string - map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "{:a 1}" }});
    try testing.expect(result == .map);
}

test "read-string - list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{.{ .string = "(+ 1 2)" }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
}
