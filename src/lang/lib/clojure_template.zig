// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.template namespace — Zig builtins for template-based code generation.
//!
//! Replaces src/clj/clojure/template.clj (25 lines).
//! - apply-template: runtime function (postwalk-replace + zipmap on Values)
//! - do-template: compile-time macro (partition + apply-template, returns (do ...))

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
const PersistentList = @import("../../runtime/collections.zig").PersistentList;
const PersistentVector = @import("../../runtime/collections.zig").PersistentVector;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// apply-template (runtime function)
// ============================================================

/// (apply-template argv expr values)
/// Recursively replaces symbols from argv with corresponding values in expr.
fn applyTemplateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) {
        return err.setError(.{ .kind = .arity_error, .phase = .eval, .message = "apply-template requires exactly 3 arguments" });
    }
    const argv = args[0];
    const expr_val = args[1];
    const values = args[2];

    var keys_buf: [64][]const u8 = undefined;
    var vals_buf: [64]Value = undefined;
    const map_len = try buildSubstitutionMap(argv, values, &keys_buf, &vals_buf);

    return postwalkReplace(allocator, expr_val, keys_buf[0..map_len], vals_buf[0..map_len]);
}

// ============================================================
// do-template (macro — receives unevaluated forms as Values)
// ============================================================

/// (do-template [argv...] expr val1 val2 ...)
fn doTemplateMacro(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) {
        return err.setError(.{ .kind = .arity_error, .phase = .eval, .message = "do-template requires at least 2 arguments: argv and expr" });
    }
    const argv = args[0];
    const expr_val = args[1];

    if (argv.tag() != .vector) {
        return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "do-template: first argument must be a vector" });
    }
    const argv_vec = argv.asVector();
    const argc = argv_vec.count();
    if (argc == 0) {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "do-template: argv must not be empty" });
    }

    const flat_values = args[2..];
    const num_groups = flat_values.len / argc;

    const do_items = try allocator.alloc(Value, num_groups + 1);
    do_items[0] = Value.initSymbol(allocator, .{ .ns = null, .name = "do" });

    var keys_buf: [64][]const u8 = undefined;
    if (argc > keys_buf.len) {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "do-template: too many argv parameters" });
    }
    for (0..argc) |i| {
        const sym_val = argv_vec.nth(i) orelse return err.setError(.{
            .kind = .value_error,
            .phase = .eval,
            .message = "do-template: argv element out of bounds",
        });
        if (sym_val.tag() != .symbol) {
            return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "do-template: argv elements must be symbols" });
        }
        keys_buf[i] = sym_val.asSymbol().name;
    }
    const keys = keys_buf[0..argc];

    for (0..num_groups) |g| {
        const group_start = g * argc;
        const group_vals = flat_values[group_start .. group_start + argc];
        do_items[g + 1] = try postwalkReplace(allocator, expr_val, keys, group_vals);
    }

    const result_list = try allocator.create(PersistentList);
    result_list.* = .{ .items = do_items };
    return Value.initList(result_list);
}

// ============================================================
// Internal helpers
// ============================================================

fn buildSubstitutionMap(
    argv: Value,
    values: Value,
    keys_buf: *[64][]const u8,
    vals_buf: *[64]Value,
) anyerror!usize {
    var argv_items: []const Value = &.{};
    switch (argv.tag()) {
        .vector => argv_items = argv.asVector().items,
        .list => argv_items = argv.asList().items,
        else => return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "apply-template: argv must be a vector or list" }),
    }

    var val_items: []const Value = &.{};
    switch (values.tag()) {
        .vector => val_items = values.asVector().items,
        .list => val_items = values.asList().items,
        else => return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "apply-template: values must be a vector or list" }),
    }

    const len = @min(argv_items.len, val_items.len);
    if (len > keys_buf.len) {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "apply-template: too many template parameters (max 64)" });
    }
    for (0..len) |i| {
        if (argv_items[i].tag() != .symbol) {
            return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "apply-template: argv elements must be symbols" });
        }
        keys_buf[i] = argv_items[i].asSymbol().name;
        vals_buf[i] = val_items[i];
    }
    return len;
}

fn postwalkReplace(
    allocator: Allocator,
    form: Value,
    keys: []const []const u8,
    vals: []const Value,
) anyerror!Value {
    const walked = switch (form.tag()) {
        .list => blk: {
            const lst = form.asList();
            if (lst.items.len == 0) break :blk form;
            const new_items = try allocator.alloc(Value, lst.items.len);
            for (lst.items, 0..) |item, i| {
                new_items[i] = try postwalkReplace(allocator, item, keys, vals);
            }
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items };
            break :blk Value.initList(new_list);
        },
        .vector => blk: {
            const vec = form.asVector();
            if (vec.items.len == 0) break :blk form;
            const new_items = try allocator.alloc(Value, vec.items.len);
            for (vec.items, 0..) |item, i| {
                new_items[i] = try postwalkReplace(allocator, item, keys, vals);
            }
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = new_items };
            break :blk Value.initVector(new_vec);
        },
        else => form,
    };

    return replaceIfMatch(walked, keys, vals);
}

fn replaceIfMatch(form: Value, keys: []const []const u8, vals: []const Value) Value {
    if (form.tag() == .symbol) {
        const sym = form.asSymbol();
        if (sym.ns == null) {
            for (keys, 0..) |k, i| {
                if (std.mem.eql(u8, sym.name, k)) {
                    return vals[i];
                }
            }
        }
    }
    return form;
}

