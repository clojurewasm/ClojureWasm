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

/// TreeWalk error surface. Aliases `error_mod.Error` so calls to
/// `setErrorFmt` type-check; the backend still only **emits**
/// `error.TypeError` (non-callable callee), `error.ArityError`
/// (wrong number of args), `error.IndexError` (slot out of range),
/// `error.NotImplemented` (Phase-3+ feature stub), and
/// `error.OutOfMemory`. Mirrors the `ReadError` / `AnalyzeError`
/// treatment in §9.5/3.2 / 3.3.
pub const EvalError = error_mod.Error;

// --- §9.5/3.11 control-flow signals ---
//
// `recur` and `throw` use Zig errors purely as a non-local control
// channel; they carry no payload (errors don't in Zig). Per-thread
// scratch state holds the actual Values:
//
//   - `pending_recur_buf` / `pending_recur_len` — recur args, drained
//     by the matching `evalLoop` / `callFunction` frame.
//   - `dispatch.last_thrown_exception` — the thrown Value, drained by
//     the matching `evalTry`'s catch handler.
//
// Buffer is fixed-size (matches `MAX_LOCALS`) so recur cannot allocate
// during the unwind. Survey: `private/notes/phase3-3.11-survey.md`
// concluded this matches v1_ref's `error.RecurSignaled` idiom and
// satisfies ROADMAP P10 (Zig 0.16 idioms) without diverging.
threadlocal var pending_recur_buf: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
threadlocal var pending_recur_len: u16 = 0;

// --- Function (heap object representing a Clojure fn) ---

/// Closure object emitted by `fn*`. Phase 3.11 adds `slot_base` and
/// `closure_bindings` so a fn nested inside `let*` / `fn*` snapshots
/// its enclosing locals at allocation time and replays them on every
/// call. Top-level fns have `slot_base == 0` and `closure_bindings ==
/// null`. The `body` and `params` slices borrow from the analyser's
/// per-eval arena, so the Function lives only as long as that arena
/// does. `closure_bindings` is owned by the Function (separate
/// gpa allocation) and freed by `freeFunction`.
pub const Function = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    arity: u16,
    has_rest: bool,
    /// Number of locals the analyser allocated above this fn — these
    /// are the slots the closure snapshot fills, and the fn's params
    /// land at `[slot_base, slot_base + arity)`.
    slot_base: u16,
    /// Function body — borrowed from the analyser arena.
    body: *const Node,
    /// Parameter names (debug + error frames). Borrowed too.
    params: []const []const u8,
    /// Captured outer locals; null when the fn closes over nothing
    /// (top-level fn) so the common case stays a single null check
    /// rather than an empty-slice round-trip.
    closure_bindings: ?[]Value,
};

/// Heap-allocate a Function and wrap it in a NaN-boxed Value. The
/// caller's `locals` array supplies the snapshot for closure capture:
/// slots `[0, fn_node.slot_base)` are duplicated into a fresh
/// gpa-owned slice the Function will later replay on every call. Top
/// -level fns (`slot_base == 0`) skip the allocation entirely. Until
/// the Phase-5 GC arrives, register the allocation with
/// `rt.heap_objects` so `Runtime.deinit` frees it.
pub fn allocFunction(rt: *Runtime, fn_node: node_mod.FnNode, locals: []const Value) !Value {
    const closure: ?[]Value = if (fn_node.slot_base == 0)
        null
    else blk: {
        const slice = try rt.gpa.alloc(Value, fn_node.slot_base);
        @memcpy(slice, locals[0..fn_node.slot_base]);
        break :blk slice;
    };
    errdefer if (closure) |s| rt.gpa.free(s);

    const f = try rt.gpa.create(Function);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .arity = fn_node.arity,
        .has_rest = fn_node.has_rest,
        .slot_base = fn_node.slot_base,
        .body = fn_node.body,
        .params = fn_node.params,
        .closure_bindings = closure,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn freeFunction(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const f: *Function = @ptrCast(@alignCast(ptr));
    if (f.closure_bindings) |s| gpa.free(s);
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
            if (n.index >= locals.len)
                return error_mod.setErrorFmt(.eval, .index_error, n.loc, "Local slot {d} out of range (max {d})", .{ n.index, locals.len });
            return locals[n.index];
        },
        .var_ref => |n| n.var_ptr.deref(),
        .def_node => |n| try evalDef(rt, env, locals, n),
        .if_node => |n| try evalIf(rt, env, locals, n),
        .do_node => |n| try evalDo(rt, env, locals, n.forms),
        .quote_node => |n| n.quoted,
        .fn_node => |n| try allocFunction(rt, n, locals),
        .let_node => |n| try evalLet(rt, env, locals, n),
        .call_node => |n| try evalCall(rt, env, locals, n),
        .loop_node => |n| try evalLoop(rt, env, locals, n),
        .recur_node => |n| try evalRecur(rt, env, locals, n),
        .try_node => |n| try evalTry(rt, env, locals, n),
        .throw_node => |n| try evalThrow(rt, env, locals, n),
    };
}

