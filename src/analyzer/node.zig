// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Node type — Analyzer output: executable AST nodes.
//!
//! Three-phase architecture:
//!   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//!
//! Each Node variant represents a special form, function call, or literal.
//! The Analyzer transforms Form into Node; the VM/TreeWalk evaluates Node to Value.

const std = @import("std");
const Value = @import("../runtime/value.zig").Value;

// === Source tracking ===

/// Source location info for error reporting and stack traces.
pub const SourceInfo = struct {
    line: u32 = 0,
    column: u32 = 0,
    file: ?[]const u8 = null,
};

// === Node structs ===

// -- References --

/// Var reference node (resolved by analyzer).
/// In Phase 1c, var_ref stores the symbol name.
/// In Phase 2+, this will hold a *Var pointer.
pub const VarRefNode = struct {
    ns: ?[]const u8,
    name: []const u8,
    source: SourceInfo,
};

/// Local variable reference (let/fn binding).
pub const LocalRefNode = struct {
    name: []const u8,
    idx: u32, // index into bindings array
    source: SourceInfo,
};

// -- Control flow --

/// if special form: (if test then else?)
pub const IfNode = struct {
    test_node: *Node,
    then_node: *Node,
    else_node: ?*Node,
    source: SourceInfo,
};

/// do special form: (do stmt1 stmt2 ... result)
pub const DoNode = struct {
    statements: []const *Node,
    source: SourceInfo,
};

/// A single let/loop binding: name = init-expr
pub const LetBinding = struct {
    name: []const u8,
    init: *Node,
};

/// let special form: (let [bindings...] body)
pub const LetNode = struct {
    bindings: []const LetBinding,
    body: *Node,
    source: SourceInfo,
};

/// letfn special form: (letfn* [name1 fn1 name2 fn2 ...] body)
/// Like let but all names are pre-registered before any init is analyzed,
/// enabling mutual recursion between the bound functions.
pub const LetfnNode = struct {
    bindings: []const LetBinding,
    body: *Node,
    source: SourceInfo,
};

/// loop special form: (loop [bindings...] body)
pub const LoopNode = struct {
    bindings: []const LetBinding,
    body: *Node,
    source: SourceInfo,
};

/// recur special form: (recur args...)
pub const RecurNode = struct {
    args: []const *Node,
    source: SourceInfo,
};

// -- Functions --

/// A single arity of a multi-arity fn.
pub const FnArity = struct {
    params: []const []const u8,
    variadic: bool, // true if last param is & rest
    body: *Node,
};

/// fn special form: (fn name? ([params] body)+)
pub const FnNode = struct {
    name: ?[]const u8,
    arities: []const FnArity,
    source: SourceInfo,
};

/// Function call: (f arg1 arg2 ...)
pub const CallNode = struct {
    callee: *Node,
    args: []const *Node,
    source: SourceInfo,
};

// -- Definitions --

/// def / defmacro: (def name init?)
pub const DefNode = struct {
    sym_name: []const u8,
    init: ?*Node,
    is_macro: bool = false,
    is_dynamic: bool = false,
    is_private: bool = false,
    is_const: bool = false,
    doc: ?[]const u8 = null,
    arglists: ?[]const u8 = null,
    source: SourceInfo,
};

/// set!: (set! var-symbol expr)
pub const SetNode = struct {
    var_name: []const u8,
    expr: *Node,
    source: SourceInfo,
};

// -- Quote --

/// quote: (quote form)
pub const QuoteNode = struct {
    value: Value, // quoted form held as runtime Value
    source: SourceInfo,
};

// -- Exceptions --

/// throw: (throw expr)
pub const ThrowNode = struct {
    expr: *Node,
    source: SourceInfo,
};

/// catch clause within try
pub const CatchClause = struct {
    binding_name: []const u8, // exception binding variable
    body: *Node,
};

