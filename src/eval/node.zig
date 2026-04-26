//! Node — the analyser's typed AST.
//!
//! `Form` (`form.zig`) is the literal surface representation a Reader
//! produces. `Node` is the post-analysis tree where every symbol has
//! been resolved to a Var or a local slot index, and every special
//! form has its own struct so the backend can dispatch on it via
//! type-safe `switch`.
//!
//! ### Phase-2 scope (this file)
//!
//! - Literal: `constant` (lifted Form atom — nil / bool / int / float /
//!   string / keyword reified into a `Value` at analyse time)
//! - References: `local_ref` (let-bound; carries a slot index), `var_ref`
//!   (resolved `*const Var`)
//! - Special forms: `def`, `if`, `do`, `quote`, `fn*`, `let*`
//! - Expressions: `call` — generic invocation
//!
//! `loop` / `recur` / `set!` / `throw` / `try` arrive in Phase 3+.
//!
//! ### Memory ownership
//!
//! The Node tree lives in the Analyzer's per-eval arena (`runtime
//! /gc/arena.zig`). Child pointers all point inside the same arena so
//! lifetimes align — the whole tree is freed at once when the arena
//! is released. Nodes are **not** Values, so the Phase-5 GC does not
//! trace them; this is the structural reason map / vec literals lift
//! into `constant` Values rather than into Node sub-trees.

const std = @import("std");
const Value = @import("../runtime/value.zig").Value;
const SourceLocation = @import("../runtime/error.zig").SourceLocation;
const Var = @import("../runtime/env.zig").Var;

/// Analysed AST. `union(enum)` lets the backend `switch` exhaustively.
pub const Node = union(enum) {
    constant: ConstantNode,
    local_ref: LocalRef,
    var_ref: VarRef,
    def_node: DefNode,
    if_node: IfNode,
    do_node: DoNode,
    quote_node: QuoteNode,
    fn_node: FnNode,
    let_node: LetNode,
    call_node: CallNode,

    /// Source location of this Node. Returns the inner variant's `loc`
    /// — every variant carries one because Phase-2 errors must cite a
    /// position (ROADMAP P6).
    pub fn loc(self: Node) SourceLocation {
        return switch (self) {
            inline else => |n| n.loc,
        };
    }
};

/// A literal whose value is fixed at analyse time. The Form-atom →
/// Value lift happens in `analyzer.zig`.
pub const ConstantNode = struct {
    value: Value,
    loc: SourceLocation = .{},
};

/// `let`-bound or `fn*`-parameter reference. `index` is the slot
/// number fixed during analysis — the shared key between TreeWalk and
/// the future VM, so emitter / interpreter can both index a flat
/// locals array.
pub const LocalRef = struct {
    /// Original symbol name (kept for debug + error messages).
    name: []const u8,
    /// Slot index within the enclosing local environment.
    index: u16,
    loc: SourceLocation = .{},
};

/// Global Var reference — analyser has already resolved the pointer.
/// `Var.deref` is consulted at eval time so dynamic bindings still
/// take effect.
pub const VarRef = struct {
    var_ptr: *const Var,
    loc: SourceLocation = .{},
};

/// `(def name value)` (and `^:dynamic` / `^:macro` / `^:private`
/// variants once metadata reading lands).
pub const DefNode = struct {
    name: []const u8,
    value_expr: *const Node,
    /// Mirrors `env.zig`'s VarFlags — duplicated because the Node
    /// tree must not import the analyser's parsing context. The two
    /// will be unified once `^{...}` reader macros land in Phase 3+.
    is_dynamic: bool = false,
    is_macro: bool = false,
    is_private: bool = false,
    loc: SourceLocation = .{},
};

/// `(if cond then else)`. The else branch is optional in Clojure.
pub const IfNode = struct {
    cond: *const Node,
    then_branch: *const Node,
    else_branch: ?*const Node = null,
    loc: SourceLocation = .{},
};

/// `(do form1 form2 ...)` — evaluate in order, return the last value.
/// An empty do returns nil.
pub const DoNode = struct {
    forms: []const Node,
    loc: SourceLocation = .{},
};

/// `(quote x)` — the analyser has already reified `x` into a Value
/// via Form-atom lifting, so the backend just returns `quoted` at
/// eval time.
pub const QuoteNode = struct {
    quoted: Value,
    loc: SourceLocation = .{},
};

/// `(fn* [params] body)`. Variadic parameters are represented by
/// `has_rest = true`; the rest-parameter is the last entry in
/// `params` and is **not** counted in `arity`.
pub const FnNode = struct {
    arity: u16,
    has_rest: bool = false,
    /// Parameter names (debug + error frames). Length equals `arity`
    /// when `has_rest` is false, `arity + 1` otherwise.
    params: []const []const u8,
    body: *const Node,
    loc: SourceLocation = .{},
};

