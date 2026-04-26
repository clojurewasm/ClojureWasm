//! TreeWalk — Phase-2 backend: evaluate the Node tree by recursive
//! descent.
//!
//! This is the simplest possible interpreter. Phase 4 adds a bytecode
//! VM, but TreeWalk stays in the tree afterwards: it's the reference
//! implementation Phase 8's `Evaluator.compare` cross-checks the VM
//! against (dual-backend verification, ROADMAP §4.4).
//!
//! ### Phase-2 scope (this commit)
//!
//! - Constants / locals / vars: trivial.
//! - Special forms: def, if, do, quote, fn*, let*.
//! - Function call: dispatched through `Runtime.vtable.callFn`, which
//!   `installVTable(rt)` populates with `treeWalkCall` from this file.
//! - Built-ins: `Value.builtin_fn` invoked directly via the
//!   `dispatch.BuiltinFn` signature.
//!
//! `loop*` / `recur` / macros / multi-arity / closures-over-locals are
//! deferred to Phase 3+.
//!
//! ### Function representation
//!
//! `Function` is a heap-allocated struct wrapped in a NaN-boxed
//! `.fn_val` Value. Phase-2 minimum: no closure capture — top-level
//! fns and any fn that only references global Vars work. Genuine
//! lexical closures (`(let* [x 1] (fn* [y] (+ x y)))`) need an
//! environment slot vector and land in Phase 3+.
//!
//! ### Locals
//!
//! Every call frame uses a fixed-size 256-slot stack array. The VM
//! (Phase 4) will tighten this to the analyser-known frame size.

const std = @import("std");
const Value = @import("../../runtime/value.zig").Value;
const HeapHeader = @import("../../runtime/value.zig").HeapHeader;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const error_mod = @import("../../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const node_mod = @import("../node.zig");
const Node = node_mod.Node;

/// Per-frame slot-array size. Generous so the analyser can lay out
/// `let*` chains without checking; the VM (Phase 4) will switch to a
/// frame-size known at analyse time.
pub const MAX_LOCALS: u16 = 256;

pub const EvalError = error{
    NotCallable,
    ArityMismatch,
    SlotOutOfRange,
    /// Phase-2 minimum: unhandled feature surface (string literal as
    /// expr, no current_ns at def-time, …). Phase 3+ removes these.
    NotImplemented,
    OutOfMemory,
};

// --- Function (heap object representing a Clojure fn) ---

/// Closure object emitted by `fn*`. Phase-2 does not capture outer
/// locals; the `body` pointer borrows from the analyser's per-eval
/// arena, so the Function lives only as long as that arena does.
pub const Function = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    arity: u16,
    has_rest: bool,
    /// Function body — borrowed from the analyser arena.
    body: *const Node,
    /// Parameter names (debug + error frames). Borrowed too.
    params: []const []const u8,
};

