//! Layer-0 → Layer-1+ dispatch types.
//!
//! Phase 1's `runtime/error.zig` carried `BuiltinFn` as `(args, loc)
//! Error!Value`. Phase 2 widens the signature to `(rt, env, args, loc)`
//! so that built-ins can:
//!   - reach interners / GC / vtable via `*Runtime`,
//!   - perform namespace operations via `*Env`,
//!   - report errors with a `SourceLocation`.
//!
//! `BuiltinFn` therefore moves here in Phase 2; the Phase-1 alias in
//! `error.zig` will be retired once 2.7 (TreeWalk) starts wiring real
//! built-ins. Until then both signatures coexist — `error.zig`'s
//! version is still legal Zig, just not what the analyzer or backend
//! talk to.
//!
//! Layer 0 declares only **types**; the concrete function pointers
//! land at startup, when Layer 1 (TreeWalk in §9.4 task 2.6) calls
//! `installVTable(rt, ...)`. While `Runtime.vtable == null`, `callFn`
//! must not be invoked — this is structurally enforced because the
//! only callers (built-ins) get registered in Phase 2.6+ and not before.
//!
//! Why not `pub var` for the vtable? Because then tests cannot inject
//! a mock backend, and two Runtimes cannot carry different backends.
//! `Runtime.vtable: ?VTable` solves both.
//!
//! ### Why no `expandMacro` here
//!
//! Macro expansion is **not** a Layer-0 concern. Earlier sketches put
//! `expandMacro` on this VTable, but Phase 3.7 surfaced two problems:
//! (1) macros operate on Forms, which are a Layer-1 concept that
//! `runtime/` cannot reference; (2) macros are backend-agnostic, so
//! routing them through the same vtable as `callFn` (which is
//! backend-installed) misnames the responsibility. The macro path
//! therefore lives in `eval/macro_dispatch.zig` (Layer 1) and is
//! threaded explicitly into `analyze`. See ADR 0001.

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const td_mod = @import("type_descriptor.zig");
const method_table = @import("dispatch/method_table.zig");
const error_catalog = @import("error/catalog.zig");

pub const CallSite = method_table.CallSite;

