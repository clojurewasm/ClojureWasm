//! Zig-level Form→Form transforms for the bootstrap macros.
//!
//! Phase 3.7 ships nine syntactic-sugar macros: `let`, `when`,
//! `cond`, `->`, `->>`, `and`, `or`, `if-let`, `when-let`. Each is
//! implemented as a Zig function whose signature matches
//! `eval/macro_dispatch.zig::ZigExpandFn`. At startup `registerInto`
//! interns each name as a Var in the `rt` namespace with
//! `flags.macro_ = true`, refers them into `user`, and inserts the
//! transform into the analyzer's `MacroTable`.
//!
//! ### Why Form→Form
//!
//! ADR 0001: macros operate on Forms (the analyzer's input AST), not
//! on Values. That keeps source-location attribution intact through
//! expansion and avoids any heap allocation for the static cases
//! (Zig transforms never traverse the runtime Value heap).
//!
//! ### Hygiene
//!
//! Auto-gensym is wired through `Runtime.gensym(arena, prefix)` —
//! see `runtime/runtime.zig`. The output names follow Clojure's
//! `<prefix>__<n>__auto__` convention so that the (eventual) user
//! `defmacro` path produces visually consistent symbols.

const std = @import("std");

const Form = @import("../eval/form.zig").Form;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;

pub const RegisterError = error{
    RtNamespaceMissing,
    UserNamespaceMissing,
    OutOfMemory,
};

/// Intern macro Vars in `rt`, refer into `user`, populate `table`
/// with the Zig transforms. Idempotent.
pub fn registerInto(env: *Env, table: *macro_dispatch.Table) !void {
    const rt_ns = env.findNs("rt") orelse return RegisterError.RtNamespaceMissing;
    const user_ns = env.findNs("user") orelse return RegisterError.UserNamespaceMissing;

    inline for (BOOTSTRAP) |entry| {
        const v = try env.intern(rt_ns, entry.name, .nil_val);
        v.flags.macro_ = true;
        try ensureRegistered(table, entry.name, entry.expand);
    }

    try env.referAll(rt_ns, user_ns);
}

/// `register` asserts uniqueness; this wraps it so re-running
/// `registerInto` (e.g., after a clear in tests) is a no-op rather
/// than a debug-assert crash.
fn ensureRegistered(
    table: *macro_dispatch.Table,
    name: []const u8,
    expand: macro_dispatch.ZigExpandFn,
) !void {
    if (table.lookup(name) != null) return;
    try table.register(name, expand);
}

const Entry = struct {
    name: []const u8,
    expand: macro_dispatch.ZigExpandFn,
};

const BOOTSTRAP = [_]Entry{
    .{ .name = "let", .expand = expandLet },
    .{ .name = "when", .expand = expandWhen },
    .{ .name = "cond", .expand = expandCond },
    .{ .name = "->", .expand = expandThreadFirst },
    .{ .name = "->>", .expand = expandThreadLast },
    .{ .name = "and", .expand = expandAnd },
    .{ .name = "or", .expand = expandOr },
    .{ .name = "if-let", .expand = expandIfLet },
    .{ .name = "when-let", .expand = expandWhenLet },
};

// --- Form-construction conveniences ---

const list = macro_dispatch.makeList;
const sym = macro_dispatch.makeSymbol;
const nilForm = macro_dispatch.makeNil;

// --- let — for now, plain rename to let* ---
//
// Clojure's `let` adds destructuring on top of `let*`; we ship the
// rename today and revisit destructuring in a later phase. This keeps
// the macro dispatch path exercised even though the transform itself
// is trivial.

fn expandLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "let requires bindings vector and at least one body form", .{});
    if (args[0].data != .vector)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, args[0].location, "let bindings must be a vector", .{});

    var items = try arena.alloc(Form, args.len + 1);
    items[0] = sym("let*", loc);
    @memcpy(items[1..], args);
    return list(arena, items, loc);
}

// --- when — `(when c body...)` → `(if c (do body...) nil)` ---

fn expandWhen(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "when requires a test and at least one body form", .{});

    const cond_form = args[0];
    const body = args[1..];

    // (do body...) -- but if there's a single body form, fold to it
    // directly so the expanded shape is simpler to read in error
    // messages.
    const then_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = cond_form;
    if_items[2] = then_form;
    if_items[3] = nilForm(loc);
    return list(arena, if_items, loc);
}

// --- cond — right-associative cascade of ifs ---

fn expandCond(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len == 0) return nilForm(loc);
    if (args.len % 2 != 0)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "cond requires an even number of forms (got {d})", .{args.len});

    return buildCondTail(arena, args, loc);
}

fn buildCondTail(
    arena: std.mem.Allocator,
    pairs: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (pairs.len == 0) return nilForm(loc);
    const test_f = pairs[0];
    const then_f = pairs[1];
    const rest_pairs = pairs[2..];

    const else_f = if (rest_pairs.len == 0) nilForm(loc) else try buildCondTail(arena, rest_pairs, loc);

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = test_f;
    if_items[2] = then_f;
    if_items[3] = else_f;
    return list(arena, if_items, loc);
}

