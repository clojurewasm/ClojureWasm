//! Analyzer — Form → Node (semantic analysis).
//!
//! Reads the Form tree the Reader produced and emits a typed Node
//! tree the backend executes directly. Responsibilities:
//!
//!   1. **Symbol resolution** — every symbol becomes either a
//!      `local_ref` (slot index, for let-bound and fn parameters)
//!      or a `var_ref` (resolved `*const Var` from a Namespace).
//!      The lookup chain is: locals → current ns mappings → current
//!      ns refers, mirroring Clojure semantics.
//!   2. **Special-form syntax checking** — shapes like `(if 1 2 3 4)`
//!      become `SyntaxError` here so the backend's hot path does not
//!      have to validate at every step.
//!   3. **Slot allocation** — every local gets a `u16` index
//!      assigned during analysis, so the backend never hits a
//!      HashMap at eval time.
//!   4. **Macro expansion** — Phase 2 *does not* expand macros yet;
//!      Phase 3+ wires the analyser↔macro_transforms loop.
//!
//! ### Phase-2 scope
//!
//! - Atoms: nil / bool / int / float / keyword (interned at analyse time).
//! - Special forms: `def` / `if` / `do` / `quote` / `fn*` / `let*`.
//! - References: symbol → LocalRef / VarRef.
//! - **Not yet**: string literals as expression values, vector / map as
//!   expression values, syntax-quote, `loop*` / `recur`, `try` / `throw`,
//!   named `fn` (Phase 3+).
//!
//! ### Memory ownership
//!
//! Every Node lands in the caller-supplied `arena` allocator. A single
//! `analyze` call drops the whole sub-tree into the same arena, so
//! eval ends by freeing the arena in one shot — no per-Node free.

const std = @import("std");
const Form = @import("form.zig").Form;
const FormData = @import("form.zig").FormData;
const SymbolRef = @import("form.zig").SymbolRef;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Value = @import("../runtime/value.zig").Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const keyword = @import("../runtime/keyword.zig");
const SourceLocation = @import("../runtime/error.zig").SourceLocation;

/// Analyser errors. Phase 2 covers syntax + name resolution only.
pub const AnalyzeError = error{
    /// Wrong arity / argument kind for a special form.
    SyntaxError,
    /// Symbol resolved to neither a local nor a global Var.
    NameError,
    /// Phase-3+ feature not yet implemented (string literal as expr,
    /// quoted symbol/list, vector / map literal as expr, …).
    NotImplemented,
    OutOfMemory,
};

// --- Scope (local-binding chain consulted during analysis) ---