/// Heap-allocate a Function and wrap it in a NaN-boxed Value. Until
/// the Phase-5 GC arrives, register the allocation with
/// `rt.heap_objects` so `Runtime.deinit` frees it.
pub fn allocFunction(rt: *Runtime, fn_node: node_mod.FnNode) !Value {
    const f = try rt.gpa.create(Function);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .arity = fn_node.arity,
        .has_rest = fn_node.has_rest,
        .body = fn_node.body,
        .params = fn_node.params,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn freeFunction(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const f: *Function = @ptrCast(@alignCast(ptr));
    gpa.destroy(f);
}

// --- Top-level eval ---

/// Evaluate one Node into a Value. `locals` is the slot array owned
/// by the caller — typically a fixed 256-entry stack array.
pub fn eval(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    node: *const Node,
) anyerror!Value {
    return switch (node.*) {
        .constant => |n| n.value,
        .local_ref => |n| {
            if (n.index >= locals.len) return EvalError.SlotOutOfRange;
            return locals[n.index];
        },
        .var_ref => |n| n.var_ptr.deref(),
        .def_node => |n| try evalDef(rt, env, locals, n),
        .if_node => |n| try evalIf(rt, env, locals, n),
        .do_node => |n| try evalDo(rt, env, locals, n.forms),
        .quote_node => |n| n.quoted,
        .fn_node => |n| try allocFunction(rt, n),
        .let_node => |n| try evalLet(rt, env, locals, n),
        .call_node => |n| try evalCall(rt, env, locals, n),
    };
}

fn evalDef(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.DefNode) !Value {
    const v = try eval(rt, env, locals, n.value_expr);
    const ns = env.current_ns orelse return EvalError.NotImplemented;
    const var_ptr = try env.intern(ns, n.name, v);
    var_ptr.flags.dynamic = n.is_dynamic;
    var_ptr.flags.macro_ = n.is_macro;
    var_ptr.flags.private = n.is_private;
    return Value.encodeHeapPtr(.var_ref, var_ptr);
}

fn evalIf(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.IfNode) !Value {
    const cond = try eval(rt, env, locals, n.cond);
    if (cond.isTruthy()) {
        return eval(rt, env, locals, n.then_branch);
    }
    if (n.else_branch) |eb| {
        return eval(rt, env, locals, eb);
    }
    return .nil_val;
}

fn evalDo(rt: *Runtime, env: *Env, locals: []Value, forms: []const Node) !Value {
    var last: Value = .nil_val;
    for (forms) |*f| {
        last = try eval(rt, env, locals, f);
    }
    return last;
}

fn evalLet(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LetNode) !Value {
    for (n.bindings) |b| {
        if (b.index >= locals.len) return EvalError.SlotOutOfRange;
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    return eval(rt, env, locals, n.body);
}

fn evalCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.CallNode) !Value {
    const callee = try eval(rt, env, locals, n.callee);
    var args_buf: [MAX_LOCALS]Value = undefined;
    if (n.args.len > MAX_LOCALS) return EvalError.NotImplemented;
    for (n.args, 0..) |*a, i| {
        args_buf[i] = try eval(rt, env, locals, a);
    }
    const args = args_buf[0..n.args.len];
    if (rt.vtable) |vt| {
        return vt.callFn(rt, env, callee, args);
    }
    return EvalError.NotCallable;
}

// --- Backend's callFn (registered as rt.vtable.callFn) ---

/// `dispatch.CallFn` implementation. Dispatches on the callee's tag:
/// `.fn_val` evaluates the body; `.builtin_fn` calls the C function
/// directly.
pub fn treeWalkCall(
    rt: *Runtime,
    env: *Env,
    callee: Value,
    args: []const Value,
) anyerror!Value {
    return switch (callee.tag()) {
        .fn_val => callFunction(rt, env, callee, args),
        .builtin_fn => callBuiltin(rt, env, callee, args),
        else => EvalError.NotCallable,
    };
}

fn callFunction(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value) !Value {
    const f = fn_val.decodePtr(*Function);
    if (!f.has_rest) {
        if (args.len != f.arity) return EvalError.ArityMismatch;
    } else {
        if (args.len < f.arity) return EvalError.ArityMismatch;
    }
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    for (args[0..f.arity], 0..) |v, i| {
        locals[i] = v;
    }
    if (f.has_rest) {
        // Phase-2 stub: the rest parameter would normally be a list of
        // the trailing arguments. Building a list needs `cons` from
        // `runtime/collection/list.zig`, which lands at task 2.7 in
        // the form of registered primitives. For now, leave nil — no
        // Phase-2 test hits a `& rest` body that observes this.
        locals[f.arity] = .nil_val;
    }
    return eval(rt, env, &locals, f.body);
}

fn callBuiltin(rt: *Runtime, env: *Env, callee: Value, args: []const Value) !Value {
    // `.builtin_fn` carries the 48-bit fn pointer in the Value itself.
    const fn_ptr = callee.asBuiltinFn(dispatch.BuiltinFn);
    return fn_ptr(rt, env, args, .{});
}

// --- VTable installer ---

/// Populate `rt.vtable` with the TreeWalk callbacks. Call once at
/// startup, after `Runtime.init` and `Env.init`.
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &treeWalkCall,
        .valueTypeKey = &valueTypeKey,
        .expandMacro = &expandMacroStub,
    };
}

fn valueTypeKey(v: Value) []const u8 {
    return @tagName(v.tag());
}

