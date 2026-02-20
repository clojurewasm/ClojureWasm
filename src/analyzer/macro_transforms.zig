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
    .{ "if-let", transformIfLet },
    .{ "when-let", transformWhenLet },
    .{ "if-some", transformIfSome },
    .{ "when-some", transformWhenSome },
    .{ "when-first", transformWhenFirst },
    .{ "assert-args", transformAssertArgs },
    .{ "binding", transformBinding },
    .{ "with-bindings", transformWithBindings },
    .{ "bound-fn", transformBoundFn },
    .{ "with-local-vars", transformWithLocalVars },
    .{ "with-redefs", transformWithRedefs },
    .{ "defn", transformDefn },
    .{ "defn-", transformDefnPrivate },
    .{ "declare", transformDeclare },
    .{ "defonce", transformDefonce },
    .{ "definline", transformDefinline },
    .{ "vswap!", transformVswap },
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

/// Create a map Form from alternating key-value entries.
pub fn makeMap(allocator: Allocator, entries: []const Form) !Form {
    const items = try allocator.alloc(Form, entries.len);
    @memcpy(items, entries);
    return .{ .data = .{ .map = items } };
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

/// Extract binding pair from a vector form [name expr].
fn extractBindingPair(bindings_form: Form) !struct { name: Form, expr: Form } {
    const vec = switch (bindings_form.data) {
        .vector => |v| v,
        else => return error.InvalidArgs,
    };
    if (vec.len != 2) return error.InvalidArgs;
    return .{ .name = vec[0], .expr = vec[1] };
}

/// `(if-let [x test] then)` or `(if-let [x test] then else)`
/// → `(let [temp test] (if temp (let [x temp] then) else))`
fn transformIfLet(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const bp = try extractBindingPair(args[0]);
    const then_form = args[1];
    const else_form: ?Form = if (args.len >= 3) args[2] else null;
    const temp = try gensymWithPrefix(allocator, "let");
    const inner_let = try makeLet(allocator, &.{ bp.name, temp }, &.{then_form});
    const if_form = try makeIf(allocator, temp, inner_let, else_form orelse makeNil());
    return makeLet(allocator, &.{ temp, bp.expr }, &.{if_form});
}

/// `(when-let [x test] body...)` → `(let [temp test] (when temp (let [x temp] body...)))`
fn transformWhenLet(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bp = try extractBindingPair(args[0]);
    const body = args[1..];
    const temp = try gensymWithPrefix(allocator, "let");
    const inner_let = try makeLet(allocator, &.{ bp.name, temp }, body);
    const when_form = try makeList(allocator, &.{ makeSymbol("when"), temp, inner_let });
    return makeLet(allocator, &.{ temp, bp.expr }, &.{when_form});
}

/// `(if-some [x test] then)` or `(if-some [x test] then else)`
/// → `(let [temp test] (if (nil? temp) else (let [x temp] then)))`
fn transformIfSome(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const bp = try extractBindingPair(args[0]);
    const then_form = args[1];
    const else_form: Form = if (args.len >= 3) args[2] else makeNil();
    const temp = try gensymWithPrefix(allocator, "some");
    const nil_check = try makeList(allocator, &.{ makeSymbol("nil?"), temp });
    const inner_let = try makeLet(allocator, &.{ bp.name, temp }, &.{then_form});
    const if_form = try makeIf(allocator, nil_check, else_form, inner_let);
    return makeLet(allocator, &.{ temp, bp.expr }, &.{if_form});
}

/// `(when-some [x test] body...)` → `(let [temp test] (if (nil? temp) nil (let [x temp] body...)))`
fn transformWhenSome(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bp = try extractBindingPair(args[0]);
    const body = args[1..];
    const temp = try gensymWithPrefix(allocator, "some");
    const nil_check = try makeList(allocator, &.{ makeSymbol("nil?"), temp });
    const inner_let = try makeLet(allocator, &.{ bp.name, temp }, body);
    const if_form = try makeIf(allocator, nil_check, makeNil(), inner_let);
    return makeLet(allocator, &.{ temp, bp.expr }, &.{if_form});
}

/// `(when-first [x xs] body...)` → `(when-let [xs__ (seq xs)] (let [x (first xs__)] body...))`
fn transformWhenFirst(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bp = try extractBindingPair(args[0]);
    const body = args[1..];
    const xs_sym = try gensymWithPrefix(allocator, "xs");
    const seq_expr = try makeList(allocator, &.{ makeSymbol("seq"), bp.expr });
    const first_expr = try makeList(allocator, &.{ makeSymbol("first"), xs_sym });
    const inner_let = try makeLet(allocator, &.{ bp.name, first_expr }, body);
    const binding_vec = try makeVector(allocator, &.{ xs_sym, seq_expr });
    return makeList(allocator, &.{ makeSymbol("when-let"), binding_vec, inner_let });
}

/// `(assert-args test1 "msg1" test2 "msg2" ...)`
/// → `(do (when-not test1 (throw (str "Requires " "msg1"))) ...)`
fn transformAssertArgs(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len % 2 != 0) return error.InvalidArgs;
    const n_checks = args.len / 2;
    var checks = try allocator.alloc(Form, n_checks);
    for (0..n_checks) |i| {
        const test_form = args[i * 2];
        const msg_form = args[i * 2 + 1];
        const str_form = try makeList(allocator, &.{ makeSymbol("str"), makeString("Requires "), msg_form });
        const throw_form = try makeList(allocator, &.{ makeSymbol("throw"), str_form });
        checks[i] = try makeList(allocator, &.{ makeSymbol("when-not"), test_form, throw_form });
    }
    return makeDo(allocator, checks);
}