/// try special form: (try body (catch e handler) (finally cleanup))
pub const TryNode = struct {
    body: *Node,
    catch_clause: ?CatchClause,
    finally_body: ?*Node,
    source: SourceInfo,
};

/// defprotocol: (defprotocol Name (method [args]) ...)
pub const DefProtocolNode = struct {
    name: []const u8,
    method_sigs: []const MethodSigNode,
    source: SourceInfo,
};

/// Method signature in defprotocol.
pub const MethodSigNode = struct {
    name: []const u8,
    arity: u8, // including 'this'
};

/// extend-type: (extend-type TypeName Protocol (method [args] body) ...)
pub const ExtendTypeNode = struct {
    type_name: []const u8,
    protocol_name: []const u8,
    methods: []const ExtendMethodNode,
    source: SourceInfo,
};

/// Method implementation in extend-type.
pub const ExtendMethodNode = struct {
    name: []const u8,
    fn_node: *FnNode,
};

/// Protocol implementation block within a reify.
pub const ReifyProtocol = struct {
    protocol_name: []const u8,
    methods: []const ExtendMethodNode,
};

/// reify: (reify Protocol1 (method1 [args] body) ... Protocol2 ...)
pub const ReifyNode = struct {
    protocols: []const ReifyProtocol,
    source: SourceInfo,
};

// -- Multimethods --

/// defmulti: (defmulti name dispatch-fn & options)
pub const DefMultiNode = struct {
    name: []const u8,
    dispatch_fn: *Node,
    /// Optional custom hierarchy var reference (from :hierarchy option).
    hierarchy_node: ?*Node = null,
    source: SourceInfo,
};

/// lazy-seq: (lazy-seq body) — wraps body as a zero-arg fn thunk.
pub const LazySeqNode = struct {
    body_fn: *FnNode, // zero-arg fn wrapping the body
    source: SourceInfo,
};

/// defmethod: (defmethod name dispatch-val [args] body)
pub const DefMethodNode = struct {
    multi_name: []const u8,
    dispatch_val: *Node,
    fn_node: *FnNode,
    source: SourceInfo,
};

// -- Case dispatch --

/// case* special form: hash-based constant-time dispatch.
///
/// (case* expr shift mask default case-map switch-type test-type skip-check?)
///
/// The case macro pre-computes hash values; case* performs the lookup.
pub const CaseNode = struct {
    expr: *Node,
    shift: i32,
    mask: i32,
    default: *Node,
    clauses: []const CaseClause,
    test_type: TestType,
    skip_check: []const i64, // hashes where equality check is skipped
    source: SourceInfo,

    pub const TestType = enum { int_test, hash_equiv, hash_identity };
};

/// A single case clause: hash key → (test-value, then-expr).
pub const CaseClause = struct {
    hash_key: i64, // pre-computed hash (key in case-map)
    test_value: Value, // the actual test constant
    then_node: *Node, // the then expression
};

/// Constant literal with optional source location.
pub const ConstantNode = struct {
    value: Value,
    source: SourceInfo = .{},
};

// === Node tagged union ===

