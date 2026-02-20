// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Macro Transforms — Zig-level Form→Form macro expansion.
//!
//! Replaces .clj defmacro definitions with compile-time Form transforms.
//! Each transform takes macro arguments as Form slices and returns a new Form
//! that the Analyzer will then analyze normally.
//!
//! Hooked into Analyzer.analyzeList() before defmacro-based macro lookup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Form = @import("../reader/form.zig").Form;
const FormData = @import("../reader/form.zig").FormData;
const SymbolRef = @import("../reader/form.zig").SymbolRef;

/// Macro transform function signature.
/// Takes allocator and argument forms (excluding the macro name itself).
/// Returns the expanded Form for re-analysis.
pub const MacroTransformFn = *const fn (Allocator, []const Form) anyerror!Form;

/// Lookup table: macro name → transform function.
/// Checked in analyzeList() before env-based macro lookup.
pub const transforms = std.StaticStringMap(MacroTransformFn).initComptime(.{
    // 83E-v2.0.3: will add `when` here as proof of concept
    // 83E-v2.1.x: will add all core macros here
});

/// Look up a macro transform by name. Returns null if no Zig transform exists.
pub fn lookup(name: []const u8) ?MacroTransformFn {
    return transforms.get(name);
}

// ============================================================
// Form construction helpers
// ============================================================

/// Create a symbol Form (unqualified).
pub fn makeSymbol(name: []const u8) Form {
    return .{ .data = .{ .symbol = .{ .ns = null, .name = name } } };
}

/// Create a qualified symbol Form.
pub fn makeQualifiedSymbol(ns: []const u8, name: []const u8) Form {
    return .{ .data = .{ .symbol = .{ .ns = ns, .name = name } } };
}

/// Create a keyword Form (unqualified).
pub fn makeKeyword(name: []const u8) Form {
    return .{ .data = .{ .keyword = .{ .ns = null, .name = name } } };
}

/// Create a nil Form.
pub fn makeNil() Form {
    return .{ .data = .nil };
}

/// Create a boolean Form.
pub fn makeBool(val: bool) Form {
    return .{ .data = .{ .boolean = val } };
}

/// Create an integer Form.
pub fn makeInteger(val: i64) Form {
    return .{ .data = .{ .integer = val } };
}

/// Create a string Form.
pub fn makeString(val: []const u8) Form {
    return .{ .data = .{ .string = val } };
}

/// Create a list Form from elements.
pub fn makeList(allocator: Allocator, elements: []const Form) !Form {
    const items = try allocator.alloc(Form, elements.len);
    @memcpy(items, elements);
    return .{ .data = .{ .list = items } };
}

/// Create a vector Form from elements.
pub fn makeVector(allocator: Allocator, elements: []const Form) !Form {
    const items = try allocator.alloc(Form, elements.len);
    @memcpy(items, elements);
    return .{ .data = .{ .vector = items } };
}

// ============================================================
// Form manipulation utilities
// ============================================================

/// Monotonic counter for gensym. Thread-local not needed (single-threaded analyzer).
var gensym_counter: u64 = 0;

/// Generate a unique symbol name for hygienic macro expansion.
/// Returns a Form like `__auto_42__`.
pub fn gensym(allocator: Allocator) !Form {
    const id = gensym_counter;
    gensym_counter += 1;
    const name = try std.fmt.allocPrint(allocator, "__auto_{d}__", .{id});
    return .{ .data = .{ .symbol = .{ .ns = null, .name = name } } };
}

/// Generate a gensym with a descriptive prefix: `prefix__42__`.
pub fn gensymWithPrefix(allocator: Allocator, prefix: []const u8) !Form {
    const id = gensym_counter;
    gensym_counter += 1;
    const name = try std.fmt.allocPrint(allocator, "{s}__{d}__", .{ prefix, id });
    return .{ .data = .{ .symbol = .{ .ns = null, .name = name } } };
}

/// Create `(quote form)`.
pub fn makeQuoted(allocator: Allocator, form: Form) !Form {
    return makeList(allocator, &.{ makeSymbol("quote"), form });
}

/// Create `(do form1 form2 ...)` from a body slice.
pub fn makeDo(allocator: Allocator, body: []const Form) !Form {
    const items = try allocator.alloc(Form, body.len + 1);
    items[0] = makeSymbol("do");
    @memcpy(items[1..], body);
    return .{ .data = .{ .list = items } };
}