fn evalDef(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.DefNode) !Value {
    const v = try eval(rt, env, locals, n.value_expr);
    const ns = env.current_ns orelse
        return error_mod.setErrorFmt(.eval, .internal_error, n.loc, "def: no current namespace", .{});
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
        if (b.index >= locals.len)
            return error_mod.setErrorFmt(.eval, .index_error, n.loc, "let* slot {d} out of range (max {d})", .{ b.index, locals.len });
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    return eval(rt, env, locals, n.body);
}

fn evalLoop(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LoopNode) anyerror!Value {
    // Initial bindings — same shape as `let*`, but every recur returns
    // here to rewrite the same slots and re-enter the body.
    for (n.bindings) |b| {
        if (b.index >= locals.len)
            return error_mod.setErrorFmt(.eval, .index_error, n.loc, "loop* slot {d} out of range (max {d})", .{ b.index, locals.len });
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    while (true) {
        if (eval(rt, env, locals, n.body)) |result| {
            return result;
        } else |err| switch (err) {
            error.RecurSignaled => {
                if (pending_recur_len != n.bindings.len)
                    return error_mod.setErrorFmt(.eval, .arity_error, n.loc, "recur to loop*: expected {d} arg(s), got {d}", .{ n.bindings.len, pending_recur_len });
                for (n.bindings, 0..) |b, i| {
                    locals[b.index] = pending_recur_buf[i];
                }
                pending_recur_len = 0;
            },
            else => return err,
        }
    }
}

fn evalRecur(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.RecurNode) anyerror!Value {
    if (n.args.len > pending_recur_buf.len)
        return error_mod.setErrorFmt(.eval, .not_implemented, n.loc, "recur with {d} args exceeds buffer ({d})", .{ n.args.len, pending_recur_buf.len });
    // Evaluate **all** args before mutating any slot — otherwise a
    // recur arg that referenced an earlier binding would see the
    // partially-rewritten frame. Stash them in the threadlocal scratch
    // so the matching loop frame can drain them once the unwind
    // returns control.
    for (n.args, 0..) |*a, i| {
        pending_recur_buf[i] = try eval(rt, env, locals, a);
    }
    pending_recur_len = @intCast(n.args.len);
    return error.RecurSignaled;
}

fn evalThrow(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.ThrowNode) anyerror!Value {
    const v = try eval(rt, env, locals, n.expr);
    dispatch.last_thrown_exception = v;
    return error.ThrownValue;
}

fn evalTry(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.TryNode) anyerror!Value {
    if (eval(rt, env, locals, n.body)) |result| {
        // Success path — finally still runs unconditionally. If
        // finally itself throws, that exception propagates and the
        // original result is dropped (matches Clojure JVM semantics).
        if (n.finally_body) |fb| {
            _ = try eval(rt, env, locals, fb);
        }
        return result;
    } else |err| switch (err) {
        error.ThrownValue => {
            const thrown = dispatch.last_thrown_exception orelse return error_mod.setErrorFmt(.eval, .internal_error, n.loc, "ThrownValue without last_thrown_exception", .{});
            // Walk catch clauses linearly — Phase 3 only matches
            // `ExceptionInfo` against `.ex_info`-tagged Values.
            for (n.catch_clauses) |cc| {
                if (catchMatches(cc.class_name, thrown)) {
                    dispatch.last_thrown_exception = null;
                    if (cc.binding_index >= locals.len)
                        return error_mod.setErrorFmt(.eval, .index_error, cc.loc, "catch slot {d} out of range (max {d})", .{ cc.binding_index, locals.len });
                    locals[cc.binding_index] = thrown;
                    const caught = eval(rt, env, locals, cc.body);
                    if (n.finally_body) |fb| {
                        _ = try eval(rt, env, locals, fb);
                    }
                    return caught;
                }
            }
            // No catch matched — finally runs, then we re-raise.
            if (n.finally_body) |fb| {
                _ = try eval(rt, env, locals, fb);
            }
            // last_thrown_exception is still populated; the outer
            // frame (or the CLI) sees the same Value.
            return error.ThrownValue;
        },
        else => {
            // Non-Clojure errors (OOM, internal_error, etc.) still run
            // finally so external resources get released, then bubble.
            if (n.finally_body) |fb| {
                _ = eval(rt, env, locals, fb) catch {};
            }
            return err;
        },
    }
}

fn catchMatches(class_name: []const u8, thrown: Value) bool {
    if (std.mem.eql(u8, class_name, "ExceptionInfo")) {
        return thrown.tag() == .ex_info;
    }
    // Phase 3.11 only recognises `ExceptionInfo`; other class symbols
    // were accepted at analyse time so user code stays readable, but
    // they never match a thrown Value until later phases extend the
    // type-name table.
    return false;
}

fn evalCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.CallNode) !Value {
    const callee = try eval(rt, env, locals, n.callee);
    var args_buf: [MAX_LOCALS]Value = undefined;
    if (n.args.len > MAX_LOCALS)
        return error_mod.setErrorFmt(.eval, .not_implemented, n.loc, "Call with {d} args exceeds Phase-2 MAX_LOCALS ({d})", .{ n.args.len, MAX_LOCALS });
    for (n.args, 0..) |*a, i| {
        args_buf[i] = try eval(rt, env, locals, a);
    }
    const args = args_buf[0..n.args.len];
    if (rt.vtable) |vt| {
        return vt.callFn(rt, env, callee, args, n.loc);
    }
    return error_mod.setErrorFmt(.eval, .internal_error, n.loc, "Runtime vtable not installed; cannot dispatch call", .{});
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
    loc: SourceLocation,
) anyerror!Value {
    return switch (callee.tag()) {
        .fn_val => callFunction(rt, env, callee, args, loc),
        .builtin_fn => callBuiltin(rt, env, callee, args, loc),
        else => |t| error_mod.setErrorFmt(.eval, .type_error, loc, "Cannot call value of type '{s}'", .{@tagName(t)}),
    };
}

