//! TreeWalk evaluator — reference implementation for --compare mode.
//!
//! Directly interprets Node AST to Value without bytecode compilation.
//! Correct but slow; serves as semantics oracle for VM validation (SS9.2).
//!
//! Pipeline:
//!   Form (Reader) -> Node (Analyzer) -> Value (TreeWalk)

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("../../common/analyzer/node.zig");
const Node = node_mod.Node;
const FnNode = node_mod.FnNode;
const FnArity = node_mod.FnArity;
const value_mod = @import("../../common/value.zig");
const Value = value_mod.Value;
const env_mod = @import("../../common/env.zig");
const Env = env_mod.Env;

/// TreeWalk execution errors.
pub const TreeWalkError = error{
    UndefinedVar,
    TypeError,
    ArityError,
    DivisionByZero,
    UserException,
    OutOfMemory,
};

const MAX_LOCALS: usize = 256;

/// TreeWalk closure — captures fn node + local bindings at definition time.
pub const Closure = struct {
    fn_node: *const FnNode,
    captured_locals: []const Value,
    captured_count: usize,
};

/// Tree-walk interpreter — evaluates Node AST directly to Value.
pub const TreeWalk = struct {
    allocator: Allocator,
    env: ?*Env = null,
    /// Local binding stack. Grows with let/fn bindings.
    locals: [MAX_LOCALS]Value = undefined,
    local_count: usize = 0,
    /// Recur flag: set to true when recur is encountered.
    recur_pending: bool = false,
    /// Recur args buffer.
    recur_args: [MAX_LOCALS]Value = undefined,
    recur_arg_count: usize = 0,
    /// Exception value (set by throw).
    exception: ?Value = null,
    /// Allocated closures (for cleanup).
    allocated_closures: std.ArrayListUnmanaged(*Closure) = .empty,
    /// Allocated Fn wrappers (for cleanup).
    allocated_fns: std.ArrayListUnmanaged(*value_mod.Fn) = .empty,

    pub fn init(allocator: Allocator) TreeWalk {
        return .{ .allocator = allocator };
    }

    pub fn initWithEnv(allocator: Allocator, env: *Env) TreeWalk {
        return .{ .allocator = allocator, .env = env };
    }

    pub fn deinit(self: *TreeWalk) void {
        for (self.allocated_fns.items) |f| {
            self.allocator.destroy(f);
        }
        self.allocated_fns.deinit(self.allocator);
        for (self.allocated_closures.items) |c| {
            if (c.captured_locals.len > 0) {
                self.allocator.free(c.captured_locals);
            }
            self.allocator.destroy(c);
        }
        self.allocated_closures.deinit(self.allocator);
    }

    /// Evaluate a Node to a Value.
    pub fn run(self: *TreeWalk, n: *const Node) TreeWalkError!Value {
        return switch (n.*) {
            .constant => |val| val,
            .local_ref => |ref| {
                if (ref.idx < self.local_count) {
                    return self.locals[ref.idx];
                }
                return error.UndefinedVar;
            },
            .var_ref => |ref| self.resolveVar(ref.ns, ref.name),
            .if_node => |if_n| {
                const test_val = try self.run(if_n.test_node);
                if (test_val.isTruthy()) {
                    return self.run(if_n.then_node);
                } else if (if_n.else_node) |else_n| {
                    return self.run(else_n);
                } else {
                    return .nil;
                }
            },
            .do_node => |do_n| {
                if (do_n.statements.len == 0) return .nil;
                for (do_n.statements[0 .. do_n.statements.len - 1]) |stmt| {
                    _ = try self.run(stmt);
                }
                return self.run(do_n.statements[do_n.statements.len - 1]);
            },
            .let_node => |let_n| {
                const saved = self.local_count;
                for (let_n.bindings) |binding| {
                    const val = try self.run(binding.init);
                    if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
                    self.locals[self.local_count] = val;
                    self.local_count += 1;
                }
                const result = try self.run(let_n.body);
                self.local_count = saved;
                return result;
            },
            .fn_node => |fn_n| self.makeClosure(fn_n),
            .call_node => |call_n| self.runCall(call_n),
            .def_node => |def_n| self.runDef(def_n),
            .loop_node => |loop_n| self.runLoop(loop_n),
            .recur_node => |recur_n| self.runRecur(recur_n),
            .quote_node => |q| q.value,
            .throw_node => |throw_n| self.runThrow(throw_n),
            .try_node => |try_n| self.runTry(try_n),
        };
    }

    // --- Var resolution ---

    fn resolveVar(self: *TreeWalk, ns: ?[]const u8, name: []const u8) TreeWalkError!Value {
        // Check builtin arithmetic/comparison
        if (ns == null) {
            if (builtinLookup(name)) |val| return val;
        }

        // Resolve via Env
        if (self.env) |env| {
            if (env.current_ns) |cur_ns| {
                if (ns) |ns_name| {
                    if (cur_ns.resolveQualified(ns_name, name)) |v| return v.deref();
                } else {
                    if (cur_ns.resolve(name)) |v| return v.deref();
                }
            }
        }
        return error.UndefinedVar;
    }

    // --- Builtin sentinel values ---
    // Use keyword values as sentinel markers for builtin functions.

    fn builtinLookup(name: []const u8) ?Value {
        const builtins = [_][]const u8{ "+", "-", "*", "/", "<", ">", "<=", ">=" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) {
                return Value{ .keyword = .{ .ns = "__builtin__", .name = b } };
            }
        }
        return null;
    }

    fn isBuiltin(val: Value) bool {
        if (val != .keyword) return false;
        const kw = val.keyword;
        if (kw.ns) |ns| return std.mem.eql(u8, ns, "__builtin__");
        return false;
    }

    // --- Function call ---

    fn runCall(self: *TreeWalk, call_n: *const node_mod.CallNode) TreeWalkError!Value {
        const callee = try self.run(call_n.callee);

        // Builtin dispatch
        if (isBuiltin(callee)) {
            return self.callBuiltin(callee.keyword.name, call_n.args);
        }

        // Closure call
        if (callee != .fn_val) return error.TypeError;
        const fn_ptr = callee.fn_val;
        // fn_val.proto is actually *Closure for TreeWalk
        const closure: *const Closure = @ptrCast(@alignCast(fn_ptr.proto));

        // Evaluate args
        var arg_vals: [MAX_LOCALS]Value = undefined;
        for (call_n.args, 0..) |arg, i| {
            arg_vals[i] = try self.run(arg);
        }
        const arg_count = call_n.args.len;

        return self.callClosure(closure, arg_vals[0..arg_count]);
    }

    fn callClosure(self: *TreeWalk, closure: *const Closure, args: []const Value) TreeWalkError!Value {
        const fn_n = closure.fn_node;

        // Find matching arity
        const arity = findArity(fn_n.arities, args.len) orelse return error.ArityError;

        const saved = self.local_count;

        // Reset locals to captured state (fn body uses idx from 0)
        self.local_count = 0;

        // Restore captured locals at positions 0..captured_count
        for (closure.captured_locals[0..closure.captured_count]) |val| {
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = val;
            self.local_count += 1;
        }

        // Bind params after captured locals
        for (args) |val| {
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = val;
            self.local_count += 1;
        }

        const result = try self.run(arity.body);
        self.local_count = saved;
        return result;
    }

    fn findArity(arities: []const FnArity, arg_count: usize) ?*const FnArity {
        // Exact match first
        for (arities) |*a| {
            if (!a.variadic and a.params.len == arg_count) return a;
        }
        // Variadic match
        for (arities) |*a| {
            if (a.variadic and arg_count >= a.params.len - 1) return a;
        }
        return null;
    }

    // --- Closure creation ---

    fn makeClosure(self: *TreeWalk, fn_n: *const FnNode) TreeWalkError!Value {
        const closure = self.allocator.create(Closure) catch return error.OutOfMemory;
        const captured: []const Value = if (self.local_count > 0) blk: {
            const buf = self.allocator.alloc(Value, self.local_count) catch return error.OutOfMemory;
            @memcpy(buf, self.locals[0..self.local_count]);
            break :blk buf;
        } else &[_]Value{};

        closure.* = .{
            .fn_node = fn_n,
            .captured_locals = captured,
            .captured_count = self.local_count,
        };
        self.allocated_closures.append(self.allocator, closure) catch return error.OutOfMemory;

        // Wrap closure pointer as fn_val (reuse Fn struct with proto = *Closure)
        const fn_obj = self.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
        fn_obj.* = .{
            .proto = closure,
            .closure_bindings = null,
        };
        self.allocated_fns.append(self.allocator, fn_obj) catch return error.OutOfMemory;

        return Value{ .fn_val = fn_obj };
    }

    // --- Def ---

    fn runDef(self: *TreeWalk, def_n: *const node_mod.DefNode) TreeWalkError!Value {
        const env = self.env orelse return error.UndefinedVar;
        const ns = env.current_ns orelse return error.UndefinedVar;

        const v = ns.intern(def_n.sym_name) catch return error.OutOfMemory;

        if (def_n.init) |init_node| {
            const val = try self.run(init_node);
            v.bindRoot(val);
        }

        if (def_n.is_macro) v.setMacro(true);
        if (def_n.is_dynamic) v.dynamic = true;
        if (def_n.is_private) v.private = true;

        return Value{ .symbol = .{ .ns = ns.name, .name = v.sym.name } };
    }

    // --- Loop / Recur ---

    fn runLoop(self: *TreeWalk, loop_n: *const node_mod.LoopNode) TreeWalkError!Value {
        const saved = self.local_count;
        const binding_base = self.local_count;

        // Initial bindings
        for (loop_n.bindings) |binding| {
            const val = try self.run(binding.init);
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = val;
            self.local_count += 1;
        }

        while (true) {
            self.recur_pending = false;
            const result = self.run(loop_n.body) catch |e| {
                self.local_count = saved;
                return e;
            };

            if (self.recur_pending) {
                // Update bindings with recur args
                for (0..self.recur_arg_count) |i| {
                    self.locals[binding_base + i] = self.recur_args[i];
                }
                self.local_count = binding_base + loop_n.bindings.len;
                continue;
            }

            self.local_count = saved;
            return result;
        }
    }

    fn runRecur(self: *TreeWalk, recur_n: *const node_mod.RecurNode) TreeWalkError!Value {
        for (recur_n.args, 0..) |arg, i| {
            self.recur_args[i] = try self.run(arg);
        }
        self.recur_arg_count = recur_n.args.len;
        self.recur_pending = true;
        return .nil; // value is ignored; loop checks recur_pending
    }

    // --- Throw / Try ---

    fn runThrow(self: *TreeWalk, throw_n: *const node_mod.ThrowNode) TreeWalkError!Value {
        const val = try self.run(throw_n.expr);
        self.exception = val;
        return error.UserException;
    }

    fn runTry(self: *TreeWalk, try_n: *const node_mod.TryNode) TreeWalkError!Value {
        const result = self.run(try_n.body) catch |e| {
            if (e == error.UserException) {
                if (try_n.catch_clause) |catch_c| {
                    const ex_val = self.exception orelse .nil;
                    self.exception = null;

                    const saved = self.local_count;
                    if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
                    self.locals[self.local_count] = ex_val;
                    self.local_count += 1;

                    const catch_result = self.run(catch_c.body) catch |e2| {
                        self.local_count = saved;
                        if (try_n.finally_body) |finally| {
                            _ = self.run(finally) catch {};
                        }
                        return e2;
                    };
                    self.local_count = saved;

                    if (try_n.finally_body) |finally| {
                        _ = self.run(finally) catch {};
                    }
                    return catch_result;
                }
            }
            if (try_n.finally_body) |finally| {
                _ = self.run(finally) catch {};
            }
            return e;
        };

        if (try_n.finally_body) |finally| {
            _ = self.run(finally) catch {};
        }
        return result;
    }

    // --- Builtin arithmetic/comparison ---

    fn callBuiltin(self: *TreeWalk, name: []const u8, args: []const *Node) TreeWalkError!Value {
        if (args.len != 2) return error.ArityError;
        const a = try self.run(args[0]);
        const b = try self.run(args[1]);

        if (std.mem.eql(u8, name, "+")) return arith(a, b, .add);
        if (std.mem.eql(u8, name, "-")) return arith(a, b, .sub);
        if (std.mem.eql(u8, name, "*")) return arith(a, b, .mul);
        if (std.mem.eql(u8, name, "/")) return arithDiv(a, b);
        if (std.mem.eql(u8, name, "<")) return cmp(a, b, .lt);
        if (std.mem.eql(u8, name, ">")) return cmp(a, b, .gt);
        if (std.mem.eql(u8, name, "<=")) return cmp(a, b, .le);
        if (std.mem.eql(u8, name, ">=")) return cmp(a, b, .ge);
        return error.UndefinedVar;
    }

    const ArithOp = enum { add, sub, mul };

    fn arith(a: Value, b: Value, op: ArithOp) TreeWalkError!Value {
        // Both integer
        if (a == .integer and b == .integer) {
            return Value{ .integer = switch (op) {
                .add => a.integer + b.integer,
                .sub => a.integer - b.integer,
                .mul => a.integer * b.integer,
            } };
        }
        // Promote to float
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;
        return Value{ .float = switch (op) {
            .add => fa + fb,
            .sub => fa - fb,
            .mul => fa * fb,
        } };
    }

    fn arithDiv(a: Value, b: Value) TreeWalkError!Value {
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;
        if (fb == 0.0) return error.DivisionByZero;
        return Value{ .float = fa / fb };
    }

    const CmpOp = enum { lt, le, gt, ge };

    fn cmp(a: Value, b: Value, op: CmpOp) TreeWalkError!Value {
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;
        const result: bool = switch (op) {
            .lt => fa < fb,
            .le => fa <= fb,
            .gt => fa > fb,
            .ge => fa >= fb,
        };
        return Value{ .boolean = result };
    }

    fn numToFloat(val: Value) ?f64 {
        return switch (val) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }
};

