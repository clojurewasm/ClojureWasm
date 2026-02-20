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
    .{ "when", transformWhen },
    .{ "when-not", transformWhenNot },
    .{ "if-not", transformIfNot },
    .{ "comment", transformComment },
    .{ "while", transformWhile },
    .{ "assert", transformAssert },
    .{ "and", transformAnd },
    .{ "or", transformOr },
    .{ "->", transformThreadFirst },
    .{ "->>", transformThreadLast },
    .{ "as->", transformAsThread },
    .{ "some->", transformSomeThreadFirst },
    .{ "some->>", transformSomeThreadLast },
    .{ "cond->", transformCondThreadFirst },
    .{ "cond->>", transformCondThreadLast },
    .{ "doto", transformDoto },
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
// Macro transform implementations
// ============================================================

/// `(when test body...)` → `(if test (do body...))`
fn transformWhen(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const test_form = args[0];
    const body = args[1..];
    const do_form = try makeDo(allocator, body);
    return makeIf(allocator, test_form, do_form, null);
}

/// `(when-not test body...)` → `(if test nil (do body...))`
fn transformWhenNot(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const test_form = args[0];
    const body = args[1..];
    const do_form = try makeDo(allocator, body);
    return makeIf(allocator, test_form, makeNil(), do_form);
}

/// `(if-not test then)` or `(if-not test then else)` → `(if (not test) then else)`
fn transformIfNot(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const test_form = args[0];
    const then_form = args[1];
    const else_form: ?Form = if (args.len >= 3) args[2] else null;
    const not_test = try makeList(allocator, &.{ makeSymbol("not"), test_form });
    return makeIf(allocator, not_test, then_form, else_form);
}

/// `(comment ...)` → `nil`
fn transformComment(_: Allocator, _: []const Form) anyerror!Form {
    return makeNil();
}

/// `(while test body...)` → `(loop [] (when test body... (recur)))`
fn transformWhile(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const test_form = args[0];
    const body = args[1..];
    // Build: (when test body... (recur))
    const recur_form = try makeList(allocator, &.{makeSymbol("recur")});
    const when_body = try appendForm(allocator, body, recur_form);
    const when_items = try prependForm(allocator, test_form, when_body);
    const when_all = try prependForm(allocator, makeSymbol("when"), when_items);
    const when_form: Form = .{ .data = .{ .list = when_all } };
    // Build: (loop [] when_form)
    const empty_vec = try makeVector(allocator, &.{});
    return makeList(allocator, &.{ makeSymbol("loop"), empty_vec, when_form });
}

/// `(assert x)` or `(assert x message)` →
/// `(when *assert* (when-not x (throw (str "Assert failed: " (pr-str 'x)))))`
fn transformAssert(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const x = args[0];
    const quoted_x = try makeQuoted(allocator, x);
    const pr_str_x = try makeList(allocator, &.{ makeSymbol("pr-str"), quoted_x });

    const throw_form = if (args.len >= 2) blk: {
        const message = args[1];
        const str_form = try makeList(allocator, &.{
            makeSymbol("str"),
            makeString("Assert failed: "),
            message,
            makeString("\n"),
            pr_str_x,
        });
        break :blk try makeList(allocator, &.{ makeSymbol("throw"), str_form });
    } else blk: {
        const str_form = try makeList(allocator, &.{
            makeSymbol("str"),
            makeString("Assert failed: "),
            pr_str_x,
        });
        break :blk try makeList(allocator, &.{ makeSymbol("throw"), str_form });
    };

    // (when-not x throw_form)
    const when_not_form = try makeList(allocator, &.{ makeSymbol("when-not"), x, throw_form });
    // (when *assert* when_not_form)
    return makeList(allocator, &.{ makeSymbol("when"), makeSymbol("*assert*"), when_not_form });
}

/// `(and)` → `true`
/// `(and x)` → `x`
/// `(and x y ...)` → `(let [g x] (if g (and y ...) g))`
fn transformAnd(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return makeBool(true);
    if (args.len == 1) return args[0];
    const g = try gensymWithPrefix(allocator, "and");
    // (and rest...)
    const and_rest_items = try prependForm(allocator, makeSymbol("and"), args[1..]);
    const and_rest: Form = .{ .data = .{ .list = and_rest_items } };
    // (if g (and rest...) g)
    const if_form = try makeIf(allocator, g, and_rest, g);
    // (let [g x] if_form)
    return makeLet(allocator, &.{ g, args[0] }, &.{if_form});
}

/// `(or)` → `nil`
/// `(or x)` → `x`
/// `(or x y ...)` → `(let [g x] (if g g (or y ...)))`
fn transformOr(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return makeNil();
    if (args.len == 1) return args[0];
    const g = try gensymWithPrefix(allocator, "or");
    // (or rest...)
    const or_rest_items = try prependForm(allocator, makeSymbol("or"), args[1..]);
    const or_rest: Form = .{ .data = .{ .list = or_rest_items } };
    // (if g g (or rest...))
    const if_form = try makeIf(allocator, g, g, or_rest);
    // (let [g x] if_form)
    return makeLet(allocator, &.{ g, args[0] }, &.{if_form});
}

/// `(-> x form1 form2 ...)` — thread-first
/// Each form: if list `(f a)` → `(f x a)`, if symbol `f` → `(f x)`
fn transformThreadFirst(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return error.InvalidArgs;
    var result = args[0];
    for (args[1..]) |form| {
        result = try threadForm(allocator, result, form, .first);
    }
    return result;
}