// --- -> / ->> — thread-first / thread-last ---

fn expandThreadFirst(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return threadInto(arena, rt, args, loc, .first);
}

fn expandThreadLast(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return threadInto(arena, rt, args, loc, .last);
}

const ThreadDir = enum { first, last };

fn threadInto(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
    dir: ThreadDir,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len == 0)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "{s} requires at least one argument", .{if (dir == .first) "->" else "->>"});

    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const step = args[i];
        acc = try threadStep(arena, acc, step, dir);
    }
    return acc;
}

fn threadStep(
    arena: std.mem.Allocator,
    acc: Form,
    step: Form,
    dir: ThreadDir,
) macro_dispatch.ExpandError!Form {
    // Bare-symbol step: `(-> x f)` → `(f x)`.
    if (step.data == .symbol) {
        const items = try arena.alloc(Form, 2);
        items[0] = step;
        items[1] = acc;
        return list(arena, items, step.location);
    }
    if (step.data != .list)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, step.location, "thread macro step must be a list or symbol, got {s}", .{step.typeName()});

    const orig = step.data.list;
    if (orig.len == 0)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, step.location, "thread macro step must not be an empty list", .{});

    const new_items = try arena.alloc(Form, orig.len + 1);
    switch (dir) {
        .first => {
            // (f a b ...) → (f acc a b ...)
            new_items[0] = orig[0];
            new_items[1] = acc;
            @memcpy(new_items[2..], orig[1..]);
        },
        .last => {
            // (f a b ...) → (f a b ... acc)
            @memcpy(new_items[0..orig.len], orig);
            new_items[orig.len] = acc;
        },
    }
    return list(arena, new_items, step.location);
}

// --- and / or — short-circuit via gensym + let* + if ---

fn expandAnd(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0) return macro_dispatch.makeBool(true, loc);
    if (args.len == 1) return args[0];

    // (let* [g <args[0]>] (if g (and <args[1..]>) g))
    const gname = try rt.gensym(arena, "and");
    const rest_call = try buildSelfCall(arena, "and", args[1..], loc);
    return buildShortCircuit(arena, gname, args[0], rest_call, sym(gname, loc), loc, .truthy);
}

fn expandOr(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0) return nilForm(loc);
    if (args.len == 1) return args[0];

    // (let* [g <args[0]>] (if g g (or <args[1..]>)))
    const gname = try rt.gensym(arena, "or");
    const rest_call = try buildSelfCall(arena, "or", args[1..], loc);
    return buildShortCircuit(arena, gname, args[0], sym(gname, loc), rest_call, loc, .truthy);
}

const ShortCircuit = enum { truthy };

/// `(let* [g expr] (if g <then_when_truthy> <else_when_falsy>))`.
fn buildShortCircuit(
    arena: std.mem.Allocator,
    gname: []const u8,
    expr: Form,
    then_branch: Form,
    else_branch: Form,
    loc: SourceLocation,
    _: ShortCircuit,
) macro_dispatch.ExpandError!Form {
    const binding = try arena.alloc(Form, 2);
    binding[0] = sym(gname, loc);
    binding[1] = expr;

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = sym(gname, loc);
    if_items[2] = then_branch;
    if_items[3] = else_branch;
    const if_form = try list(arena, if_items, loc);

    const let_items = try arena.alloc(Form, 3);
    let_items[0] = sym("let*", loc);
    let_items[1] = .{ .data = .{ .vector = binding }, .location = loc };
    let_items[2] = if_form;
    return list(arena, let_items, loc);
}

fn buildSelfCall(
    arena: std.mem.Allocator,
    head: []const u8,
    rest: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    const items = try arena.alloc(Form, rest.len + 1);
    items[0] = sym(head, loc);
    @memcpy(items[1..], rest);
    return list(arena, items, loc);
}

// --- if-let / when-let ---
//
// `(if-let [name expr] then else?)` →
//   `(let* [g expr] (if g (let* [name g] then) else))`
// `(when-let [name expr] body...)` →
//   `(if-let [name expr] (do body...) nil)`

fn expandIfLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 2 or args.len > 3)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "if-let requires [name expr] and a then form (else optional)", .{});
    if (args[0].data != .vector or args[0].data.vector.len != 2)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, args[0].location, "if-let bindings must be a vector of [name expr]", .{});

    const binding_v = args[0].data.vector;
    if (binding_v[0].data != .symbol or binding_v[0].data.symbol.ns != null)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, binding_v[0].location, "if-let binding name must be an unqualified symbol", .{});

    const name_form = binding_v[0];
    const expr_form = binding_v[1];
    const then_form = args[1];
    const else_form: Form = if (args.len == 3) args[2] else nilForm(loc);

    const gname = try rt.gensym(arena, "if_let");

    // Inner: (let* [name g] then)
    const inner_binding = try arena.alloc(Form, 2);
    inner_binding[0] = name_form;
    inner_binding[1] = sym(gname, loc);
    const inner_let_items = try arena.alloc(Form, 3);
    inner_let_items[0] = sym("let*", loc);
    inner_let_items[1] = .{ .data = .{ .vector = inner_binding }, .location = loc };
    inner_let_items[2] = then_form;
    const inner_let = try list(arena, inner_let_items, loc);

    // Outer: (let* [g expr] (if g <inner_let> else))
    return buildShortCircuit(arena, gname, expr_form, inner_let, else_form, loc, .truthy);
}