// === Tests ===

test "TreeWalk constant nil" {
    var tw = TreeWalk.init(std.testing.allocator);
    const n = Node{ .constant = .nil };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value.nil, result);
}

test "TreeWalk constant integer" {
    var tw = TreeWalk.init(std.testing.allocator);
    const n = Node{ .constant = .{ .integer = 42 } };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "TreeWalk constant boolean" {
    var tw = TreeWalk.init(std.testing.allocator);
    const n = Node{ .constant = .{ .boolean = true } };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .boolean = true }, result);
}

test "TreeWalk if true branch" {
    var tw = TreeWalk.init(std.testing.allocator);
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
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 1 }, result);
}

test "TreeWalk if false branch" {
    var tw = TreeWalk.init(std.testing.allocator);
    var test_n = Node{ .constant = .{ .boolean = false } };
    var then_n = Node{ .constant = .{ .integer = 1 } };
    var else_n = Node{ .constant = .{ .integer = 2 } };
    var if_data = node_mod.IfNode{
        .test_node = &test_n,
        .then_node = &then_n,
        .else_node = &else_n,
        .source = .{},
    };
    const n = Node{ .if_node = &if_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 2 }, result);
}

test "TreeWalk if nil is falsy" {
    var tw = TreeWalk.init(std.testing.allocator);
    var test_n = Node{ .constant = .nil };
    var then_n = Node{ .constant = .{ .integer = 1 } };
    var if_data = node_mod.IfNode{
        .test_node = &test_n,
        .then_node = &then_n,
        .else_node = null,
        .source = .{},
    };
    const n = Node{ .if_node = &if_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value.nil, result);
}