/// Executable AST node — output of the Analyzer.
pub const Node = union(enum) {
    // Literals
    constant: ConstantNode,

    // References
    var_ref: VarRefNode,
    local_ref: LocalRefNode,

    // Control flow
    if_node: *IfNode,
    do_node: *DoNode,
    let_node: *LetNode,
    letfn_node: *LetfnNode,
    loop_node: *LoopNode,
    recur_node: *RecurNode,

    // Functions
    fn_node: *FnNode,
    call_node: *CallNode,

    // Definitions
    def_node: *DefNode,

    // Assignment
    set_node: *SetNode,

    // Quote
    quote_node: *QuoteNode,

    // Exceptions
    throw_node: *ThrowNode,
    try_node: *TryNode,

    // Protocols
    defprotocol_node: *DefProtocolNode,
    extend_type_node: *ExtendTypeNode,
    reify_node: *ReifyNode,

    // Multimethods
    defmulti_node: *DefMultiNode,
    defmethod_node: *DefMethodNode,

    // Lazy sequences
    lazy_seq_node: *LazySeqNode,

    // Case dispatch
    case_node: *CaseNode,

    /// Get source location info for error reporting.
    pub fn source(self: Node) SourceInfo {
        return switch (self) {
            .constant => |c| c.source,
            .var_ref => |n| n.source,
            .local_ref => |n| n.source,
            .if_node => |n| n.source,
            .do_node => |n| n.source,
            .let_node => |n| n.source,
            .letfn_node => |n| n.source,
            .loop_node => |n| n.source,
            .recur_node => |n| n.source,
            .fn_node => |n| n.source,
            .call_node => |n| n.source,
            .def_node => |n| n.source,
            .set_node => |n| n.source,
            .quote_node => |n| n.source,
            .throw_node => |n| n.source,
            .try_node => |n| n.source,
            .defprotocol_node => |n| n.source,
            .extend_type_node => |n| n.source,
            .reify_node => |n| n.source,
            .defmulti_node => |n| n.source,
            .defmethod_node => |n| n.source,
            .lazy_seq_node => |n| n.source,
            .case_node => |n| n.source,
        };
    }

    /// Return the node kind name for debugging.
    pub fn kindName(self: Node) []const u8 {
        return switch (self) {
            .constant => |_| "constant",
            .var_ref => "var-ref",
            .local_ref => "local-ref",
            .if_node => "if",
            .do_node => "do",
            .let_node => "let",
            .letfn_node => "letfn",
            .loop_node => "loop",
            .recur_node => "recur",
            .fn_node => "fn",
            .call_node => "call",
            .def_node => "def",
            .set_node => "set!",
            .quote_node => "quote",
            .throw_node => "throw",
            .try_node => "try",
            .defprotocol_node => "defprotocol",
            .extend_type_node => "extend-type",
            .reify_node => "reify",
            .defmulti_node => "defmulti",
            .defmethod_node => "defmethod",
            .lazy_seq_node => "lazy-seq",
            .case_node => "case*",
        };
    }
};

// === Helper constructors ===

/// Create a constant node from a Value.
pub fn constantNode(val: Value) Node {
    return .{ .constant = .{ .value = val } };
}

/// nil constant node.
pub fn nilNode() Node {
    return .{ .constant = .{ .value = Value.nil_val } };
}

/// true constant node.
pub fn trueNode() Node {
    return .{ .constant = .{ .value = Value.true_val } };
}

/// false constant node.
pub fn falseNode() Node {
    return .{ .constant = .{ .value = Value.false_val } };
}

// === Tests ===

test "constantNode creates a constant node" {
    const node = constantNode(Value.initInteger(42));
    try std.testing.expectEqualStrings("constant", node.kindName());
    switch (node) {
        .constant => |c| {
            try std.testing.expect(c.value.eql(Value.initInteger(42)));
        },
        else => unreachable,
    }
}

test "nilNode creates nil constant" {
    const node = nilNode();
    switch (node) {
        .constant => |c| {
            try std.testing.expect(c.value.isNil());
        },
        else => unreachable,
    }
}

test "trueNode and falseNode" {
    const t = trueNode();
    const f = falseNode();
    switch (t) {
        .constant => |c| try std.testing.expect(c.value.isTruthy()),
        else => unreachable,
    }
    switch (f) {
        .constant => |c| try std.testing.expect(!c.value.isTruthy()),
        else => unreachable,
    }
}

