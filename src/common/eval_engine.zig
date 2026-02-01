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

        var vm = if (self.env) |env|
            VM.initWithEnv(self.allocator, env)
        else
            VM.init(self.allocator);
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

test "EvalEngine compare arithmetic with registry Env" {
    // (+ 3 4) => 7 — builtins registered via registry
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 3 } };
    var a2 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 7 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 7 }, result.vm_value.?);
}

test "EvalEngine compare def+var_ref" {
    // (do (def x 42) x) => 42 in both backends
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    var engine = EvalEngine.init(alloc, &env);

    var init_val = Node{ .constant = .{ .integer = 42 } };
    var def_data = node_mod.DefNode{
        .sym_name = "x",
        .init = &init_val,
        .source = .{},
    };
    var def_node = Node{ .def_node = &def_data };
    var var_ref_node = Node{ .var_ref = .{ .ns = null, .name = "x", .source = .{} } };
    var stmts = [_]*Node{ &def_node, &var_ref_node };
    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const n = Node{ .do_node = &do_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.vm_value.?);
}

test "EvalEngine compare loop/recur" {
    // (loop [x 0] (if (< x 5) (recur (+ x 1)) x)) => 5
    var engine = EvalEngine.init(std.testing.allocator, null);

    var init_0 = Node{ .constant = .{ .integer = 0 } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_0 },
    };

    // test: (< x 5)
    var x_ref1 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var five = Node{ .constant = .{ .integer = 5 } };
    var lt_callee = Node{ .var_ref = .{ .ns = null, .name = "<", .source = .{} } };
    var lt_args = [_]*Node{ &x_ref1, &five };
    var lt_call = node_mod.CallNode{ .callee = &lt_callee, .args = &lt_args, .source = .{} };
    var test_node = Node{ .call_node = &lt_call };

    // then: (recur (+ x 1))
    var x_ref2 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var one = Node{ .constant = .{ .integer = 1 } };
    var add_callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var add_args = [_]*Node{ &x_ref2, &one };
    var add_call = node_mod.CallNode{ .callee = &add_callee, .args = &add_args, .source = .{} };
    var add_node = Node{ .call_node = &add_call };
    var recur_args = [_]*Node{&add_node};
    var recur_data = node_mod.RecurNode{ .args = &recur_args, .source = .{} };
    var then_node = Node{ .recur_node = &recur_data };

    // else: x
    var x_ref3 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };

    var if_data = node_mod.IfNode{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &x_ref3,
        .source = .{},
    };
    var body = Node{ .if_node = &if_data };

    var loop_data = node_mod.LoopNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const n = Node{ .loop_node = &loop_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.vm_value.?);
}

test "EvalEngine compare collection intrinsic (count)" {
    // (count [1 2 3]) => 3 — both backends via registry
    const registry = @import("builtin/registry.zig");
    const collections_mod = @import("collections.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var vec = collections_mod.PersistentVector{ .items = &items };
    var callee = Node{ .var_ref = .{ .ns = null, .name = "count", .source = .{} } };
    var arg = Node{ .constant = Value{ .vector = &vec } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.vm_value.?);
}

test "EvalEngine compare first on vector" {
    // (first [10 20 30]) => 10 — both backends
    const registry = @import("builtin/registry.zig");
    const collections_mod = @import("collections.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var vec = collections_mod.PersistentVector{ .items = &items };
    var callee = Node{ .var_ref = .{ .ns = null, .name = "first", .source = .{} } };
    var arg = Node{ .constant = Value{ .vector = &vec } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 10 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 10 }, result.vm_value.?);
}

test "EvalEngine compare nil? predicate" {
    // (nil? nil) => true — both backends via registry
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    var callee = Node{ .var_ref = .{ .ns = null, .name = "nil?", .source = .{} } };
    var arg = Node{ .constant = .nil };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .boolean = true }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .boolean = true }, result.vm_value.?);
}

test "EvalEngine compare str builtin" {
    // (str 1) => "1" — both backends via registry
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    var callee = Node{ .var_ref = .{ .ns = null, .name = "str", .source = .{} } };
    var arg = Node{ .constant = .{ .integer = 42 } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqualStrings("42", result.tw_value.?.string);
    try std.testing.expectEqualStrings("42", result.vm_value.?.string);
}

test "EvalEngine compare pr-str builtin" {
    // (pr-str "hello") => "\"hello\"" — both backends via registry
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    var callee = Node{ .var_ref = .{ .ns = null, .name = "pr-str", .source = .{} } };
    var arg = Node{ .constant = .{ .string = "hello" } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqualStrings("\"hello\"", result.tw_value.?.string);
    try std.testing.expectEqualStrings("\"hello\"", result.vm_value.?.string);
}

test "EvalEngine compare atom + deref" {
    // (deref (atom 42)) => 42 — both backends via registry
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    // Build: (atom 42)
    var atom_callee = Node{ .var_ref = .{ .ns = null, .name = "atom", .source = .{} } };
    var atom_arg = Node{ .constant = .{ .integer = 42 } };
    var atom_args = [_]*Node{&atom_arg};
    var atom_call_data = node_mod.CallNode{ .callee = &atom_callee, .args = &atom_args, .source = .{} };
    var atom_node = Node{ .call_node = &atom_call_data };

    // Build: (deref <atom-expr>)
    var deref_callee = Node{ .var_ref = .{ .ns = null, .name = "deref", .source = .{} } };
    var deref_args = [_]*Node{&atom_node};
    var deref_call_data = node_mod.CallNode{ .callee = &deref_callee, .args = &deref_args, .source = .{} };
    const n = Node{ .call_node = &deref_call_data };

    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 42 }, result.vm_value.?);
}