test "TreeWalk do node" {
    var tw = TreeWalk.init(std.testing.allocator);
    var stmt1 = Node{ .constant = .{ .integer = 1 } };
    var stmt2 = Node{ .constant = .{ .integer = 2 } };
    var stmts = [_]*Node{ &stmt1, &stmt2 };
    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const n = Node{ .do_node = &do_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 2 }, result);
}

test "TreeWalk do empty" {
    var tw = TreeWalk.init(std.testing.allocator);
    var stmts = [_]*Node{};
    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const n = Node{ .do_node = &do_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value.nil, result);
}

test "TreeWalk let node" {
    // (let [x 10] x) => 10
    var tw = TreeWalk.init(std.testing.allocator);
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
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 10 }, result);
}

test "TreeWalk let two bindings" {
    // (let [x 10 y 20] y) => 20
    var tw = TreeWalk.init(std.testing.allocator);
    var init_x = Node{ .constant = .{ .integer = 10 } };
    var init_y = Node{ .constant = .{ .integer = 20 } };
    var body = Node{ .local_ref = .{ .name = "y", .idx = 1, .source = .{} } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_x },
        .{ .name = "y", .init = &init_y },
    };
    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const n = Node{ .let_node = &let_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 20 }, result);
}

test "TreeWalk let restores locals" {
    // After let completes, locals are restored
    var tw = TreeWalk.init(std.testing.allocator);
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
    _ = try tw.run(&n);

    // After let, local_count should be back to 0
    try std.testing.expectEqual(@as(usize, 0), tw.local_count);
}