test "IfNode with source info" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var test_cond = trueNode();
    var then_branch = constantNode(Value.initInteger(1));
    var else_branch = constantNode(Value.initInteger(2));

    const if_data = try allocator.create(IfNode);
    if_data.* = .{
        .test_node = &test_cond,
        .then_node = &then_branch,
        .else_node = &else_branch,
        .source = .{ .line = 5, .column = 3 },
    };

    const node = Node{ .if_node = if_data };
    try std.testing.expectEqualStrings("if", node.kindName());
    try std.testing.expectEqual(@as(u32, 5), node.source().line);
    try std.testing.expectEqual(@as(u32, 3), node.source().column);
}

test "DoNode with statements" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stmt1 = constantNode(Value.initInteger(1));
    var stmt2 = constantNode(Value.initInteger(2));
    const stmts = try allocator.alloc(*Node, 2);
    stmts[0] = &stmt1;
    stmts[1] = &stmt2;

    const do_data = try allocator.create(DoNode);
    do_data.* = .{
        .statements = stmts,
        .source = .{ .line = 10 },
    };

    const node = Node{ .do_node = do_data };
    try std.testing.expectEqualStrings("do", node.kindName());
    try std.testing.expectEqual(@as(usize, 2), do_data.statements.len);
}

test "CallNode with callee and args" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var callee = nilNode();
    var arg1 = constantNode(Value.initInteger(1));
    var arg2 = constantNode(Value.initInteger(2));

    const args = try allocator.alloc(*Node, 2);
    args[0] = &arg1;
    args[1] = &arg2;

    const call_data = try allocator.create(CallNode);
    call_data.* = .{
        .callee = &callee,
        .args = args,
        .source = .{},
    };

    const node = Node{ .call_node = call_data };
    try std.testing.expectEqualStrings("call", node.kindName());
    try std.testing.expectEqual(@as(usize, 2), call_data.args.len);
}

test "LetNode with bindings and body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var init1 = constantNode(Value.initInteger(10));
    var init2 = constantNode(Value.initInteger(20));
    var body = constantNode(Value.initInteger(30));

    const bindings = try allocator.alloc(LetBinding, 2);
    bindings[0] = .{ .name = "x", .init = &init1 };
    bindings[1] = .{ .name = "y", .init = &init2 };

    const let_data = try allocator.create(LetNode);
    let_data.* = .{
        .bindings = bindings,
        .body = &body,
        .source = .{ .line = 1, .column = 0 },
    };

    const node = Node{ .let_node = let_data };
    try std.testing.expectEqualStrings("let", node.kindName());
    try std.testing.expectEqual(@as(usize, 2), let_data.bindings.len);
    try std.testing.expectEqualStrings("x", let_data.bindings[0].name);
    try std.testing.expectEqualStrings("y", let_data.bindings[1].name);
}

test "FnNode with multiple arities" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var body1 = constantNode(Value.initInteger(1));
    var body2 = constantNode(Value.initInteger(2));

    const params1 = try allocator.alloc([]const u8, 1);
    params1[0] = "x";
    const params2 = try allocator.alloc([]const u8, 2);
    params2[0] = "x";
    params2[1] = "y";

    const arities = try allocator.alloc(FnArity, 2);
    arities[0] = .{ .params = params1, .variadic = false, .body = &body1 };
    arities[1] = .{ .params = params2, .variadic = false, .body = &body2 };

    const fn_data = try allocator.create(FnNode);
    fn_data.* = .{
        .name = "add",
        .arities = arities,
        .source = .{},
    };

    const node = Node{ .fn_node = fn_data };
    try std.testing.expectEqualStrings("fn", node.kindName());
    try std.testing.expectEqual(@as(usize, 2), fn_data.arities.len);
    try std.testing.expect(!fn_data.arities[0].variadic);
}

test "DefNode with metadata flags" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var init = constantNode(Value.initInteger(42));

    const def_data = try allocator.create(DefNode);
    def_data.* = .{
        .sym_name = "my-var",
        .init = &init,
        .is_dynamic = true,
        .doc = "A dynamic var",
        .source = .{ .line = 3 },
    };

    const node = Node{ .def_node = def_data };
    try std.testing.expectEqualStrings("def", node.kindName());
    try std.testing.expect(def_data.is_dynamic);
    try std.testing.expect(!def_data.is_macro);
    try std.testing.expect(!def_data.is_private);
    try std.testing.expectEqualStrings("A dynamic var", def_data.doc.?);
}