fn callFunction(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) !Value {
    const f = fn_val.decodePtr(*Function);
    if (!f.has_rest) {
        if (args.len != f.arity)
            return error_mod.setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to fn (expected {d})", .{ args.len, f.arity });
    } else {
        if (args.len < f.arity)
            return error_mod.setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to fn (expected at least {d})", .{ args.len, f.arity });
    }
    if (@as(usize, f.slot_base) + f.arity + @intFromBool(f.has_rest) > MAX_LOCALS)
        return error_mod.setErrorFmt(.eval, .not_implemented, loc, "fn frame ({d}+{d}) exceeds MAX_LOCALS ({d})", .{ f.slot_base, f.arity, MAX_LOCALS });
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    // Replay captured outer locals into the fresh frame so LocalRefs
    // resolved against the analyser's enclosing scope still find their
    // values. Top-level fns skip this entirely.
    if (f.closure_bindings) |snap| {
        @memcpy(locals[0..snap.len], snap);
    }
    // Params land at `[slot_base, slot_base + arity)` — the slots the
    // analyser allocated when it descended into the fn body.
    for (args[0..f.arity], 0..) |v, i| {
        locals[f.slot_base + i] = v;
    }
    if (f.has_rest) {
        // Phase-2 stub: the rest parameter would normally be a list of
        // the trailing arguments. Building a list needs `cons` from
        // `runtime/collection/list.zig`, which lands at task 2.7 in
        // the form of registered primitives. For now, leave nil — no
        // Phase-2 test hits a `& rest` body that observes this.
        locals[f.slot_base + f.arity] = .nil_val;
    }
    return eval(rt, env, &locals, f.body);
}

fn callBuiltin(rt: *Runtime, env: *Env, callee: Value, args: []const Value, loc: SourceLocation) !Value {
    // `.builtin_fn` carries the 48-bit fn pointer in the Value itself.
    const fn_ptr = callee.asBuiltinFn(dispatch.BuiltinFn);
    return fn_ptr(rt, env, args, loc);
}

// --- VTable installer ---

/// Populate `rt.vtable` with the TreeWalk callbacks. Call once at
/// startup, after `Runtime.init` and `Env.init`. Macro expansion is
/// **not** installed here — it lives in `eval/macro_dispatch.zig` and
/// is threaded explicitly into `analyze`. See ADR 0001.
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &treeWalkCall,
        .valueTypeKey = &valueTypeKey,
    };
}

fn valueTypeKey(v: Value) []const u8 {
    return @tagName(v.tag());
}

// --- tests ---

const testing = std.testing;
const Reader = @import("../reader.zig").Reader;
const analyze = @import("../analyzer.zig").analyze;
const macro_dispatch = @import("../macro_dispatch.zig");

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    macro_table: macro_dispatch.Table,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.macro_table = macro_dispatch.Table.init(alloc);
        installVTable(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.macro_table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn evalStr(self: *TestFixture, source: []const u8) !Value {
        var reader = Reader.init(self.arena.allocator(), source);
        const form = (try reader.read()) orelse return error.NotImplemented;
        const node = try analyze(self.arena.allocator(), &self.rt, &self.env, null, form, &self.macro_table);
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
            else => return error.NotImplemented,
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
    try testing.expectError(error.TypeError, fix.evalStr("(x 1 2)"));
}

test "calling a fn with wrong arity yields ArityMismatch" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    try testing.expectError(error.ArityError, fix.evalStr("(id 1 2)"));
}