/// `(binding [*a* 1 *b* 2] body...)` →
/// `(do (push-thread-bindings (hash-map (var *a*) 1 (var *b*) 2)) (try body... (finally (pop-thread-bindings))))`
fn transformBinding(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bindings = switch (args[0].data) {
        .vector => |v| v,
        else => return error.InvalidArgs,
    };
    if (bindings.len % 2 != 0) return error.InvalidArgs;
    const body = args[1..];
    // Build (hash-map (var *a*) 1 (var *b*) 2 ...)
    const n_pairs = bindings.len / 2;
    var hm_args = try allocator.alloc(Form, 1 + n_pairs * 2);
    hm_args[0] = makeSymbol("hash-map");
    for (0..n_pairs) |i| {
        hm_args[1 + i * 2] = try makeList(allocator, &.{ makeSymbol("var"), bindings[i * 2] });
        hm_args[1 + i * 2 + 1] = bindings[i * 2 + 1];
    }
    const hm_form: Form = .{ .data = .{ .list = hm_args } };
    const push_form = try makeList(allocator, &.{ makeSymbol("push-thread-bindings"), hm_form });
    const pop_form = try makeList(allocator, &.{makeSymbol("pop-thread-bindings")});
    const finally_form = try makeList(allocator, &.{ makeSymbol("finally"), pop_form });
    // (try body... (finally (pop-thread-bindings)))
    var try_items = try allocator.alloc(Form, 1 + body.len + 1);
    try_items[0] = makeSymbol("try");
    @memcpy(try_items[1 .. 1 + body.len], body);
    try_items[1 + body.len] = finally_form;
    const try_form: Form = .{ .data = .{ .list = try_items } };
    return makeDo(allocator, &.{ push_form, try_form });
}

/// `(with-bindings map body...)` → `(with-bindings* map (fn [] body...))`
fn transformWithBindings(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const binding_map = args[0];
    const body = args[1..];
    const fn_form = try makeFn(allocator, &.{}, body);
    return makeList(allocator, &.{ makeSymbol("with-bindings*"), binding_map, fn_form });
}

/// `(bound-fn [args] body...)` → `(bound-fn* (fn [args] body...))`
fn transformBoundFn(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len == 0) return error.InvalidArgs;
    // Pass all args as fntail to fn
    var fn_items = try allocator.alloc(Form, 1 + args.len);
    fn_items[0] = makeSymbol("fn");
    @memcpy(fn_items[1..], args);
    const fn_form: Form = .{ .data = .{ .list = fn_items } };
    return makeList(allocator, &.{ makeSymbol("bound-fn*"), fn_form });
}