/// `(->> x form1 form2 ...)` — thread-last
fn transformThreadLast(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return error.InvalidArgs;
    var result = args[0];
    for (args[1..]) |form| {
        result = try threadForm(allocator, result, form, .last);
    }
    return result;
}

const ThreadPosition = enum { first, last };

fn threadForm(allocator: Allocator, threaded: Form, form: Form, pos: ThreadPosition) !Form {
    if (form.data == .list and form.data.list.len > 0) {
        const items = form.data.list;
        return switch (pos) {
            .first => blk: {
                // (f a b) + threaded → (f threaded a b)
                var new_items = try allocator.alloc(Form, items.len + 1);
                new_items[0] = items[0]; // f
                new_items[1] = threaded;
                @memcpy(new_items[2..], items[1..]);
                break :blk Form{ .data = .{ .list = new_items } };
            },
            .last => blk: {
                // (f a b) + threaded → (f a b threaded)
                var new_items = try allocator.alloc(Form, items.len + 1);
                @memcpy(new_items[0..items.len], items);
                new_items[items.len] = threaded;
                break :blk Form{ .data = .{ .list = new_items } };
            },
        };
    }
    // symbol `f` → `(f threaded)`
    return makeList(allocator, &.{ form, threaded });
}

/// `(as-> expr name form1 form2 ...)` → `(let [name expr name form1 name form2 ...] name)`
fn transformAsThread(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const expr = args[0];
    const name = args[1];
    const forms = args[2..];
    // Build bindings: [name expr name form1 name form2 ...]
    var bindings = try allocator.alloc(Form, 2 + forms.len * 2);
    bindings[0] = name;
    bindings[1] = expr;
    for (forms, 0..) |form, i| {
        bindings[2 + i * 2] = name;
        bindings[2 + i * 2 + 1] = form;
    }
    return makeLet(allocator, bindings, &.{name});
}

/// `(some-> expr form1 form2 ...)` — thread-first with nil short-circuit
fn transformSomeThreadFirst(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformSomeThread(allocator, args, .first);
}

/// `(some->> expr form1 form2 ...)` — thread-last with nil short-circuit
fn transformSomeThreadLast(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformSomeThread(allocator, args, .last);
}

fn transformSomeThread(allocator: Allocator, args: []const Form, pos: ThreadPosition) !Form {
    if (args.len == 0) return error.InvalidArgs;
    if (args.len == 1) return args[0];
    const expr = args[0];
    const forms = args[1..];
    const g = try gensymWithPrefix(allocator, "some");
    // Build from inside out: last step first
    var result = try threadForm(allocator, g, forms[forms.len - 1], pos);
    // Wrap each step in: (let [g prev] (if (nil? g) nil step))
    var i: usize = forms.len - 1;
    while (i > 0) {
        i -= 1;
        const step = try threadForm(allocator, g, forms[i], pos);
        const nil_check = try makeList(allocator, &.{ makeSymbol("nil?"), g });
        const if_form = try makeIf(allocator, nil_check, makeNil(), result);
        result = try makeLet(allocator, &.{ g, step }, &.{if_form});
    }
    // Outermost let binds g to expr
    const nil_check = try makeList(allocator, &.{ makeSymbol("nil?"), g });
    const if_form = try makeIf(allocator, nil_check, makeNil(), result);
    return makeLet(allocator, &.{ g, expr }, &.{if_form});
}

/// `(cond-> expr test1 form1 test2 form2 ...)` — conditional thread-first
fn transformCondThreadFirst(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformCondThread(allocator, args, .first);
}

/// `(cond->> expr test1 form1 test2 form2 ...)` — conditional thread-last
fn transformCondThreadLast(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformCondThread(allocator, args, .last);
}

fn transformCondThread(allocator: Allocator, args: []const Form, pos: ThreadPosition) !Form {
    if (args.len == 0) return error.InvalidArgs;
    const expr = args[0];
    const clauses = args[1..];
    if (clauses.len % 2 != 0) return error.InvalidArgs;
    var result = expr;
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const test_form = clauses[i];
        const form = clauses[i + 1];
        const g = try gensymWithPrefix(allocator, "cond");
        const step = try threadForm(allocator, g, form, pos);
        const if_form = try makeIf(allocator, test_form, step, g);
        result = try makeLet(allocator, &.{ g, result }, &.{if_form});
    }
    return result;
}

/// `(doto x form1 form2 ...)` — evaluate forms with x as first arg, return x
fn transformDoto(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return error.InvalidArgs;
    const x = args[0];
    const forms = args[1..];
    const g = try gensymWithPrefix(allocator, "doto");
    // Build body: (f g args...) for each form, then g at the end
    var body = try allocator.alloc(Form, forms.len + 1);
    for (forms, 0..) |form, i| {
        if (form.data == .list and form.data.list.len > 0) {
            const items = form.data.list;
            var new_items = try allocator.alloc(Form, items.len + 1);
            new_items[0] = items[0];
            new_items[1] = g;
            @memcpy(new_items[2..], items[1..]);
            body[i] = .{ .data = .{ .list = new_items } };
        } else {
            body[i] = try makeList(allocator, &.{ form, g });
        }
    }
    body[forms.len] = g; // return g
    return makeLet(allocator, &.{ g, x }, body);
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