test "non-callable callee populates last_error with eval phase" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", Value.initInteger(7));

    error_mod.clearLastError();
    try testing.expectError(error.TypeError, fix.evalStr("(x 1 2)"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.type_error, info.kind);
    try testing.expectEqual(error_mod.Phase.eval, info.phase);
    try testing.expect(std.mem.find(u8, info.message, "Cannot call value") != null);
}

test "wrong arity populates last_error with eval phase" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    error_mod.clearLastError();
    try testing.expectError(error.ArityError, fix.evalStr("(id 1 2)"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.arity_error, info.kind);
    try testing.expectEqual(error_mod.Phase.eval, info.phase);
}

// --- §9.5/3.11 — loop* / recur ---

test "eval (loop* [x nil] (if x x (recur 42))) → 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(loop* [x nil] (if x x (recur 42)))");
    try testing.expectEqual(@as(i48, 42), r.asInteger());
}

test "eval (loop* [n 3 acc nil] (if acc acc (recur n n))) → 3" {
    // Two-binding loop: rebinds both slots; second iteration the
    // previously-nil acc is now `n` (3, truthy) and we return it.
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(loop* [n 3 acc nil] (if acc acc (recur n n)))");
    try testing.expectEqual(@as(i48, 3), r.asInteger());
}

test "recur outside loop / fn is rejected at analysis (already in 3.9)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectError(error.SyntaxError, fix.evalStr("(recur 1)"));
}

// --- §9.5/3.11 — throw / try / catch / finally ---

test "eval (throw 42) raises ThrownValue and stashes the Value" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    dispatch.last_thrown_exception = null;
    try testing.expectError(error.ThrownValue, fix.evalStr("(throw 42)"));
    const v = dispatch.last_thrown_exception orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i48, 42), v.asInteger());
    dispatch.last_thrown_exception = null;
}

test "eval try with no catch returns body value" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(try 7)");
    try testing.expectEqual(@as(i48, 7), r.asInteger());
}

test "eval try / catch ExceptionInfo binds the thrown ex-info" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Register `ex-info` so the catch path has a real ex_info Value to
    // match against. Phase 3.10 lives in `lang/primitive/error.zig`;
    // the Node tree imports nothing from `lang/`, but tests are
    // exempt from the zone gate so we can set up a minimal binding
    // here without dragging registerAll in.
    const error_prim = @import("../../lang/primitive/error.zig");
    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "ex-info", Value.initBuiltinFn(&error_prim.exInfo));

    const r = try fix.evalStr(
        "(try (throw (ex-info \"boom\" 0)) (catch ExceptionInfo e e))",
    );
    try testing.expect(r.tag() == .ex_info);
}

test "eval try / finally runs finally on success" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Use `def` from inside finally so we can observe the side effect.
    _ = try fix.evalStr("(try 1 (finally (def *side* 42)))");
    const user = fix.env.findNs("user").?;
    const v = user.resolve("*side*").?;
    try testing.expectEqual(@as(i48, 42), v.root.asInteger());
}

test "eval try / finally runs finally then rethrows" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    dispatch.last_thrown_exception = null;
    try testing.expectError(
        error.ThrownValue,
        fix.evalStr("(try (throw 7) (finally (def *side2* 99)))"),
    );
    const user = fix.env.findNs("user").?;
    const v = user.resolve("*side2*").?;
    try testing.expectEqual(@as(i48, 99), v.root.asInteger());
    const thrown = dispatch.last_thrown_exception orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i48, 7), thrown.asInteger());
    dispatch.last_thrown_exception = null;
}

// --- §9.5/3.11 — fn* closure capture ---

test "eval ((fn* [x] (fn* [y] x)) 3) returns a closure capturing x" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const inner = try fix.evalStr("((fn* [x] (fn* [y] x)) 3)");
    try testing.expect(inner.tag() == .fn_val);
}

test "eval (((fn* [x] (fn* [y] (+ x y))) 3) 4) → 7 (lexical closure)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus));

    const r = try fix.evalStr("(((fn* [x] (fn* [y] (+ x y))) 3) 4)");
    try testing.expectEqual(@as(i48, 7), r.asInteger());
}

test "eval (let* [x 5] ((fn* [y] (+ x y)) 6)) → 11 (closure over let)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus));

    const r = try fix.evalStr("(let* [x 5] ((fn* [y] (+ x y)) 6))");
    try testing.expectEqual(@as(i48, 11), r.asInteger());
}