/// Phase-2 built-in signature. All `lang/primitive/*.zig` functions
/// have this shape.
pub const BuiltinFn = *const fn (
    rt: *Runtime,
    env: *Env,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value;

/// Backend-implemented dispatcher for any callable Value (`fn_val`,
/// `builtin_fn`, `multi_fn`, `keyword`-as-function, etc.). The TreeWalk
/// backend (Phase 2.6) supplies the concrete implementation. `loc` is
/// the call-site location so primitives can attach it to any error
/// they raise via `setErrorFmt`.
pub const CallFn = *const fn (
    rt: *Runtime,
    env: *Env,
    fn_val: Value,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value;

/// Returns a human-readable type name for `(type x)` and error
/// messages. Filled in by the backend so it can dispatch over its own
/// heap shape (e.g. distinguish two record kinds with the same
/// HeapTag).
pub const ValueTypeKeyFn = *const fn (val: Value) []const u8;

/// VM backend hook: evaluate a compiled bytecode chunk in the current
/// frame. Installed by `vm.installVTable` and consulted by
/// `tree_walk.callFunction` when the callee's `Function.bytecode` is
/// non-null. `null` ⇒ the tree-walk fn body is evaluated instead.
///
/// `chunk` is `*const anyopaque` so the Layer-0 vtable does not import
/// the Layer-1 `BytecodeChunk` type (per `zone_deps.md`). The VM
/// backend casts back to the concrete pointer at its end.
pub const EvalChunkFn = *const fn (
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const anyopaque,
) anyerror!Value;

/// Layer-0 → Layer-1+ dispatch table. Stored as a field on `Runtime`,
/// not as a `pub var`, so multiple Runtimes can carry independent
/// backends (parallel tests, multi-tenant nREPL, mock injection).
///
/// Macro expansion is intentionally **not** here — see the module-level
/// comment and ADR 0001.
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
    evalChunk: ?EvalChunkFn = null,
};

/// ADR-0008 protocol dispatch ABI (amendment 1 + amendment 3).
/// Wraps `CallSite.lookupWithCache` + the `protocol_generation`
/// invalidation guard, then routes through `vtable.callFn` on the
/// installed method body Value. Raises `protocol_no_satisfies` when
/// no MethodEntry exists on the receiver's descriptor chain, or
/// when the receiver is not a `typed_instance` (per-Tag default
/// descriptor table is a Phase 7+ extension).
///
/// `cs` is the per-call-site cache slot (analyzer-arena owned via
/// MethodCallNode in row 7.6+; tests inject directly). `protocol` /
/// `method` are arena/static strings used by `lookupWithCache`'s
/// re-validation. `args` is the method's argument list (does NOT
/// include receiver; impls extract it via the analyzer-time bound
/// receiver-slot if needed).
///
/// Per ADR-0008 amendment 3 (cycle 6.6), the body now reads
/// `MethodEntry.method_val: Value` and dispatches via
/// `rt.vtable.callFn`. The prior `?*const anyopaque` raw cast path
/// is retired — convergence with row 7.2 multimethod's
/// `vtable.callFn` routing closes the protocol-vs-multimethod
/// dispatch divergence that amendment 1 left open.
pub fn dispatch(
    rt: *Runtime,
    env: *Env,
    cs: *CallSite,
    receiver: Value,
    protocol_name: []const u8,
    method_name: []const u8,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value {
    // Resolve receiver's TypeDescriptor: typed_instance carries its
    // own; native Tag receivers consult the per-Tag default registry
    // (cycle 8.5 — Runtime.nativeDescriptor). The fallback raises
    // protocol_no_satisfies when allocation fails OR when no method
    // is registered for `(td, protocol, method)`.
    const td: *const td_mod.TypeDescriptor = if (receiver.tag() == .typed_instance) blk: {
        const inst = receiver.decodePtr(*const td_mod.TypedInstance);
        break :blk inst.descriptor;
    } else if (receiver.tag() == .reified_instance) blk: {
        // Row 7.5 cycle 2 (ADR-0039): ReifiedInstance carries its
        // anonymous descriptor at the same offset-8 position; the
        // dispatch resolution is structurally identical to
        // typed_instance.
        const inst = receiver.decodePtr(*const td_mod.ReifiedInstance);
        break :blk inst.descriptor;
    } else try rt.nativeDescriptor(receiver.tag());
    const me = cs.lookupWithCache(td, protocol_name, method_name, rt.protocol_generation) orelse {
        return error_catalog.raise(.protocol_no_satisfies, loc, .{
            .protocol = protocol_name,
            .method = method_name,
            .type_name = td.fqcn orelse "<anonymous>",
        });
    };
    if (me.method_val.tag() == .nil) return error_catalog.raise(.feature_not_supported, loc, .{
        .name = "protocol method with nil method_val (declare-only)",
    });
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, me.method_val, args, loc);
}

// --- threadlocal call-scoped state ---

/// The Env currently being evaluated. Set on call entry, cleared on
/// exit. Strictly redundant in most paths because `BuiltinFn` already
/// receives `env`, but needed in low-level callbacks (e.g. GC root
/// walks) where `env` isn't otherwise in scope.
pub threadlocal var current_env: ?*Env = null;

/// Last `(throw ...)`'d exception Value, used to bridge VM ↔ TreeWalk
/// error flow. Wired actively from Phase 3 (`(throw)` / `(catch)`).
pub threadlocal var last_thrown_exception: ?Value = null;

// --- tests ---

const testing = std.testing;

fn mockCallFn(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = fn_val;
    _ = args;
    _ = loc;
    return .true_val;
}

fn mockValueTypeKey(val: Value) []const u8 {
    _ = val;
    return "mock";
}

fn dummyBuiltin(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = args;
    _ = loc;
    return .nil_val;
}

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "Runtime.vtable defaults to null" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expect(fix.rt.vtable == null);
}

test "VTable can be constructed and stored on Runtime" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    fix.rt.vtable = .{
        .callFn = mockCallFn,
        .valueTypeKey = mockValueTypeKey,
    };
    try testing.expect(fix.rt.vtable != null);
}

