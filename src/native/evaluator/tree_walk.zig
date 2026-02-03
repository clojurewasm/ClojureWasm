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
const bootstrap = @import("../../common/bootstrap.zig");

/// TreeWalk execution errors.
pub const TreeWalkError = error{
    UndefinedVar,
    TypeError,
    ArityError,
    DivisionByZero,
    UserException,
    OutOfMemory,
    StackOverflow,
};

const MAX_LOCALS: usize = 256;
const MAX_CALL_DEPTH: usize = 512;

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
    /// Current call depth (for stack overflow protection).
    call_depth: usize = 0,
    /// Exception value (set by throw).
    exception: ?Value = null,
    /// Allocated closures (for cleanup).
    allocated_closures: std.ArrayList(*Closure) = .empty,
    /// Allocated Fn wrappers (for cleanup).
    allocated_fns: std.ArrayList(*value_mod.Fn) = .empty,

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
            .defprotocol_node => |dp_n| self.runDefprotocol(dp_n),
            .extend_type_node => |et_n| self.runExtendType(et_n),
            .defmulti_node => |dm_n| self.runDefmulti(dm_n),
            .defmethod_node => |dm_n| self.runDefmethod(dm_n),
            .lazy_seq_node => |ls_n| self.runLazySeq(ls_n),
        };
    }

    // --- Var resolution ---

    fn resolveVar(self: *TreeWalk, ns: ?[]const u8, name: []const u8) TreeWalkError!Value {
        // Resolve via Env first (registry-registered builtins live here)
        if (self.env) |env| {
            if (env.current_ns) |cur_ns| {
                if (ns) |ns_name| {
                    if (cur_ns.resolveQualified(ns_name, name)) |v| {
                        return v.deref();
                    }
                } else {
                    if (cur_ns.resolve(name)) |v| {
                        return v.deref();
                    }
                }
            }
        }

        return error.UndefinedVar;
    }

    // --- Function call ---

    /// Call a function Value with pre-evaluated arguments.
    /// Used for macro expansion: Analyzer calls macro fn_val with Value args.
    pub fn callValue(self: *TreeWalk, callee: Value, args: []const Value) TreeWalkError!Value {
        return switch (callee) {
            .builtin_fn => |f| @errorCast(f(self.allocator, args)),
            .fn_val => |fn_ptr| {
                if (fn_ptr.kind == .bytecode) {
                    return @errorCast(bootstrap.callFnVal(self.allocator, callee, args));
                }
                const closure: *const Closure = @ptrCast(@alignCast(fn_ptr.proto));
                return self.callClosure(closure, callee, args);
            },
            .keyword => {
                // Keyword-as-function: (:key map) => (get map :key)
                if (args.len < 1 or args.len > 2) return error.ArityError;
                if (args[0] == .map) {
                    return args[0].map.get(callee) orelse
                        if (args.len == 2) args[1] else .nil;
                }
                return if (args.len == 2) args[1] else .nil;
            },
            .set => |set| {
                // Set-as-function: (#{:a :b} :a) => :a, (#{:a :b} :c) => nil
                if (args.len < 1 or args.len > 2) return error.ArityError;
                return if (set.contains(args[0])) args[0] else if (args.len == 2) args[1] else .nil;
            },
            else => return error.TypeError,
        };
    }

    fn runCall(self: *TreeWalk, call_n: *const node_mod.CallNode) TreeWalkError!Value {
        const callee = try self.run(call_n.callee);

        // Builtin function dispatch (runtime_fn via BuiltinFn pointer)
        if (callee == .builtin_fn) {
            return self.callBuiltinFn(callee.builtin_fn, call_n.args);
        }

        // Protocol function dispatch
        if (callee == .protocol_fn) {
            return self.callProtocolFn(callee.protocol_fn, call_n.args);
        }

        // Multimethod dispatch
        if (callee == .multi_fn) {
            return self.callMultiFn(callee.multi_fn, call_n.args);
        }

        // Keyword-as-function: (:key map) => (get map :key)
        if (callee == .keyword) {
            if (call_n.args.len < 1 or call_n.args.len > 2) return error.ArityError;
            const target = try self.run(call_n.args[0]);
            if (target == .map) {
                return target.map.get(callee) orelse
                    if (call_n.args.len == 2) try self.run(call_n.args[1]) else .nil;
            }
            return if (call_n.args.len == 2) try self.run(call_n.args[1]) else .nil;
        }

        // Set-as-function: (#{:a :b} :a) => :a
        if (callee == .set) {
            if (call_n.args.len < 1 or call_n.args.len > 2) return error.ArityError;
            const target = try self.run(call_n.args[0]);
            return if (callee.set.contains(target)) target else if (call_n.args.len == 2) try self.run(call_n.args[1]) else .nil;
        }

        // Closure call
        if (callee != .fn_val) return error.TypeError;
        const fn_ptr = callee.fn_val;

        // Evaluate args (heap-allocated to reduce stack frame size)
        const arg_count = call_n.args.len;
        const arg_vals = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
        defer self.allocator.free(arg_vals);
        for (call_n.args, 0..) |arg, i| {
            arg_vals[i] = try self.run(arg);
        }

        // Bytecode fn_val: dispatch to VM via unified callFnVal
        if (fn_ptr.kind == .bytecode) {
            return @errorCast(bootstrap.callFnVal(self.allocator, callee, arg_vals));
        }

        // TreeWalk closure
        const closure: *const Closure = @ptrCast(@alignCast(fn_ptr.proto));
        return self.callClosure(closure, callee, arg_vals);
    }

    fn callClosure(self: *TreeWalk, closure: *const Closure, callee_fn_val: Value, args: []const Value) TreeWalkError!Value {
        // Stack overflow protection
        if (self.call_depth >= MAX_CALL_DEPTH) return error.StackOverflow;
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const fn_n = closure.fn_node;

        // Find matching arity
        const arity = findArity(fn_n.arities, args.len) orelse return error.ArityError;

        // Save caller's local frame on heap (avoids stack overflow in deep recursion)
        const saved_count = self.local_count;
        const saved_locals = self.allocator.alloc(Value, saved_count) catch return error.OutOfMemory;
        defer self.allocator.free(saved_locals);
        @memcpy(saved_locals, self.locals[0..saved_count]);

        // Save recur state (full buffer — inner calls may change arg_count)
        const saved_recur_pending = self.recur_pending;
        const saved_recur_arg_count = self.recur_arg_count;
        const saved_recur_args = self.allocator.alloc(Value, MAX_LOCALS) catch return error.OutOfMemory;
        defer self.allocator.free(saved_recur_args);
        @memcpy(saved_recur_args, &self.recur_args);

        // Reset locals to captured state (fn body uses idx from 0)
        self.local_count = 0;

        // Restore captured locals at positions 0..captured_count
        for (closure.captured_locals[0..closure.captured_count]) |val| {
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = val;
            self.local_count += 1;
        }

        // Bind fn name for self-recursion (Analyzer allocates a local slot for it)
        // Use the caller's fn_val directly to preserve identity
        if (fn_n.name != null) {
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = callee_fn_val;
            self.local_count += 1;
        }

        // Track param base for fn-level recur rebinding (before binding params)
        const params_base = self.local_count;

        // Bind params after captured locals (and fn name)
        if (arity.variadic) {
            // Variadic: bind fixed params, collect rest into a list
            const fixed_count = arity.params.len - 1; // last param is rest
            for (args[0..fixed_count]) |val| {
                if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
                self.locals[self.local_count] = val;
                self.local_count += 1;
            }
            // Collect remaining args into a PersistentList
            const rest_args = args[fixed_count..];
            const rest_val: Value = if (rest_args.len == 0)
                .nil
            else blk: {
                const collections = @import("../../common/collections.zig");
                const items = self.allocator.alloc(Value, rest_args.len) catch return error.OutOfMemory;
                @memcpy(items, rest_args);
                const lst = self.allocator.create(collections.PersistentList) catch return error.OutOfMemory;
                lst.* = .{ .items = items };
                break :blk Value{ .list = lst };
            };
            if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
            self.locals[self.local_count] = rest_val;
            self.local_count += 1;
        } else {
            for (args) |val| {
                if (self.local_count >= MAX_LOCALS) return error.OutOfMemory;
                self.locals[self.local_count] = val;
                self.local_count += 1;
            }
        }

        const params_count = arity.params.len;

        // Execute body with fn-level recur support (like loop)
        while (true) {
            self.recur_pending = false;
            const result = self.run(arity.body) catch |e| {
                // Restore caller's local frame on error
                @memcpy(self.locals[0..saved_count], saved_locals);
                self.local_count = saved_count;
                self.recur_pending = saved_recur_pending;
                self.recur_arg_count = saved_recur_arg_count;
                @memcpy(&self.recur_args, saved_recur_args);
                return e;
            };

            if (self.recur_pending) {
                // Rebind params with recur args
                for (0..self.recur_arg_count) |i| {
                    self.locals[params_base + i] = self.recur_args[i];
                }
                self.local_count = params_base + params_count;
                continue;
            }

            // Restore caller's local frame
            @memcpy(self.locals[0..saved_count], saved_locals);
            self.local_count = saved_count;

            // Restore recur state
            self.recur_pending = saved_recur_pending;
            self.recur_arg_count = saved_recur_arg_count;
            @memcpy(&self.recur_args, saved_recur_args);

            return result;
        }
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
            .kind = .treewalk,
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

    fn callProtocolFn(self: *TreeWalk, pf: *const value_mod.ProtocolFn, arg_nodes: []const *Node) TreeWalkError!Value {
        // Evaluate all arguments
        const args = self.allocator.alloc(Value, arg_nodes.len) catch return error.OutOfMemory;
        for (arg_nodes, 0..) |arg_node, i| {
            args[i] = try self.run(arg_node);
        }

        // Dispatch on first arg's type
        if (args.len == 0) return error.ArityError;
        const type_key = valueTypeKey(args[0]);

        // Lookup in protocol impls
        const protocol = pf.protocol;
        const method_map_val = protocol.impls.get(.{ .string = type_key }) orelse return error.TypeError;
        if (method_map_val != .map) return error.TypeError;
        const method_map = method_map_val.map;

        // Lookup method in method map
        const fn_val = method_map.get(.{ .string = pf.method_name }) orelse return error.TypeError;

        // Call the impl function
        return self.callValue(fn_val, args);
    }

    // --- Protocols ---

    fn runDefprotocol(self: *TreeWalk, dp_n: *const node_mod.DefProtocolNode) TreeWalkError!Value {
        const env = self.env orelse return error.UndefinedVar;
        const ns = env.current_ns orelse return error.UndefinedVar;

        // Create Protocol
        const protocol = self.allocator.create(value_mod.Protocol) catch return error.OutOfMemory;
        const method_sigs = self.allocator.alloc(value_mod.MethodSig, dp_n.method_sigs.len) catch return error.OutOfMemory;
        for (dp_n.method_sigs, 0..) |sig, i| {
            method_sigs[i] = .{ .name = sig.name, .arity = sig.arity };
        }
        // Empty impls map
        const empty_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
        empty_map.* = .{ .entries = &.{} };
        protocol.* = .{
            .name = dp_n.name,
            .method_sigs = method_sigs,
            .impls = empty_map,
        };

        // Bind protocol name
        const proto_var = ns.intern(dp_n.name) catch return error.OutOfMemory;
        proto_var.bindRoot(.{ .protocol = protocol });

        // Bind each method as a ProtocolFn var
        for (dp_n.method_sigs) |sig| {
            const pf = self.allocator.create(value_mod.ProtocolFn) catch return error.OutOfMemory;
            pf.* = .{
                .protocol = protocol,
                .method_name = sig.name,
            };
            const method_var = ns.intern(sig.name) catch return error.OutOfMemory;
            method_var.bindRoot(.{ .protocol_fn = pf });
        }

        return Value{ .protocol = protocol };
    }

    fn runExtendType(self: *TreeWalk, et_n: *const node_mod.ExtendTypeNode) TreeWalkError!Value {
        const env = self.env orelse return error.UndefinedVar;
        const ns = env.current_ns orelse return error.UndefinedVar;

        // Resolve protocol
        const proto_var = ns.resolve(et_n.protocol_name) orelse return error.UndefinedVar;
        const proto_val = proto_var.deref();
        if (proto_val != .protocol) return error.TypeError;
        const protocol = proto_val.protocol;

        // Map type name to type key
        const type_key = mapTypeKey(et_n.type_name);

        // Build method map: {method_name -> fn_val}
        const method_count = et_n.methods.len;
        const entries = self.allocator.alloc(Value, method_count * 2) catch return error.OutOfMemory;
        for (et_n.methods, 0..) |method, i| {
            entries[i * 2] = .{ .string = method.name };
            entries[i * 2 + 1] = try self.makeClosure(method.fn_node);
        }
        const method_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
        method_map.* = .{ .entries = entries };

        // Add to protocol impls: assoc type_key -> method_map
        const old_impls = protocol.impls;
        const new_entries = self.allocator.alloc(Value, old_impls.entries.len + 2) catch return error.OutOfMemory;
        @memcpy(new_entries[0..old_impls.entries.len], old_impls.entries);
        new_entries[old_impls.entries.len] = .{ .string = type_key };
        new_entries[old_impls.entries.len + 1] = .{ .map = method_map };
        const new_impls = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
        new_impls.* = .{ .entries = new_entries };
        protocol.impls = new_impls;

        return .nil;
    }

    /// Map user-facing type name to internal type key.
    fn mapTypeKey(type_name: []const u8) []const u8 {
        if (std.mem.eql(u8, type_name, "String")) return "string";
        if (std.mem.eql(u8, type_name, "Integer") or std.mem.eql(u8, type_name, "Long")) return "integer";
        if (std.mem.eql(u8, type_name, "Double") or std.mem.eql(u8, type_name, "Float")) return "float";
        if (std.mem.eql(u8, type_name, "Boolean")) return "boolean";
        if (std.mem.eql(u8, type_name, "nil")) return "nil";
        if (std.mem.eql(u8, type_name, "Keyword")) return "keyword";
        if (std.mem.eql(u8, type_name, "Symbol")) return "symbol";
        if (std.mem.eql(u8, type_name, "PersistentList") or std.mem.eql(u8, type_name, "List")) return "list";
        if (std.mem.eql(u8, type_name, "PersistentVector") or std.mem.eql(u8, type_name, "Vector")) return "vector";
        if (std.mem.eql(u8, type_name, "PersistentArrayMap") or std.mem.eql(u8, type_name, "Map")) return "map";
        if (std.mem.eql(u8, type_name, "PersistentHashSet") or std.mem.eql(u8, type_name, "Set")) return "set";
        if (std.mem.eql(u8, type_name, "Atom")) return "atom";
        if (std.mem.eql(u8, type_name, "Volatile")) return "volatile";
        if (std.mem.eql(u8, type_name, "Pattern")) return "regex";
        // Default: use as-is (for custom record types)
        return type_name;
    }

    /// Get type key string for a runtime value.
    fn valueTypeKey(val: Value) []const u8 {
        return switch (val) {
            .nil => "nil",
            .boolean => "boolean",
            .integer => "integer",
            .float => "float",
            .char => "char",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .fn_val, .builtin_fn => "function",
            .atom => "atom",
            .volatile_ref => "volatile",
            .regex => "regex",
            .protocol => "protocol",
            .protocol_fn => "protocol_fn",
            .multi_fn => "multi_fn",
            .lazy_seq => "lazy_seq",
            .cons => "cons",
            .var_ref => "var",
            .reduced => "reduced",
        };
    }

    // --- Multimethods ---

    fn runDefmulti(self: *TreeWalk, dm_n: *const node_mod.DefMultiNode) TreeWalkError!Value {
        const env = self.env orelse return error.UndefinedVar;
        const ns = env.current_ns orelse return error.UndefinedVar;

        // Evaluate dispatch function
        const dispatch_fn = try self.run(dm_n.dispatch_fn);

        // Create MultiFn
        const mf = self.allocator.create(value_mod.MultiFn) catch return error.OutOfMemory;
        const empty_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
        empty_map.* = .{ .entries = &.{} };
        mf.* = .{
            .name = dm_n.name,
            .dispatch_fn = dispatch_fn,
            .methods = empty_map,
        };

        // Bind to var
        const v = ns.intern(dm_n.name) catch return error.OutOfMemory;
        v.bindRoot(.{ .multi_fn = mf });

        return Value{ .multi_fn = mf };
    }

    fn runDefmethod(self: *TreeWalk, dm_n: *const node_mod.DefMethodNode) TreeWalkError!Value {
        const env = self.env orelse return error.UndefinedVar;
        const ns = env.current_ns orelse return error.UndefinedVar;

        // Resolve the multimethod
        const mf_var = ns.resolve(dm_n.multi_name) orelse return error.UndefinedVar;
        const mf_val = mf_var.deref();
        if (mf_val != .multi_fn) return error.TypeError;
        const mf = mf_val.multi_fn;

        // Evaluate dispatch value
        const dispatch_val = try self.run(dm_n.dispatch_val);

        // Build method fn
        const method_fn = try self.makeClosure(dm_n.fn_node);

        // Add to methods map: assoc dispatch_val -> method_fn
        const old = mf.methods;
        const new_entries = self.allocator.alloc(Value, old.entries.len + 2) catch return error.OutOfMemory;
        @memcpy(new_entries[0..old.entries.len], old.entries);
        new_entries[old.entries.len] = dispatch_val;
        new_entries[old.entries.len + 1] = method_fn;
        const new_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
        new_map.* = .{ .entries = new_entries };
        mf.methods = new_map;

        return method_fn;
    }

    fn callMultiFn(self: *TreeWalk, mf: *const value_mod.MultiFn, arg_nodes: []const *Node) TreeWalkError!Value {
        // Evaluate all arguments
        const args = self.allocator.alloc(Value, arg_nodes.len) catch return error.OutOfMemory;
        for (arg_nodes, 0..) |arg_node, i| {
            args[i] = try self.run(arg_node);
        }

        // Call dispatch function on args
        const dispatch_val = try self.callValue(mf.dispatch_fn, args);

        // Lookup method by dispatch value
        const method_fn = mf.methods.get(dispatch_val) orelse blk: {
            // Try :default
            break :blk mf.methods.get(.{ .keyword = .{ .ns = null, .name = "default" } }) orelse
                return error.TypeError;
        };

        // Call the matched method
        return self.callValue(method_fn, args);
    }

    // --- Lazy Sequences ---

    fn runLazySeq(self: *TreeWalk, ls_n: *const node_mod.LazySeqNode) TreeWalkError!Value {
        // Create a closure from the body fn (captures current env)
        const thunk = try self.makeClosure(ls_n.body_fn);

        // Create LazySeq with thunk
        const ls = self.allocator.create(value_mod.LazySeq) catch return error.OutOfMemory;
        ls.* = .{
            .thunk = thunk,
            .realized = null,
        };
        return Value{ .lazy_seq = ls };
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

    // --- Builtin function dispatch (runtime_fn) ---

    const var_mod = @import("../../common/var.zig");

    fn callBuiltinFn(self: *TreeWalk, func: var_mod.BuiltinFn, arg_nodes: []const *Node) TreeWalkError!Value {
        // Evaluate all arguments (heap-allocated to reduce stack frame size)
        const arg_vals = self.allocator.alloc(Value, arg_nodes.len) catch return error.OutOfMemory;
        defer self.allocator.free(arg_vals);
        for (arg_nodes, 0..) |arg, i| {
            arg_vals[i] = try self.run(arg);
        }
        const result = func(self.allocator, arg_vals);
        if (result) |v| {
            return v;
        } else |e| {
            return @errorCast(e);
        }
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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

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
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);
    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
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

test "TreeWalk collection intrinsic via registry" {
    // (first [10 20 30]) => 10
    const registry = @import("../../common/builtin/registry.zig");
    const collections_mod = @import("../../common/collections.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var vec = collections_mod.PersistentVector{ .items = &items };
    var callee = Node{ .var_ref = .{ .ns = null, .name = "first", .source = .{} } };
    var arg = Node{ .constant = Value{ .vector = &vec } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 10 }, result);
}

test "TreeWalk count via registry" {
    // (count [1 2 3]) => 3
    const registry = @import("../../common/builtin/registry.zig");
    const collections_mod = @import("../../common/collections.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var tw = TreeWalk.initWithEnv(arena.allocator(), &env);
    defer tw.deinit();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var vec = collections_mod.PersistentVector{ .items = &items };
    var callee = Node{ .var_ref = .{ .ns = null, .name = "count", .source = .{} } };
    var arg = Node{ .constant = Value{ .vector = &vec } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 3 }, result);
}

test "TreeWalk arithmetic via registry-registered Env" {
    // (+ 3 4) => 7, resolved through Env with registered builtins
    const registry = @import("../../common/builtin/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();
    try registry.registerBuiltins(&env);

    var tw = TreeWalk.initWithEnv(std.testing.allocator, &env);
    defer tw.deinit();

    var callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var a1 = Node{ .constant = .{ .integer = 3 } };
    var a2 = Node{ .constant = .{ .integer = 4 } };
    var args = [_]*Node{ &a1, &a2 };
    var call_data = node_mod.CallNode{ .callee = &callee, .args = &args, .source = .{} };
    const n = Node{ .call_node = &call_data };
    const result = try tw.run(&n);
    try std.testing.expectEqual(Value{ .integer = 7 }, result);
}