/// Lexical scope chain. `let*` and `fn*` push children; resolution
/// walks the chain linearly. `next_slot` is **inherited** from the
/// parent so the whole enclosing function shares one slot space —
/// the backend can then index a single flat locals array.
pub const Scope = struct {
    parent: ?*const Scope = null,
    bindings: std.StringHashMapUnmanaged(u16) = .empty,
    next_slot: u16 = 0,

    pub fn deinit(self: *Scope, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
    }

    /// Spawn a child scope. The child inherits `next_slot` so newly
    /// declared locals don't collide with the parent's slots.
    pub fn child(parent: *const Scope) Scope {
        return .{ .parent = parent, .next_slot = parent.next_slot };
    }

    /// Declare a new local; returns its slot number.
    pub fn declare(self: *Scope, alloc: std.mem.Allocator, name: []const u8) !u16 {
        const slot = self.next_slot;
        try self.bindings.put(alloc, name, slot);
        self.next_slot += 1;
        return slot;
    }

    /// Walk the chain looking for `name`; returns null when the
    /// caller should fall back to global resolution.
    pub fn lookup(self: *const Scope, name: []const u8) ?u16 {
        if (self.bindings.get(name)) |idx| return idx;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

// --- Special-form table ---

const SpecialFormKind = enum {
    def,
    if_form,
    do_form,
    quote_form,
    fn_star,
    let_star,
};

const SPECIAL_FORMS = std.StaticStringMap(SpecialFormKind).initComptime(.{
    .{ "def", .def },
    .{ "if", .if_form },
    .{ "do", .do_form },
    .{ "quote", .quote_form },
    .{ "fn*", .fn_star },
    .{ "let*", .let_star },
});

// --- Top-level entry ---

/// Analyse `form` and return the resulting Node tree. Top-level
/// callers pass `scope = null`; recursion threads a `Scope` chain
/// while inside a `let*` / `fn*`.
pub fn analyze(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    form: Form,
) AnalyzeError!*const Node {
    return switch (form.data) {
        .nil => try makeConstant(arena, .nil_val, form),
        .boolean => |b| try makeConstant(arena, if (b) .true_val else .false_val, form),
        .integer => |i| try makeConstant(arena, Value.initInteger(i), form),
        .float => |f| try makeConstant(arena, Value.initFloat(f), form),
        .keyword => |sym| {
            const v = try keyword.intern(rt, sym.ns, sym.name);
            return try makeConstant(arena, v, form);
        },
        .symbol => |sym| try analyzeSymbol(arena, env, scope, sym, form),
        .list => |items| try analyzeList(arena, rt, env, scope, items, form),
        // String / vector / map as expression values land in Phase 3+,
        // when they get a Heap representation. For now they're an
        // explicit NotImplemented — better than silently failing.
        .string, .vector, .map => return AnalyzeError.NotImplemented,
    };
}

// --- Helpers ---

fn makeConstant(arena: std.mem.Allocator, v: Value, form: Form) !*const Node {
    const n = try arena.create(Node);
    n.* = .{ .constant = .{ .value = v, .loc = form.location } };
    return n;
}

// --- Symbol resolution ---

fn analyzeSymbol(
    arena: std.mem.Allocator,
    env: *Env,
    scope: ?*const Scope,
    sym: SymbolRef,
    form: Form,
) AnalyzeError!*const Node {
    // Locals can only match unqualified symbols.
    if (sym.ns == null and scope != null) {
        if (scope.?.lookup(sym.name)) |slot| {
            const n = try arena.create(Node);
            n.* = .{ .local_ref = .{
                .name = sym.name,
                .index = slot,
                .loc = form.location,
            } };
            return n;
        }
    }
    // Global Var resolution.
    const ns = if (sym.ns) |ns_name|
        env.findNs(ns_name) orelse return AnalyzeError.NameError
    else
        env.current_ns orelse return AnalyzeError.NameError;
    const v_ptr = ns.resolve(sym.name) orelse return AnalyzeError.NameError;
    const n = try arena.create(Node);
    n.* = .{ .var_ref = .{ .var_ptr = v_ptr, .loc = form.location } };
    return n;
}

// --- List dispatch (special form vs call) ---

fn analyzeList(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len == 0) {
        // The empty-list literal `()` evaluates to () in Clojure, which
        // requires a heap List Value the analyser doesn't have yet
        // (Phase 5 collections). Defer cleanly.
        return AnalyzeError.NotImplemented;
    }
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(arena, rt, env, scope, kind, items, form);
            }
        }
    }
    return analyzeCall(arena, rt, env, scope, items, form);
}

fn analyzeCall(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    const callee = try analyze(arena, rt, env, scope, items[0]);
    var arg_nodes = try arena.alloc(Node, items.len - 1);
    for (items[1..], 0..) |arg_form, i| {
        const arg_node = try analyze(arena, rt, env, scope, arg_form);
        arg_nodes[i] = arg_node.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .call_node = .{
        .callee = callee,
        .args = arg_nodes,
        .loc = form.location,
    } };
    return n;
}

// --- Special forms ---

fn analyzeSpecial(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    kind: SpecialFormKind,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    return switch (kind) {
        .def => analyzeDef(arena, rt, env, scope, items, form),
        .if_form => analyzeIf(arena, rt, env, scope, items, form),
        .do_form => analyzeDo(arena, rt, env, scope, items, form),
        .quote_form => analyzeQuote(arena, rt, items, form),
        .fn_star => analyzeFnStar(arena, rt, env, scope, items, form),
        .let_star => analyzeLetStar(arena, rt, env, scope, items, form),
    };
}

fn analyzeDef(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    // (def name) | (def name value)
    if (items.len < 2 or items.len > 3) return AnalyzeError.SyntaxError;
    if (items[1].data != .symbol) return AnalyzeError.SyntaxError;
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null) return AnalyzeError.SyntaxError; // no qualified def
    const value_node = if (items.len == 3)
        try analyze(arena, rt, env, scope, items[2])
    else
        try makeConstant(arena, .nil_val, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .def_node = .{
        .name = name_sym.name,
        .value_expr = value_node,
        .loc = form.location,
    } };
    return n;
}

fn analyzeIf(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len < 3 or items.len > 4) return AnalyzeError.SyntaxError;
    const cond = try analyze(arena, rt, env, scope, items[1]);
    const then_b = try analyze(arena, rt, env, scope, items[2]);
    const else_b: ?*const Node = if (items.len == 4)
        try analyze(arena, rt, env, scope, items[3])
    else
        null;
    const n = try arena.create(Node);
    n.* = .{ .if_node = .{
        .cond = cond,
        .then_branch = then_b,
        .else_branch = else_b,
        .loc = form.location,
    } };
    return n;
}