/// Create `(let [bindings...] body...)`.
/// `bindings` should be [name1, val1, name2, val2, ...].
pub fn makeLet(allocator: Allocator, bindings: []const Form, body: []const Form) !Form {
    const binding_vec = try makeVector(allocator, bindings);
    const items = try allocator.alloc(Form, 2 + body.len);
    items[0] = makeSymbol("let");
    items[1] = binding_vec;
    @memcpy(items[2..], body);
    return .{ .data = .{ .list = items } };
}

/// Create `(if test then else)` or `(if test then)`.
pub fn makeIf(allocator: Allocator, test_form: Form, then_form: Form, else_form: ?Form) !Form {
    if (else_form) |ef| {
        return makeList(allocator, &.{ makeSymbol("if"), test_form, then_form, ef });
    } else {
        return makeList(allocator, &.{ makeSymbol("if"), test_form, then_form });
    }
}

/// Create `(fn [params...] body...)`.
pub fn makeFn(allocator: Allocator, params: []const Form, body: []const Form) !Form {
    const param_vec = try makeVector(allocator, params);
    const items = try allocator.alloc(Form, 2 + body.len);
    items[0] = makeSymbol("fn");
    items[1] = param_vec;
    @memcpy(items[2..], body);
    return .{ .data = .{ .list = items } };
}

/// Prepend an element to a Form slice, returning a new slice.
pub fn prependForm(allocator: Allocator, first: Form, rest: []const Form) ![]Form {
    const result = try allocator.alloc(Form, rest.len + 1);
    result[0] = first;
    @memcpy(result[1..], rest);
    return result;
}

/// Append an element to a Form slice, returning a new slice.
pub fn appendForm(allocator: Allocator, items: []const Form, last: Form) ![]Form {
    const result = try allocator.alloc(Form, items.len + 1);
    @memcpy(result[0..items.len], items);
    result[items.len] = last;
    return result;
}