test "VarRefNode and LocalRefNode" {
    const var_node = Node{ .var_ref = .{
        .ns = "clojure.core",
        .name = "+",
        .source = .{ .line = 1 },
    } };
    try std.testing.expectEqualStrings("var-ref", var_node.kindName());
    try std.testing.expectEqual(@as(u32, 1), var_node.source().line);

    const local_node = Node{ .local_ref = .{
        .name = "x",
        .idx = 0,
        .source = .{ .line = 2 },
    } };
    try std.testing.expectEqualStrings("local-ref", local_node.kindName());
    try std.testing.expectEqual(@as(u32, 2), local_node.source().line);
}

test "QuoteNode holds a Value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const quote_data = try allocator.create(QuoteNode);
    quote_data.* = .{
        .value = Value.initSymbol(allocator, .{ .ns = null, .name = "foo" }),
        .source = .{},
    };

    const node = Node{ .quote_node = quote_data };
    try std.testing.expectEqualStrings("quote", node.kindName());
    switch (quote_data.value.tag()) {
        .symbol => try std.testing.expectEqualStrings("foo", quote_data.value.asSymbol().name),
        else => unreachable,
    }
}

test "TryNode with catch and finally" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var body = constantNode(Value.initInteger(1));
    var catch_body = constantNode(Value.initInteger(2));
    var finally_body = constantNode(Value.nil_val);

    const try_data = try allocator.create(TryNode);
    try_data.* = .{
        .body = &body,
        .catch_clause = .{
            .binding_name = "e",
            .body = &catch_body,
        },
        .finally_body = &finally_body,
        .source = .{ .line = 7 },
    };

    const node = Node{ .try_node = try_data };
    try std.testing.expectEqualStrings("try", node.kindName());
    try std.testing.expect(try_data.catch_clause != null);
    try std.testing.expectEqualStrings("e", try_data.catch_clause.?.binding_name);
    try std.testing.expect(try_data.finally_body != null);
}

test "LoopNode and RecurNode" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var init = constantNode(Value.initInteger(0));
    var body = constantNode(Value.initInteger(1));

    const bindings = try allocator.alloc(LetBinding, 1);
    bindings[0] = .{ .name = "i", .init = &init };

    const loop_data = try allocator.create(LoopNode);
    loop_data.* = .{
        .bindings = bindings,
        .body = &body,
        .source = .{ .line = 4 },
    };

    const loop_node = Node{ .loop_node = loop_data };
    try std.testing.expectEqualStrings("loop", loop_node.kindName());
    try std.testing.expectEqual(@as(u32, 4), loop_node.source().line);

    // recur
    var recur_arg = constantNode(Value.initInteger(1));
    const recur_args = try allocator.alloc(*Node, 1);
    recur_args[0] = &recur_arg;

    const recur_data = try allocator.create(RecurNode);
    recur_data.* = .{
        .args = recur_args,
        .source = .{},
    };

    const recur_node = Node{ .recur_node = recur_data };
    try std.testing.expectEqualStrings("recur", recur_node.kindName());
    try std.testing.expectEqual(@as(usize, 1), recur_data.args.len);
}

test "ThrowNode" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var expr = constantNode(Value.initString(allocator, "error!"));

    const throw_data = try allocator.create(ThrowNode);
    throw_data.* = .{
        .expr = &expr,
        .source = .{ .line = 9 },
    };

    const node = Node{ .throw_node = throw_data };
    try std.testing.expectEqualStrings("throw", node.kindName());
    try std.testing.expectEqual(@as(u32, 9), node.source().line);
}