test "EvalEngine compare reset!" {
    // Test: (let [a (atom 0)] (reset! a 99) (deref a)) => 99
    // Simplified: just test (reset! (atom 0) 99) => 99
    const registry = @import("builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var engine = EvalEngine.init(alloc, &env);

    // Build: (atom 0)
    var atom_callee = Node{ .var_ref = .{ .ns = null, .name = "atom", .source = .{} } };
    var atom_arg = Node{ .constant = .{ .integer = 0 } };
    var atom_args = [_]*Node{&atom_arg};
    var atom_call_data = node_mod.CallNode{ .callee = &atom_callee, .args = &atom_args, .source = .{} };
    var atom_node = Node{ .call_node = &atom_call_data };

    // Build: (reset! <atom-expr> 99)
    var reset_callee = Node{ .var_ref = .{ .ns = null, .name = "reset!", .source = .{} } };
    var reset_val = Node{ .constant = .{ .integer = 99 } };
    var reset_args = [_]*Node{ &atom_node, &reset_val };
    var reset_call_data = node_mod.CallNode{ .callee = &reset_callee, .args = &reset_args, .source = .{} };
    const n = Node{ .call_node = &reset_call_data };

    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 99 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 99 }, result.vm_value.?);
}

test "EvalEngine compare variadic add 3 args" {
    // (+ 1 2 3) => 6 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 1 } };
    var a2 = Node{ .constant = .{ .integer = 2 } };
    var a3 = Node{ .constant = .{ .integer = 3 } };
    var args = [_]*Node{ &a1, &a2, &a3 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 6 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 6 }, result.vm_value.?);
}

test "EvalEngine compare variadic add 0 args" {
    // (+) => 0 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var args = [_]*Node{};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 0 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 0 }, result.vm_value.?);
}

test "EvalEngine compare variadic mul 0 args" {
    // (*) => 1 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "*", .source = .{} } };
    var args = [_]*Node{};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.vm_value.?);
}

test "EvalEngine compare variadic add 1 arg" {
    // (+ 5) => 5 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 5 } };
    var args = [_]*Node{&a1};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.vm_value.?);
}

test "EvalEngine compare variadic sub 1 arg (negation)" {
    // (- 5) => -5 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "-", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 5 } };
    var args = [_]*Node{&a1};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = -5 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = -5 }, result.vm_value.?);
}

test "EvalEngine compare variadic div 1 arg (reciprocal)" {
    // (/ 4) => 0.25 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "/", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{&a1};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .float = 0.25 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .float = 0.25 }, result.vm_value.?);
}

test "EvalEngine compare variadic mul 3 args" {
    // (* 2 3 4) => 24 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "*", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 2 } };
    var a2 = Node{ .constant = .{ .integer = 3 } };
    var a3 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2, &a3 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 24 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 24 }, result.vm_value.?);
}

test "EvalEngine compare variadic sub 3 args" {
    // (- 10 3 2) => 5 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "-", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 10 } };
    var a2 = Node{ .constant = .{ .integer = 3 } };
    var a3 = Node{ .constant = .{ .integer = 2 } };
    var args = [_]*Node{ &a1, &a2, &a3 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 5 }, result.vm_value.?);
}

test "EvalEngine compare variadic div 3 args" {
    // (/ 120 6 4) => 5.0 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "/", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 120 } };
    var a2 = Node{ .constant = .{ .integer = 6 } };
    var a3 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2, &a3 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .float = 5.0 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .float = 5.0 }, result.vm_value.?);
}

test "EvalEngine compare variadic add 5 args" {
    // (+ 1 2 3 4 5) => 15 in both backends
    var engine = EvalEngine.init(std.testing.allocator, null);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 1 } };
    var a2 = Node{ .constant = .{ .integer = 2 } };
    var a3 = Node{ .constant = .{ .integer = 3 } };
    var a4 = Node{ .constant = .{ .integer = 4 } };
    var a5 = Node{ .constant = .{ .integer = 5 } };
    var args = [_]*Node{ &a1, &a2, &a3, &a4, &a5 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = engine.compare(&n);
    try std.testing.expect(result.match);
    try std.testing.expectEqual(Value{ .integer = 15 }, result.tw_value.?);
    try std.testing.expectEqual(Value{ .integer = 15 }, result.vm_value.?);
}