fn expandWhenLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_mod.setErrorFmt(.macroexpand, .syntax_error, loc, "when-let requires [name expr] and at least one body form", .{});

    const binding_form = args[0];
    const body = args[1..];

    // Build (do body...) (or single body form).
    const body_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    // Wrap in (if-let [name expr] body nil) -- analyzer re-expands
    // through expandIfLet on the next pass, so we get the gensym for
    // free.
    const if_let_items = try arena.alloc(Form, 4);
    if_let_items[0] = sym("if-let", loc);
    if_let_items[1] = binding_form;
    if_let_items[2] = body_form;
    if_let_items[3] = nilForm(loc);
    return list(arena, if_let_items, loc);
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.table = macro_dispatch.Table.init(alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "registerInto wires every bootstrap macro into rt and the Table" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try registerInto(&fix.env, &fix.table);

    const rt_ns = fix.env.findNs("rt").?;
    inline for (BOOTSTRAP) |e| {
        const v = rt_ns.resolve(e.name) orelse return error.TestUnexpectedResult;
        try testing.expect(v.flags.macro_);
        try testing.expect(fix.table.lookup(e.name) != null);
    }
}

test "expandLet renames head to let*" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const x_sym = sym("x", .{});
    const one = Form{ .data = .{ .integer = 1 }, .location = .{} };
    const binding_v = try arena.dupe(Form, &.{ x_sym, one });
    const bindings_form = Form{ .data = .{ .vector = binding_v }, .location = .{} };
    const body_form = x_sym;

    const args = [_]Form{ bindings_form, body_form };
    const out = try expandLet(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expect(out.data.list.len == 3);
    try testing.expectEqualStrings("let*", out.data.list[0].data.symbol.name);
}

test "expandWhen builds (if c (do body...) nil)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const cond_f = Form{ .data = .{ .boolean = true }, .location = .{} };
    const body_f = Form{ .data = .{ .integer = 42 }, .location = .{} };
    const args = [_]Form{ cond_f, body_f };

    const out = try expandWhen(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("if", out.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(usize, 4), out.data.list.len);
    try testing.expect(out.data.list[3].data == .nil);
}

test "expandThreadFirst produces (* (+ 1 2) 3) for (-> 1 (+ 2) (* 3))" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const one = Form{ .data = .{ .integer = 1 }, .location = .{} };
    const two = Form{ .data = .{ .integer = 2 }, .location = .{} };
    const three = Form{ .data = .{ .integer = 3 }, .location = .{} };

    // (+ 2)
    const plus_items = try arena.dupe(Form, &.{ sym("+", .{}), two });
    const plus_call = Form{ .data = .{ .list = plus_items }, .location = .{} };
    // (* 3)
    const mul_items = try arena.dupe(Form, &.{ sym("*", .{}), three });
    const mul_call = Form{ .data = .{ .list = mul_items }, .location = .{} };

    const args = [_]Form{ one, plus_call, mul_call };
    const out = try expandThreadFirst(arena, &fix.rt, &args, .{});

    // Outermost: (* (+ 1 2) 3)
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("*", out.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(usize, 3), out.data.list.len);
    // Second arg: 3 literal
    try testing.expectEqual(@as(i64, 3), out.data.list[2].data.integer);
    // First arg: (+ 1 2)
    const inner = out.data.list[1];
    try testing.expect(inner.data == .list);
    try testing.expectEqualStrings("+", inner.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), inner.data.list[1].data.integer);
    try testing.expectEqual(@as(i64, 2), inner.data.list[2].data.integer);
}

test "expandCond empty → nil; odd-arity → syntax error" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const empty = try expandCond(arena, &fix.rt, &.{}, .{});
    try testing.expect(empty.data == .nil);

    const single = [_]Form{Form{ .data = .{ .boolean = true }, .location = .{} }};
    const got = expandCond(arena, &fix.rt, &single, .{ .file = "<t>", .line = 1, .column = 0 });
    try testing.expectError(error.SyntaxError, got);
}

test "expandAnd / expandOr cover empty / single / multi" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const true_f = Form{ .data = .{ .boolean = true }, .location = .{} };

    // (and) -> true
    const a0 = try expandAnd(arena, &fix.rt, &.{}, .{});
    try testing.expect(a0.data == .boolean and a0.data.boolean);
    // (or) -> nil
    const o0 = try expandOr(arena, &fix.rt, &.{}, .{});
    try testing.expect(o0.data == .nil);
    // (and x) -> x
    const a1 = try expandAnd(arena, &fix.rt, &.{true_f}, .{});
    try testing.expect(a1.data == .boolean and a1.data.boolean);
    // (and x y) -> (let* [g x] (if g (and y) g))
    const a2 = try expandAnd(arena, &fix.rt, &.{ true_f, true_f }, .{});
    try testing.expectEqualStrings("let*", a2.data.list[0].data.symbol.name);
}