// ============================================================
// Namespace definition
// ============================================================

const builtins_arr = [_]BuiltinDef{
    .{
        .name = "apply-template",
        .func = applyTemplateFn,
        .doc = "For use in macros. argv is an argument list, as in defn. expr is a quoted expression using the symbols in argv. values is a sequence of values to be used for the arguments. apply-template will recursively replace argument symbols in expr with their corresponding values, returning a modified expr.",
        .arglists = "([argv expr values])",
        .added = "1.0",
    },
};

const do_template_def = BuiltinDef{
    .name = "do-template",
    .func = doTemplateMacro,
    .doc = "Repeatedly copies expr (in a do block) for each group of arguments in values. values are automatically partitioned by the number of arguments in argv, an argument vector as in defn.",
    .arglists = "([argv expr & values])",
    .added = "1.0",
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.template",
    .builtins = &builtins_arr,
    .macro_builtins = &.{do_template_def},
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const test_alloc = std.heap.page_allocator;

test "apply-template basic substitution" {
    var argv_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "y" }),
    };
    const argv_vec = try test_alloc.create(PersistentVector);
    argv_vec.* = .{ .items = &argv_items };
    const argv = Value.initVector(argv_vec);

    var expr_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "=" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "y" }),
    };
    const expr_list = try test_alloc.create(PersistentList);
    expr_list.* = .{ .items = &expr_items };
    const expr_val = Value.initList(expr_list);

    var val_items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const val_vec = try test_alloc.create(PersistentVector);
    val_vec.* = .{ .items = &val_items };
    const values = Value.initVector(val_vec);

    const result = try applyTemplateFn(test_alloc, &.{ argv, expr_val, values });

    try testing.expectEqual(Value.Tag.list, result.tag());
    const result_list = result.asList();
    try testing.expectEqual(@as(usize, 3), result_list.items.len);
    try testing.expectEqual(Value.Tag.symbol, result_list.items[0].tag());
    try testing.expect(std.mem.eql(u8, "=", result_list.items[0].asSymbol().name));
    try testing.expectEqual(Value.Tag.integer, result_list.items[1].tag());
    try testing.expectEqual(@as(i64, 1), result_list.items[1].asInteger());
    try testing.expectEqual(Value.Tag.integer, result_list.items[2].tag());
    try testing.expectEqual(@as(i64, 2), result_list.items[2].asInteger());
}

test "do-template macro expansion" {
    var argv_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "y" }),
    };
    const argv_vec = try test_alloc.create(PersistentVector);
    argv_vec.* = .{ .items = &argv_items };
    const argv = Value.initVector(argv_vec);

    var expr_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "=" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "y" }),
    };
    const expr_list = try test_alloc.create(PersistentList);
    expr_list.* = .{ .items = &expr_items };
    const expr_val = Value.initList(expr_list);

    const result = try doTemplateMacro(test_alloc, &.{
        argv,
        expr_val,
        Value.initInteger(1),
        Value.initInteger(1),
        Value.initInteger(2),
        Value.initInteger(2),
    });

    try testing.expectEqual(Value.Tag.list, result.tag());
    const do_list = result.asList();
    try testing.expectEqual(@as(usize, 3), do_list.items.len);

    try testing.expectEqual(Value.Tag.symbol, do_list.items[0].tag());
    try testing.expect(std.mem.eql(u8, "do", do_list.items[0].asSymbol().name));

    try testing.expectEqual(Value.Tag.list, do_list.items[1].tag());
    const group1 = do_list.items[1].asList();
    try testing.expectEqual(@as(usize, 3), group1.items.len);
    try testing.expectEqual(@as(i64, 1), group1.items[1].asInteger());
    try testing.expectEqual(@as(i64, 1), group1.items[2].asInteger());

    try testing.expectEqual(Value.Tag.list, do_list.items[2].tag());
    const group2 = do_list.items[2].asList();
    try testing.expectEqual(@as(usize, 3), group2.items.len);
    try testing.expectEqual(@as(i64, 2), group2.items[1].asInteger());
    try testing.expectEqual(@as(i64, 2), group2.items[2].asInteger());
}

test "postwalkReplace nested forms" {
    const keys = [_][]const u8{"x"};
    const vals = [_]Value{Value.initInteger(42)};

    var neg_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "-" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
    };
    const neg_list = try test_alloc.create(PersistentList);
    neg_list.* = .{ .items = &neg_items };

    var pos_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "pos?" }),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
    };
    const pos_list = try test_alloc.create(PersistentList);
    pos_list.* = .{ .items = &pos_items };

    var if_items = [_]Value{
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "if" }),
        Value.initList(pos_list),
        Value.initSymbol(test_alloc, .{ .ns = null, .name = "x" }),
        Value.initList(neg_list),
    };
    const if_list = try test_alloc.create(PersistentList);
    if_list.* = .{ .items = &if_items };

    const result = try postwalkReplace(test_alloc, Value.initList(if_list), &keys, &vals);

    try testing.expectEqual(Value.Tag.list, result.tag());
    const r = result.asList();
    try testing.expectEqual(@as(usize, 4), r.items.len);

    const cond = r.items[1].asList();
    try testing.expectEqual(@as(i64, 42), cond.items[1].asInteger());

    try testing.expectEqual(@as(i64, 42), r.items[2].asInteger());

    const neg = r.items[3].asList();
    try testing.expectEqual(@as(i64, 42), neg.items[1].asInteger());
}