/// `(with-local-vars [x 10 y 20] body...)` →
/// `(let [x (create-local-var) y (create-local-var)]
///    (push-thread-bindings (hash-map x 10 y 20))
///    (try body... (finally (pop-thread-bindings))))`
fn transformWithLocalVars(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bindings = switch (args[0].data) {
        .vector => |v| v,
        else => return error.InvalidArgs,
    };
    if (bindings.len % 2 != 0) return error.InvalidArgs;
    const body = args[1..];
    const n_pairs = bindings.len / 2;
    // Let bindings: [x (create-local-var) y (create-local-var) ...]
    var let_bindings = try allocator.alloc(Form, n_pairs * 2);
    const create_var = try makeList(allocator, &.{makeSymbol("create-local-var")});
    for (0..n_pairs) |i| {
        let_bindings[i * 2] = bindings[i * 2]; // name
        let_bindings[i * 2 + 1] = create_var; // (create-local-var)
    }
    // (hash-map x 10 y 20 ...)
    var hm_args = try allocator.alloc(Form, 1 + bindings.len);
    hm_args[0] = makeSymbol("hash-map");
    @memcpy(hm_args[1..], bindings);
    const hm_form: Form = .{ .data = .{ .list = hm_args } };
    const push_form = try makeList(allocator, &.{ makeSymbol("push-thread-bindings"), hm_form });
    const pop_form = try makeList(allocator, &.{makeSymbol("pop-thread-bindings")});
    const finally_form = try makeList(allocator, &.{ makeSymbol("finally"), pop_form });
    // (try body... (finally ...))
    var try_items = try allocator.alloc(Form, 1 + body.len + 1);
    try_items[0] = makeSymbol("try");
    @memcpy(try_items[1 .. 1 + body.len], body);
    try_items[1 + body.len] = finally_form;
    const try_form: Form = .{ .data = .{ .list = try_items } };
    // Wrap in let
    return makeLet(allocator, let_bindings, &.{ push_form, try_form });
}

/// `(with-redefs [name1 val1 name2 val2] body...)` →
/// `(with-redefs-fn {(var name1) val1 (var name2) val2} (fn [] body...))`
fn transformWithRedefs(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 1) return error.InvalidArgs;
    const bindings = switch (args[0].data) {
        .vector => |v| v,
        else => return error.InvalidArgs,
    };
    if (bindings.len % 2 != 0) return error.InvalidArgs;
    const body = args[1..];
    const n_pairs = bindings.len / 2;
    // Build map: {(var name1) val1 (var name2) val2 ...}
    var map_items = try allocator.alloc(Form, n_pairs * 2);
    for (0..n_pairs) |i| {
        map_items[i * 2] = try makeList(allocator, &.{ makeSymbol("var"), bindings[i * 2] });
        map_items[i * 2 + 1] = bindings[i * 2 + 1];
    }
    const map_form: Form = .{ .data = .{ .map = map_items } };
    const fn_form = try makeFn(allocator, &.{}, body);
    return makeList(allocator, &.{ makeSymbol("with-redefs-fn"), map_form, fn_form });
}

/// `(declare a b c)` → `(do (def a) (def b) (def c))`
fn transformDeclare(allocator: Allocator, args: []const Form) anyerror!Form {
    var defs = try allocator.alloc(Form, args.len);
    for (args, 0..) |name, i| {
        defs[i] = try makeList(allocator, &.{ makeSymbol("def"), name });
    }
    return makeDo(allocator, defs);
}

/// `(defonce name expr)` → `(when-not (bound? (quote sym)) (def name expr))`
/// where sym = raw symbol extracted from name (which may be (with-meta sym meta))
fn transformDefonce(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len != 2) return error.InvalidArgs;
    const name = args[0];
    const expr = args[1];
    const sym = extractRawSymbol(name);
    const quoted_sym = try makeQuoted(allocator, sym);
    const bound_check = try makeList(allocator, &.{ makeQualifiedSymbol("clojure.core", "bound?"), quoted_sym });
    const def_form = try makeList(allocator, &.{ makeSymbol("def"), name, expr });
    return makeList(allocator, &.{ makeSymbol("when-not"), bound_check, def_form });
}

/// `(vswap! vol f & args)` → `(vreset! vol (f (deref vol) args...))`
fn transformVswap(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const vol = args[0];
    const f = args[1];
    const extra_args = args[2..];
    // Build (deref vol)
    const deref_vol = try makeList(allocator, &.{ makeSymbol("deref"), vol });
    // Build (f (deref vol) extra_args...)
    var call_items = try allocator.alloc(Form, 2 + extra_args.len);
    call_items[0] = f;
    call_items[1] = deref_vol;
    @memcpy(call_items[2..], extra_args);
    const call_form: Form = .{ .data = .{ .list = call_items } };
    // (vreset! vol call_form)
    return makeList(allocator, &.{ makeSymbol("vreset!"), vol, call_form });
}

/// `(defn name doc? attr-map? [params] body...)` or `(defn name doc? attr-map? ([params] body...) ...)`
/// → `(def name-with-meta (fn name arities...))`
fn transformDefn(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformDefnImpl(allocator, args, false);
}

/// `(defn- name ...)` → like defn but adds {:private true} to metadata
fn transformDefnPrivate(allocator: Allocator, args: []const Form) anyerror!Form {
    return transformDefnImpl(allocator, args, true);
}