test "VTable.callFn dispatches through Runtime field" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    fix.rt.vtable = .{
        .callFn = mockCallFn,
        .valueTypeKey = mockValueTypeKey,
    };

    const args = [_]Value{};
    const result = try fix.rt.vtable.?.callFn(&fix.rt, &env, .nil_val, &args, .{});
    try testing.expectEqual(Value.true_val, result);
}

test "BuiltinFn signature compiles and is invocable" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const f: BuiltinFn = &dummyBuiltin;
    const result = try f(&fix.rt, &env, &.{}, .{});
    try testing.expect(result.isNil());
}

// --- ADR-0008 amendment 1 + amendment 3 dispatch fn tests ---

fn protocolMethodMock(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    // Echo arg count as an integer so the test can verify the right
    // builtin ran with the right arguments.
    return Value.initInteger(@intCast(args.len));
}

/// Mock vtable.callFn that handles the `.builtin_fn` arm — mirrors
/// the canonical pattern at `multimethod.zig:662-674` (cycle 5a test).
/// Cycle 6.6 dispatch routes every protocol-method call through
/// `rt.vtable.callFn`, so the BuiltinFn-Value-wrapped mock used by
/// the test below needs a vtable to land on.
fn dispatchMockCallFn(
    rt: *Runtime,
    env: *Env,
    callee: Value,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value {
    if (callee.tag() == .builtin_fn) {
        const fn_ptr = callee.asBuiltinFn(BuiltinFn);
        return fn_ptr(rt, env, args, loc);
    }
    return callee;
}

fn dispatchMockTypeKey(val: Value) []const u8 {
    return @tagName(val.tag());
}

test "dispatch routes through CallSite cache on monomorphic typed_instance receivers" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    fix.rt.vtable = .{ .callFn = dispatchMockCallFn, .valueTypeKey = dispatchMockTypeKey };

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    // Synthetic descriptor with one MethodEntry whose method_val
    // wraps our BuiltinFn mock via the .builtin_fn immediate tag.
    const methods = [_]td_mod.TypeDescriptor.MethodEntry{
        .{ .protocol_name = "P", .method_name = "m", .method_val = Value.initBuiltinFn(&protocolMethodMock) },
    };
    const td = try testing.allocator.create(td_mod.TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "test.Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{"P"},
        .method_table = &methods,
        .parent = null,
        .meta = .nil_val,
    };

    const inst = try td_mod.allocInstance(&fix.rt, td, &.{});

    var cs: CallSite = .{};
    const args = [_]Value{ .nil_val, .true_val };

    // Miss: fills the cache.
    const r1 = try dispatch(&fix.rt, &env, &cs, inst, "P", "m", &args, .{});
    try testing.expectEqual(@as(i64, 2), r1.asInteger());
    try testing.expect(cs.last_type.? == td);
    try testing.expect(cs.last_method != null);

    // Hit: same cache slot used (CallSite state unchanged).
    const last_method_ptr = cs.last_method.?;
    const r2 = try dispatch(&fix.rt, &env, &cs, inst, "P", "m", &args, .{});
    try testing.expectEqual(@as(i64, 2), r2.asInteger());
    try testing.expect(cs.last_method.? == last_method_ptr);
}

test "dispatch raises protocol_no_satisfies when method missing from descriptor" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const td = try testing.allocator.create(td_mod.TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "test.Bare",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    const inst = try td_mod.allocInstance(&fix.rt, td, &.{});

    var cs: CallSite = .{};
    try testing.expectError(
        error.TypeError,
        dispatch(&fix.rt, &env, &cs, inst, "P", "missing", &.{}, .{}),
    );
}

test "dispatch raises protocol_no_satisfies on non-typed_instance receiver" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    var cs: CallSite = .{};
    // Receiver is an integer Value, not a typed_instance — the per-Tag
    // default descriptor table is a Phase 7+ extension; for now this
    // path raises immediately.
    try testing.expectError(
        error.TypeError,
        dispatch(&fix.rt, &env, &cs, Value.initInteger(42), "P", "m", &.{}, .{}),
    );
}

test "threadlocal current_env starts null and is settable" {
    try testing.expect(current_env == null);

    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    current_env = &env;
    defer current_env = null;
    try testing.expectEqual(@as(?*Env, &env), current_env);
}
