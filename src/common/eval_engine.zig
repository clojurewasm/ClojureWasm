//! EvalEngine — dual-backend evaluation with --compare mode.
//!
//! Runs both TreeWalk and VM on the same Node AST, compares results,
//! and reports mismatches. Key regression detection tool (SS9.2, D6).

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("analyzer/node.zig");
const Node = node_mod.Node;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Env = @import("env.zig").Env;
const Compiler = @import("bytecode/compiler.zig").Compiler;
const VM = @import("../native/vm/vm.zig").VM;
const TreeWalk = @import("../native/evaluator/tree_walk.zig").TreeWalk;

/// Evaluation backend selector.
pub const Backend = enum {
    tree_walk,
    vm,
    compare,
};

/// Result of a compare-mode evaluation.
pub const CompareResult = struct {
    tw_value: ?Value,
    vm_value: ?Value,
    tw_error: bool,
    vm_error: bool,
    match: bool,
};

/// Dual-backend evaluation engine.
pub const EvalEngine = struct {
    allocator: Allocator,
    env: ?*Env,

    pub fn init(allocator: Allocator, env: ?*Env) EvalEngine {
        return .{ .allocator = allocator, .env = env };
    }

    /// Run Node through TreeWalk evaluator.
    pub fn runTreeWalk(self: *EvalEngine, n: *const Node) !Value {
        var tw = if (self.env) |env|
            TreeWalk.initWithEnv(self.allocator, env)
        else
            TreeWalk.init(self.allocator);
        defer tw.deinit();
        return tw.run(n);
    }

    /// Run Node through Compiler + VM pipeline.
    pub fn runVM(self: *EvalEngine, n: *const Node) !Value {
        var compiler = Compiler.init(self.allocator);
        defer compiler.deinit();
        try compiler.compile(n);
        try compiler.chunk.emitOp(.ret);

        var vm = VM.init(self.allocator);
        defer vm.deinit();
        return vm.run(&compiler.chunk);
    }

    /// Run both backends and compare results.
    pub fn compare(self: *EvalEngine, n: *const Node) CompareResult {
        var result = CompareResult{
            .tw_value = null,
            .vm_value = null,
            .tw_error = false,
            .vm_error = false,
            .match = false,
        };

        // TreeWalk
        if (self.runTreeWalk(n)) |val| {
            result.tw_value = val;
        } else |_| {
            result.tw_error = true;
        }

        // VM
        if (self.runVM(n)) |val| {
            result.vm_value = val;
        } else |_| {
            result.vm_error = true;
        }

        // Both succeeded: compare values
        if (result.tw_value != null and result.vm_value != null) {
            result.match = result.tw_value.?.eql(result.vm_value.?);
        }
        // Both failed: also a match (same error behavior)
        else if (result.tw_error and result.vm_error) {
            result.match = true;
        }
        // One succeeded, one failed: mismatch
        // (default match = false)

        return result;
    }
};

// === Tests ===

test "EvalEngine runTreeWalk constant" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    const n = Node{ .constant = .{ .integer = 42 } };
    const result = try engine.runTreeWalk(&n);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "EvalEngine runVM constant" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    const n = Node{ .constant = .{ .integer = 42 } };
    const result = try engine.runVM(&n);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "EvalEngine compare matching constants" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    const n = Node{ .constant = .{ .integer = 42 } };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expect(!result.tw_error);
    try std.testing.expect(!result.vm_error);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.vm_value.?);
}

test "EvalEngine compare nil" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    const n = Node{ .constant = .nil };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
}

test "EvalEngine compare boolean" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    const t = Node{ .constant = .{ .boolean = true } };
    const result = engine.compare(&t);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .boolean = true }, result.tw_value.?);
}

test "EvalEngine compare if_node" {
    // (if true 1 2) => 1 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var test_n = Node{ .constant = .{ .boolean = true } };
    var then_n = Node{ .constant = .{ .integer = 1 } };
    var else_n = Node{ .constant = .{ .integer = 2 } };
    var if_data = node_mod.IfNode{
        .test_node = &test_n,
        .then_node = &then_n,
        .else_node = &else_n,
        .source = .{},
    };
    const n = Node{ .if_node = &if_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.tw_value.?);
}

test "EvalEngine compare do_node" {
    var engine = EvalEngine.init(std.testing.allocator, null);
    var stmt1 = Node{ .constant = .{ .integer = 1 } };
    var stmt2 = Node{ .constant = .{ .integer = 2 } };
    var stmts = [_]*Node{ &stmt1, &stmt2 };
    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const n = Node{ .do_node = &do_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 2 }, result.tw_value.?);
}

test "EvalEngine compare let_node" {
    // (let [x 10] x) => 10
    var engine = EvalEngine.init(std.testing.allocator, null);
    var init_val = Node{ .constant = .{ .integer = 10 } };
    var body = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_val },
    };
    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const n = Node{ .let_node = &let_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 10 }, result.tw_value.?);
}

test "EvalEngine compare arithmetic intrinsic matches" {
    // (+ 1 2) => 3 in both backends (compiler emits add opcode directly)
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 1 } };
    var a2 = Node{ .constant = .{ .integer = 2 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.vm_value.?);
}

test "EvalEngine compare division" {
    // (/ 10 4) => 2.5 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "/", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 10 } };
    var a2 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .float = 2.5 }, result.tw_value.?);
}

test "EvalEngine compare mod" {
    // (mod 7 3) => 1 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "mod", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 7 } };
    var a2 = Node{ .constant = .{ .integer = 3 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.tw_value.?);
}

test "EvalEngine compare equality" {
    // (= 1 1) => true
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "=", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 1 } };
    var a2 = Node{ .constant = .{ .integer = 1 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .boolean = true }, result.tw_value.?);
}

test "EvalEngine compare fn+call matches" {
    // ((fn [x] x) 42) => 42
    var engine = EvalEngine.init(std.testing.allocator, null);
    var body = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    const params = [_][]const u8{"x"};
    const arities = [_]node_mod.FnArity{
        .{ .params = &params, .variadic = false, .body = &body },
    };
    var fn_data = node_mod.FnNode{
        .name = null,
        .arities = &arities,
        .source = .{},
    };
    var fn_node = Node{ .fn_node = &fn_data };
    var arg = Node{ .constant = .{ .integer = 42 } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &args,
        .source = .{},
    };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.tw_value.?);
}