fn transformDefnImpl(allocator: Allocator, args: []const Form, is_private: bool) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const name = args[0];
    var fdecl = args[1..];

    // Extract optional docstring
    var doc: ?Form = null;
    if (fdecl.len > 0 and fdecl[0].data == .string) {
        doc = fdecl[0];
        fdecl = fdecl[1..];
    }

    // Extract optional attr-map
    var attr_map_entries: ?[]const Form = null;
    if (fdecl.len > 0 and fdecl[0].data == .map) {
        attr_map_entries = fdecl[0].data.map;
        fdecl = fdecl[1..];
    }

    if (fdecl.len == 0) return error.InvalidArgs;

    // Normalize single-arity: if first is vector, wrap to multi-arity form
    if (fdecl[0].data == .vector) {
        const arity_list = try makeList(allocator, fdecl);
        const wrapped = try allocator.alloc(Form, 1);
        wrapped[0] = arity_list;
        fdecl = wrapped;
    }

    // Remove trailing attr-map (legacy pattern)
    if (fdecl.len > 0 and fdecl[fdecl.len - 1].data == .map) {
        fdecl = fdecl[0 .. fdecl.len - 1];
    }

    // Build additional metadata entries
    var meta_list: std.ArrayList(Form) = .empty;
    if (is_private) {
        try meta_list.append(allocator, makeKeyword("private"));
        try meta_list.append(allocator, makeBool(true));
    }
    if (attr_map_entries) |entries| {
        for (entries) |e| {
            try meta_list.append(allocator, e);
        }
    }
    if (doc) |d| {
        try meta_list.append(allocator, makeKeyword("doc"));
        try meta_list.append(allocator, d);
    }

    // Build def-name: wrap with metadata if any
    var def_name = name;
    if (meta_list.items.len > 0) {
        const meta_map = try makeMap(allocator, meta_list.items);
        def_name = try makeList(allocator, &.{ makeSymbol("with-meta"), name, meta_map });
    }

    // Extract raw symbol for fn name (fn analyzer needs plain symbol or single with-meta)
    const fn_name = extractRawSymbol(name);

    // Build (fn fn_name arities...)
    var fn_items = try allocator.alloc(Form, 2 + fdecl.len);
    fn_items[0] = makeSymbol("fn");
    fn_items[1] = fn_name;
    @memcpy(fn_items[2..], fdecl);
    const fn_form: Form = .{ .data = .{ .list = fn_items } };

    // (def def-name fn-form)
    return makeList(allocator, &.{ makeSymbol("def"), def_name, fn_form });
}

/// `(definline name & decl)` → `(defn name pre-args... args expr)`
/// Splits decl at first vector form: everything before = pre-args, vector = args, rest = expr
fn transformDefinline(allocator: Allocator, args: []const Form) anyerror!Form {
    if (args.len < 2) return error.InvalidArgs;
    const name = args[0];
    const decl = args[1..];

    // Find first vector in decl (split-with (comp not vector?) decl)
    var split_idx: usize = 0;
    while (split_idx < decl.len) : (split_idx += 1) {
        if (decl[split_idx].data == .vector) break;
    }
    if (split_idx >= decl.len) return error.InvalidArgs; // no vector found

    const pre_args = decl[0..split_idx];
    const params = decl[split_idx]; // vector
    const body = decl[split_idx + 1 ..];

    // Build (defn name pre-args... params body...)
    var defn_items = try allocator.alloc(Form, 2 + pre_args.len + 1 + body.len);
    defn_items[0] = makeSymbol("defn");
    defn_items[1] = name;
    @memcpy(defn_items[2 .. 2 + pre_args.len], pre_args);
    defn_items[2 + pre_args.len] = params;
    @memcpy(defn_items[2 + pre_args.len + 1 ..], body);
    const defn_form: Form = .{ .data = .{ .list = defn_items } };
    // Re-analyze will invoke transformDefn
    return defn_form;
}

/// Extract the raw symbol from a form that may be wrapped in (with-meta sym meta).
/// Recursively unwraps nested with-meta forms.
fn extractRawSymbol(form: Form) Form {
    if (form.data == .symbol) return form;
    if (form.data == .list) {
        const items = form.data.list;
        if (items.len == 3 and items[0].data == .symbol and
            std.mem.eql(u8, items[0].data.symbol.name, "with-meta"))
        {
            return extractRawSymbol(items[1]);
        }
    }
    return form;
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