fn expandMacroStub(rt: *Runtime, env: *Env, macro_val: Value, args: []const Value) anyerror!Value {
    _ = rt;
    _ = env;
    _ = macro_val;
    _ = args;
    // Phase-3 wires real macro expansion. Until then, any code that
    // hits this path (only happens if a Var.flags.macro_ is set, which
    // Phase-2 never does) gets a clean error rather than a UB ride.
    return EvalError.NotImplemented;
}

// --- tests ---

const testing = std.testing;
const Reader = @import("../reader.zig").Reader;
const analyze = @import("../analyzer.zig").analyze;

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
        installVTable(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn evalStr(self: *TestFixture, source: []const u8) !Value {
        var reader = Reader.init(self.arena.allocator(), source);
        const form = (try reader.read()) orelse return EvalError.NotImplemented;
        const node = try analyze(self.arena.allocator(), &self.rt, &self.env, null, form);
        var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
        return eval(&self.rt, &self.env, &locals, node);
    }
};

// Built-in `+` used by the Phase-2 exit-criterion smoke tests. Phase
// 2.7 / 2.8 land the proper version under `lang/primitive/math.zig`;
// inlining a minimal one here keeps this test-only and avoids the
// upward import (zone violation) into lang/.
fn builtinPlus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    var sum: i64 = 0;
    for (args) |v| {
        sum += switch (v.tag()) {
            .integer => @as(i64, v.asInteger()),
            else => return EvalError.NotImplemented,
        };
    }
    return Value.initInteger(sum);
}

test "Function is 8-byte aligned (NaN boxing safety)" {
    try testing.expectEqual(@as(usize, 8), @alignOf(Function));
}

test "eval atoms: nil / true / 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, try fix.evalStr("nil"));
    try testing.expectEqual(Value.true_val, try fix.evalStr("true"));
    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("42")).asInteger());
}

test "eval (if true 1 2) and (if false 1 2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 1), (try fix.evalStr("(if true 1 2)")).asInteger());
    try testing.expectEqual(@as(i48, 2), (try fix.evalStr("(if false 1 2)")).asInteger());
}

test "eval (if false 1) without else returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(Value.nil_val, try fix.evalStr("(if false 1)"));
}

test "eval (do 1 2 3) returns the last form" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(do 1 2 3)")).asInteger());
}

test "eval (let* [x 1 y 2] y)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(@as(i48, 2), (try fix.evalStr("(let* [x 1 y 2] y)")).asInteger());
}

test "eval (def x 42) creates a Var; subsequent x returns 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def x 42)");
    const user = fix.env.findNs("user").?;
    const v = user.resolve("x").?;
    try testing.expectEqual(@as(i48, 42), v.root.asInteger());

    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("x")).asInteger());
}

test "eval (quote nil) returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(Value.nil_val, try fix.evalStr("(quote nil)"));
}

test "eval (fn* [x] x) returns a callable .fn_val" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(fn* [x] x)");
    try testing.expect(r.tag() == .fn_val);
}

test "eval ((fn* [x] x) 41) → 41 (Phase-2 exit criterion 2/2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("((fn* [x] x) 41)");
    try testing.expectEqual(@as(i48, 41), r.asInteger());
}

test "eval (def id (fn* [x] x)) (id 7) → 7" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    try testing.expectEqual(@as(i48, 7), (try fix.evalStr("(id 7)")).asInteger());
}

test "eval calls a built-in registered through Env.intern" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus));

    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(+ 1 2)")).asInteger());
}

test "eval (let* [x 1] (+ x 2)) → 3 (Phase-2 exit criterion 1/2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus));

    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(let* [x 1] (+ x 2))")).asInteger());
}

test "eval ((fn* [x] (+ x 1)) 41) → 42 (Phase-2 exit criterion combined)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus));

    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("((fn* [x] (+ x 1)) 41)")).asInteger());
}

test "calling a non-callable Value yields NotCallable" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", Value.initInteger(7));
    try testing.expectError(EvalError.NotCallable, fix.evalStr("(x 1 2)"));
}

test "calling a fn with wrong arity yields ArityMismatch" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    try testing.expectError(EvalError.ArityMismatch, fix.evalStr("(id 1 2)"));
}