/// Concatenate two Form slices.
pub fn concatForms(allocator: Allocator, a: []const Form, b: []const Form) ![]Form {
    const result = try allocator.alloc(Form, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

// ============================================================
// Tests
// ============================================================

test "makeSymbol creates unqualified symbol" {
    const form = makeSymbol("foo");
    try std.testing.expect(form.data == .symbol);
    try std.testing.expectEqualStrings("foo", form.data.symbol.name);
    try std.testing.expect(form.data.symbol.ns == null);
}

test "makeQualifiedSymbol creates qualified symbol" {
    const form = makeQualifiedSymbol("clojure.core", "map");
    try std.testing.expect(form.data == .symbol);
    try std.testing.expectEqualStrings("clojure.core", form.data.symbol.ns.?);
    try std.testing.expectEqualStrings("map", form.data.symbol.name);
}

test "makeKeyword creates keyword" {
    const form = makeKeyword("added");
    try std.testing.expect(form.data == .keyword);
    try std.testing.expectEqualStrings("added", form.data.keyword.name);
}

test "makeNil creates nil" {
    const form = makeNil();
    try std.testing.expect(form.data == .nil);
}

test "makeBool creates boolean" {
    try std.testing.expect(makeBool(true).data.boolean == true);
    try std.testing.expect(makeBool(false).data.boolean == false);
}

test "makeList creates list from elements" {
    const alloc = std.testing.allocator;
    const elements = [_]Form{
        makeSymbol("if"),
        makeSymbol("test"),
        makeSymbol("body"),
    };
    const form = try makeList(alloc, &elements);
    defer alloc.free(form.data.list);
    try std.testing.expect(form.data == .list);
    try std.testing.expectEqual(@as(usize, 3), form.data.list.len);
    try std.testing.expectEqualStrings("if", form.data.list[0].data.symbol.name);
}

test "makeVector creates vector from elements" {
    const alloc = std.testing.allocator;
    const elements = [_]Form{
        makeSymbol("x"),
        makeInteger(42),
    };
    const form = try makeVector(alloc, &elements);
    defer alloc.free(form.data.vector);
    try std.testing.expect(form.data == .vector);
    try std.testing.expectEqual(@as(usize, 2), form.data.vector.len);
}

test "lookup returns null for unknown macro" {
    try std.testing.expect(lookup("nonexistent") == null);
}

test "gensym generates unique symbols" {
    const alloc = std.testing.allocator;
    const s1 = try gensym(alloc);
    const s2 = try gensym(alloc);
    defer alloc.free(s1.data.symbol.name);
    defer alloc.free(s2.data.symbol.name);
    try std.testing.expect(s1.data == .symbol);
    try std.testing.expect(s2.data == .symbol);
    // Each gensym should have a different name
    try std.testing.expect(!std.mem.eql(u8, s1.data.symbol.name, s2.data.symbol.name));
}

test "gensymWithPrefix uses prefix" {
    const alloc = std.testing.allocator;
    const s = try gensymWithPrefix(alloc, "val");
    defer alloc.free(s.data.symbol.name);
    try std.testing.expect(std.mem.startsWith(u8, s.data.symbol.name, "val__"));
}

test "makeQuoted wraps in quote" {
    const alloc = std.testing.allocator;
    const quoted = try makeQuoted(alloc, makeSymbol("foo"));
    defer alloc.free(quoted.data.list);
    try std.testing.expect(quoted.data == .list);
    try std.testing.expectEqual(@as(usize, 2), quoted.data.list.len);
    try std.testing.expectEqualStrings("quote", quoted.data.list[0].data.symbol.name);
    try std.testing.expectEqualStrings("foo", quoted.data.list[1].data.symbol.name);
}

test "makeDo creates do form" {
    const alloc = std.testing.allocator;
    const body = [_]Form{ makeSymbol("a"), makeSymbol("b") };
    const form = try makeDo(alloc, &body);
    defer alloc.free(form.data.list);
    try std.testing.expectEqual(@as(usize, 3), form.data.list.len);
    try std.testing.expectEqualStrings("do", form.data.list[0].data.symbol.name);
    try std.testing.expectEqualStrings("a", form.data.list[1].data.symbol.name);
    try std.testing.expectEqualStrings("b", form.data.list[2].data.symbol.name);
}

test "makeLet creates let form with bindings and body" {
    const alloc = std.testing.allocator;
    const bindings = [_]Form{ makeSymbol("x"), makeInteger(1) };
    const body = [_]Form{makeSymbol("x")};
    const form = try makeLet(alloc, &bindings, &body);
    defer alloc.free(form.data.list);
    defer alloc.free(form.data.list[1].data.vector);
    try std.testing.expectEqual(@as(usize, 3), form.data.list.len);
    try std.testing.expectEqualStrings("let", form.data.list[0].data.symbol.name);
    try std.testing.expect(form.data.list[1].data == .vector);
    try std.testing.expectEqual(@as(usize, 2), form.data.list[1].data.vector.len);
}

test "makeIf creates if form" {
    const alloc = std.testing.allocator;
    const form = try makeIf(alloc, makeSymbol("test"), makeSymbol("then"), makeSymbol("else"));
    defer alloc.free(form.data.list);
    try std.testing.expectEqual(@as(usize, 4), form.data.list.len);
    try std.testing.expectEqualStrings("if", form.data.list[0].data.symbol.name);
}

test "makeIf without else" {
    const alloc = std.testing.allocator;
    const form = try makeIf(alloc, makeSymbol("test"), makeSymbol("then"), null);
    defer alloc.free(form.data.list);
    try std.testing.expectEqual(@as(usize, 3), form.data.list.len);
}

test "prependForm adds element at front" {
    const alloc = std.testing.allocator;
    const rest = [_]Form{ makeSymbol("b"), makeSymbol("c") };
    const result = try prependForm(alloc, makeSymbol("a"), &rest);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0].data.symbol.name);
    try std.testing.expectEqualStrings("b", result[1].data.symbol.name);
}

test "appendForm adds element at end" {
    const alloc = std.testing.allocator;
    const items = [_]Form{ makeSymbol("a"), makeSymbol("b") };
    const result = try appendForm(alloc, &items, makeSymbol("c"));
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("c", result[2].data.symbol.name);
}

test "concatForms merges two slices" {
    const alloc = std.testing.allocator;
    const a = [_]Form{ makeSymbol("a"), makeSymbol("b") };
    const b = [_]Form{makeSymbol("c")};
    const result = try concatForms(alloc, &a, &b);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0].data.symbol.name);
    try std.testing.expectEqualStrings("c", result[2].data.symbol.name);
}