test "TreeWalk quote node" {
    var tw = TreeWalk.init(std.testing.allocator);
    var quote_data = node_mod.QuoteNode{
        .value = .{ .symbol = .{ .ns = null, .name = "foo" } },
        .source = .{},
    };
    const n = Node{ .quote_node = &quote_data };
    const result = try tw.run(&n);
    try std.testing.expect(result.eql(.{ .symbol = .{ .ns = null, .name = "foo" } }));
}

test "TreeWalk constant string" {
    var tw = TreeWalk.init(std.testing.allocator);
    const n = Node{ .constant = .{ .string = "hello" } };
    const result = try tw.run(&n);
    try std.testing.expect(result.eql(.{ .string = "hello" }));
}

test "TreeWalk fn and call" {
    // ((fn [x] x) 42) => 42
    const allocator = std.testing.allocator;
    var tw = TreeWalk.init(allocator);
    defer tw.deinit();

    var body = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    const params = [_][]const u8{"x"};
    const arities = [_]FnArity{
        .{ .params = &params, .variadic = false, .body = &body },
    };
    var fn_data = FnNode{
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
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "TreeWalk fn with two params" {
    // ((fn [x y] y) 1 2) => 2
    const allocator = std.testing.allocator;
    var tw = TreeWalk.init(allocator);
    defer tw.deinit();

    var body = Node{ .local_ref = .{ .name = "y", .idx = 1, .source = .{} } };
    const params = [_][]const u8{ "x", "y" };
    const arities = [_]FnArity{
        .{ .params = &params, .variadic = false, .body = &body },
    };
    var fn_data = FnNode{
        .name = null,
        .arities = &arities,
        .source = .{},
    };
    var fn_node = Node{ .fn_node = &fn_data };
    var arg1 = Node{ .constant = .{ .integer = 1 } };
    var arg2 = Node{ .constant = .{ .integer = 2 } };
    var args = [_]*Node{ &arg1, &arg2 };
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &args,
        .source = .{},
    };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 2 }, result);
}