fn analyzeDo(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    var forms = try arena.alloc(Node, items.len - 1);
    for (items[1..], 0..) |f, i| {
        const sub = try analyze(arena, rt, env, scope, f);
        forms[i] = sub.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = forms, .loc = form.location } };
    return n;
}

fn analyzeQuote(
    arena: std.mem.Allocator,
    rt: *Runtime,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2) return AnalyzeError.SyntaxError;
    const v = try formToValue(rt, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .quote_node = .{ .quoted = v, .loc = form.location } };
    return n;
}

/// Form atom → Value lift (used by `quote` only in Phase 2). Symbols,
/// strings, and collection literals need heap support that lands in
/// later phases.
fn formToValue(rt: *Runtime, form: Form) AnalyzeError!Value {
    return switch (form.data) {
        .nil => .nil_val,
        .boolean => |b| if (b) .true_val else .false_val,
        .integer => |i| Value.initInteger(i),
        .float => |f| Value.initFloat(f),
        .keyword => |sym| try keyword.intern(rt, sym.ns, sym.name),
        .symbol, .string, .list, .vector, .map => AnalyzeError.NotImplemented,
    };
}

fn analyzeFnStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    // (fn* [params] body...)
    if (items.len < 3) return AnalyzeError.SyntaxError;
    if (items[1].data != .vector) return AnalyzeError.SyntaxError;
    const params_form = items[1].data.vector;

    var has_rest = false;
    var arity: u16 = 0;
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(arena);

    var i: usize = 0;
    while (i < params_form.len) : (i += 1) {
        if (params_form[i].data != .symbol) return AnalyzeError.SyntaxError;
        const ps = params_form[i].data.symbol;
        if (ps.ns != null) return AnalyzeError.SyntaxError;
        if (std.mem.eql(u8, ps.name, "&")) {
            // `& rest`: the next symbol is the rest-parameter.
            if (i + 1 >= params_form.len) return AnalyzeError.SyntaxError;
            if (params_form[i + 1].data != .symbol) return AnalyzeError.SyntaxError;
            try param_names.append(arena, params_form[i + 1].data.symbol.name);
            has_rest = true;
            break;
        }
        try param_names.append(arena, ps.name);
        arity += 1;
    }

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);
    for (param_names.items) |name| {
        _ = try child_scope.declare(arena, name);
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form);

    const n = try arena.create(Node);
    n.* = .{ .fn_node = .{
        .arity = arity,
        .has_rest = has_rest,
        .params = try arena.dupe([]const u8, param_names.items),
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

/// Fold multiple body forms into a `do_node`; a single body form is
/// returned as-is. Used by `fn*` and `let*`.
fn analyzeBody(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: *const Scope,
    body_forms: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (body_forms.len == 1) {
        return analyze(arena, rt, env, scope, body_forms[0]);
    }
    var sub = try arena.alloc(Node, body_forms.len);
    for (body_forms, 0..) |f, i| {
        const n = try analyze(arena, rt, env, scope, f);
        sub[i] = n.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = sub, .loc = form.location } };
    return n;
}

fn analyzeLetStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    // (let* [k1 v1 k2 v2 ...] body...)
    if (items.len < 3) return AnalyzeError.SyntaxError;
    if (items[1].data != .vector) return AnalyzeError.SyntaxError;
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0) return AnalyzeError.SyntaxError;

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, binding_forms.len / 2);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol) return AnalyzeError.SyntaxError;
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null) return AnalyzeError.SyntaxError;
        // Analyse the value *before* declaring the name so each value
        // expression sees the pre-shadow scope (Clojure `let` semantics:
        // bindings are sequential; later bindings see earlier ones, but
        // each value is evaluated in the scope-before-its-own-binding).
        const value_node = try analyze(arena, rt, env, &child_scope, binding_forms[fi + 1]);
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{
            .name = name_sym.name,
            .index = slot,
            .value_expr = value_node,
        };
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form);

    const n = try arena.create(Node);
    n.* = .{ .let_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

// --- tests ---

const testing = std.testing;
const Reader = @import("reader.zig").Reader;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn analyzeStr(self: *TestFixture, source: []const u8) !*const Node {
        var reader = Reader.init(self.arena.allocator(), source);
        const form_opt = try reader.read();
        const form = form_opt orelse return AnalyzeError.SyntaxError;
        return analyze(self.arena.allocator(), &self.rt, &self.env, null, form);
    }
};