/// `(let* [n1 e1 n2 e2 ...] body)`. The body is a single Node — the
/// analyser lowers a multi-form let body into an enclosing `do_node`
/// so let_node stays simple.
pub const LetNode = struct {
    bindings: []const Binding,
    body: *const Node,
    loc: SourceLocation = .{},

    pub const Binding = struct {
        name: []const u8,
        /// Local slot index this binding occupies.
        index: u16,
        value_expr: *const Node,
    };
};

/// `(callee args...)` — generic invocation. `callee` is itself a
/// Node so a fn-literal can be invoked directly (`((fn* [x] x) 1)`).
pub const CallNode = struct {
    callee: *const Node,
    args: []const Node,
    loc: SourceLocation = .{},
};

// --- tests ---

const testing = std.testing;

test "Node.loc dispatches to inner variant" {
    const c = Node{ .constant = .{
        .value = .nil_val,
        .loc = .{ .line = 10, .column = 5 },
    } };
    try testing.expectEqual(@as(u32, 10), c.loc().line);
    try testing.expectEqual(@as(u16, 5), c.loc().column);
}

test "ConstantNode holds primitive Values" {
    const c1 = Node{ .constant = .{ .value = .nil_val } };
    const c2 = Node{ .constant = .{ .value = .true_val } };
    try testing.expectEqual(Value.nil_val, c1.constant.value);
    try testing.expectEqual(Value.true_val, c2.constant.value);
}

test "IfNode supports optional else branch" {
    const cond = Node{ .constant = .{ .value = .true_val } };
    const then_b = Node{ .constant = .{ .value = .nil_val } };
    const else_b = Node{ .constant = .{ .value = .false_val } };

    const with_else = Node{ .if_node = .{
        .cond = &cond,
        .then_branch = &then_b,
        .else_branch = &else_b,
    } };
    try testing.expect(with_else.if_node.else_branch != null);

    const no_else = Node{ .if_node = .{
        .cond = &cond,
        .then_branch = &then_b,
    } };
    try testing.expect(no_else.if_node.else_branch == null);
}

test "FnNode default has_rest is false" {
    const body = Node{ .constant = .{ .value = .nil_val } };
    const params = [_][]const u8{"x"};
    const fn_node = Node{ .fn_node = .{
        .arity = 1,
        .params = &params,
        .body = &body,
    } };
    try testing.expect(!fn_node.fn_node.has_rest);
    try testing.expectEqual(@as(u16, 1), fn_node.fn_node.arity);
}

test "DoNode accepts empty forms" {
    const empty = [_]Node{};
    const do_node = Node{ .do_node = .{ .forms = &empty } };
    try testing.expectEqual(@as(usize, 0), do_node.do_node.forms.len);
}

test "LetNode binding carries name / index / value_expr" {
    const expr = Node{ .constant = .{ .value = .true_val } };
    const body = Node{ .constant = .{ .value = .nil_val } };
    const bindings = [_]LetNode.Binding{
        .{ .name = "x", .index = 0, .value_expr = &expr },
    };
    const let_node = Node{ .let_node = .{
        .bindings = &bindings,
        .body = &body,
    } };
    try testing.expectEqualStrings("x", let_node.let_node.bindings[0].name);
    try testing.expectEqual(@as(u16, 0), let_node.let_node.bindings[0].index);
}

test "DefNode flag defaults are all false" {
    const v = Node{ .constant = .{ .value = .nil_val } };
    const d = DefNode{ .name = "x", .value_expr = &v };
    try testing.expect(!d.is_dynamic);
    try testing.expect(!d.is_macro);
    try testing.expect(!d.is_private);
}

test "QuoteNode stores a reified Value" {
    const q = Node{ .quote_node = .{ .quoted = .true_val } };
    try testing.expectEqual(Value.true_val, q.quote_node.quoted);
}

test "CallNode holds callee + arg list" {
    const callee = Node{ .constant = .{ .value = .nil_val } };
    const args = [_]Node{
        .{ .constant = .{ .value = .true_val } },
        .{ .constant = .{ .value = .false_val } },
    };
    const c = Node{ .call_node = .{
        .callee = &callee,
        .args = &args,
    } };
    try testing.expectEqual(@as(usize, 2), c.call_node.args.len);
}

test "LocalRef.index distinguishes slots with the same name" {
    const a = LocalRef{ .name = "x", .index = 0 };
    const b = LocalRef{ .name = "x", .index = 1 };
    try testing.expectEqualStrings(a.name, b.name);
    try testing.expect(a.index != b.index);
}