test "TreeWalk arithmetic builtins" {
    // (+ 3 4) => 7
    var tw = TreeWalk.init(std.testing.allocator);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 3 } };
    var a2 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 7 }, result);
}

test "TreeWalk subtraction" {
    var tw = TreeWalk.init(std.testing.allocator);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "-", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 10 } };
    var a2 = Node{ .constant = .{ .integer = 3 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 7 }, result);
}

test "TreeWalk multiplication" {
    var tw = TreeWalk.init(std.testing.allocator);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "*", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 6 } };
    var a2 = Node{ .constant = .{ .integer = 7 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "TreeWalk division returns float" {
    var tw = TreeWalk.init(std.testing.allocator);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "/", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 10 } };
    var a2 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .float = 2.5 }, result);
}

test "TreeWalk comparison" {
    // (< 1 2) => true
    var tw = TreeWalk.init(std.testing.allocator);
    var callee = Node{ .var_ref = .{ .ns = null, .name = "<", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 1 } };
    var a2 = Node{ .constant = .{ .integer = 2 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .boolean = true }, result);
}

test "TreeWalk def and var_ref" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    var tw = TreeWalk.initWithEnv(allocator, &env);
    defer tw.deinit();

    // (def x 42)
    var init_node = Node{ .constant = .{ .integer = 42 } };
    var def_data = node_mod.DefNode{
        .sym_name = "x",
        .init = &init_node,
        .source = .{},
    };
    const def_node = Node{ .def_node = &def_data };
    _ = try tw.run(&def_node);

    // x => 42
    const var_node = Node{ .var_ref = .{ .ns = null, .name = "x", .source = .{} } };
    const result = try tw.run(&var_node);
    try std.testing.expect(result.eql(.{ .integer = 42 }));
}