test "analyse atoms: nil / int / keyword interned consistently" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, (try fix.analyzeStr("nil")).constant.value);
    try testing.expect((try fix.analyzeStr("42")).constant.value.tag() == .integer);

    const k1 = try fix.analyzeStr(":foo");
    const k2 = try fix.analyzeStr(":foo");
    try testing.expectEqual(k1.constant.value, k2.constant.value);
}

test "unbound symbol → NameError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(AnalyzeError.NameError, fix.analyzeStr("undefined-symbol"));
}

test "resolved symbol → var_ref pointing at the right Var.root" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", .true_val);
    const n = try fix.analyzeStr("x");
    try testing.expect(n.* == .var_ref);
    try testing.expectEqual(Value.true_val, n.var_ref.var_ptr.root);
}

test "(if cond then else) shape; missing else stays null" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const with_else = try fix.analyzeStr("(if true 1 2)");
    try testing.expectEqual(Value.true_val, with_else.if_node.cond.constant.value);
    try testing.expect(with_else.if_node.else_branch != null);

    const no_else = try fix.analyzeStr("(if true 1)");
    try testing.expect(no_else.if_node.else_branch == null);
}

test "(do ...) gathers all sub-forms" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(do 1 2 3)");
    try testing.expectEqual(@as(usize, 3), n.do_node.forms.len);
}

test "(quote ...) lifts atoms; symbols still NotImplemented" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, (try fix.analyzeStr("(quote nil)")).quote_node.quoted);
    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr("(quote x)"));
}

test "(let* [x 1] x) — single binding + body local_ref" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(let* [x 1] x)");
    try testing.expectEqual(@as(usize, 1), n.let_node.bindings.len);
    try testing.expectEqualStrings("x", n.let_node.bindings[0].name);
    try testing.expectEqual(@as(u16, 0), n.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 0), n.let_node.body.local_ref.index);
}

test "(let* [x 1 y 2] (+ x y)) — slot indices increment; body is a call_node" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", .nil_val); // dummy so symbol resolves

    const n = try fix.analyzeStr("(let* [x 1 y 2] (+ x y))");
    try testing.expectEqual(@as(u16, 0), n.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 1), n.let_node.bindings[1].index);
    try testing.expectEqual(@as(usize, 2), n.let_node.body.call_node.args.len);
}

test "nested let* — inner binding shadows outer with new slot" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(let* [x 1] (let* [x 2] x))");
    const inner = n.let_node.body;
    try testing.expectEqual(@as(u16, 1), inner.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 1), inner.let_node.body.local_ref.index);
}

test "(fn* [x] x) — arity, params, body local_ref" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(fn* [x] x)");
    try testing.expectEqual(@as(u16, 1), n.fn_node.arity);
    try testing.expect(!n.fn_node.has_rest);
    try testing.expectEqualStrings("x", n.fn_node.params[0]);
    try testing.expectEqual(@as(u16, 0), n.fn_node.body.local_ref.index);
}

test "(fn* [x & rest] x) — has_rest is true; params include rest" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(fn* [x & rest] x)");
    try testing.expectEqual(@as(u16, 1), n.fn_node.arity);
    try testing.expect(n.fn_node.has_rest);
    try testing.expectEqual(@as(usize, 2), n.fn_node.params.len);
    try testing.expectEqualStrings("rest", n.fn_node.params[1]);
}

test "(def x 1) records name + value expr" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(def x 1)");
    try testing.expectEqualStrings("x", n.def_node.name);
    try testing.expect(n.def_node.value_expr.constant.value.tag() == .integer);
}

test "(if 1 2 3 4) — too many args is SyntaxError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(AnalyzeError.SyntaxError, fix.analyzeStr("(if 1 2 3 4)"));
}

test "call to a Var-resolved function lands as a call_node with var_ref callee" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "f", .nil_val);
    const n = try fix.analyzeStr("(f 1 2)");
    try testing.expect(n.call_node.callee.* == .var_ref);
    try testing.expectEqual(@as(usize, 2), n.call_node.args.len);
}

test "((fn* [x] x) 41) — direct fn-literal call (Phase-2 exit shape)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("((fn* [x] x) 41)");
    try testing.expect(n.* == .call_node);
    try testing.expect(n.call_node.callee.* == .fn_node);
    try testing.expectEqual(@as(usize, 1), n.call_node.args.len);
    try testing.expect(n.call_node.args[0].constant.value.tag() == .integer);
}