test "TreeWalk loop/recur" {
    // (loop [i 0] (if (< i 5) (recur (+ i 1)) i)) => 5
    var tw = TreeWalk.init(std.testing.allocator);

    // Build AST
    var i_ref = Node{ .local_ref = .{ .name = "i", .idx = 0, .source = .{} } };
    var const_5 = Node{ .constant = .{ .integer = 5 } };
    var lt_callee = Node{ .var_ref = .{ .ns = null, .name = "<", .source = .{} } };
    var lt_args = [_]*Node{ &i_ref, &const_5 };
    var lt_call_data = node_mod.CallNode{ .callee = &lt_callee, .args = &lt_args, .source = .{} };
    var test_node = Node{ .call_node = &lt_call_data };

    // recur: (recur (+ i 1))
    var i_ref2 = Node{ .local_ref = .{ .name = "i", .idx = 0, .source = .{} } };
    var const_1 = Node{ .constant = .{ .integer = 1 } };
    var add_callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var add_args = [_]*Node{ &i_ref2, &const_1 };
    var add_call_data = node_mod.CallNode{ .callee = &add_callee, .args = &add_args, .source = .{} };
    var add_node = Node{ .call_node = &add_call_data };
    var recur_args = [_]*Node{&add_node};
    var recur_data = node_mod.RecurNode{ .args = &recur_args, .source = .{} };
    var then_node = Node{ .recur_node = &recur_data };

    // if body
    var i_ref3 = Node{ .local_ref = .{ .name = "i", .idx = 0, .source = .{} } };
    var if_data = node_mod.IfNode{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &i_ref3,
        .source = .{},
    };
    var body = Node{ .if_node = &if_data };

    // loop
    var init_0 = Node{ .constant = .{ .integer = 0 } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "i", .init = &init_0 },
    };
    var loop_data = node_mod.LoopNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const n = Node{ .loop_node = &loop_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 5 }, result);
}

test "TreeWalk closure captures locals" {
    // (let [x 10] ((fn [y] (+ x y)) 5)) => 15
    const allocator = std.testing.allocator;
    var tw = TreeWalk.init(allocator);
    defer tw.deinit();

    // fn body: (+ x y)
    var x_ref = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var y_ref = Node{ .local_ref = .{ .name = "y", .idx = 1, .source = .{} } };
    var add_callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var add_args = [_]*Node{ &x_ref, &y_ref };
    var add_call_data = node_mod.CallNode{ .callee = &add_callee, .args = &add_args, .source = .{} };
    var fn_body = Node{ .call_node = &add_call_data };

    const params = [_][]const u8{"y"};
    const arities = [_]FnArity{
        .{ .params = &params, .variadic = false, .body = &fn_body },
    };
    var fn_data = FnNode{
        .name = null,
        .arities = &arities,
        .source = .{},
    };
    var fn_node = Node{ .fn_node = &fn_data };

    // ((fn [y] (+ x y)) 5)
    var arg_5 = Node{ .constant = .{ .integer = 5 } };
    var call_args = [_]*Node{&arg_5};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &call_args,
        .source = .{},
    };
    var call_node = Node{ .call_node = &call_data };

    // (let [x 10] ...)
    var init_10 = Node{ .constant = .{ .integer = 10 } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_10 },
    };
    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &call_node,
        .source = .{},
    };
    const n = Node{ .let_node = &let_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 15 }, result);
}

test "TreeWalk throw and try" {
    const allocator = std.testing.allocator;
    var tw = TreeWalk.init(allocator);

    // (try (throw "oops") (catch e e))
    var throw_expr = Node{ .constant = .{ .string = "oops" } };
    var throw_data = node_mod.ThrowNode{ .expr = &throw_expr, .source = .{} };
    var body = Node{ .throw_node = &throw_data };

    // catch: e is bound at the current local idx
    var catch_body = Node{ .local_ref = .{ .name = "e", .idx = 0, .source = .{} } };
    var try_data = node_mod.TryNode{
        .body = &body,
        .catch_clause = .{
            .binding_name = "e",
            .body = &catch_body,
        },
        .finally_body = null,
        .source = .{},
    };
    const n = Node{ .try_node = &try_data };
    const result = try tw.run(&n);
    try std.testing.expect(result.eql(.{ .string = "oops" }));
}

test "TreeWalk throw without catch propagates" {
    const allocator = std.testing.allocator;
    var tw = TreeWalk.init(allocator);

    var throw_expr = Node{ .constant = .{ .string = "error" } };
    var throw_data = node_mod.ThrowNode{ .expr = &throw_expr, .source = .{} };
    const n = Node{ .throw_node = &throw_data };
    try std.testing.expectError(error.UserException, tw.run(&n));
}
