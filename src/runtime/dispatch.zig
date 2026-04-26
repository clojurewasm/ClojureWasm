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
//! `installVTable(rt, ...)`. While `Runtime.vtable == null`, callFn /
//! expandMacro must not be invoked — this is structurally enforced
//! because the only callers (built-ins and the analyzer's macro path)
//! get registered in Phase 2.6+ and not before.
//!
//! Why not `pub var` for the vtable? Because then tests cannot inject
//! a mock backend, and two Runtimes cannot carry different backends.
//! `Runtime.vtable: ?VTable` solves both.

const std = @import("std");
const Value = @import("value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error.zig").SourceLocation;

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
/// backend (Phase 2.6) supplies the concrete implementation.
pub const CallFn = *const fn (
    rt: *Runtime,
    env: *Env,
    fn_val: Value,
    args: []const Value,
) anyerror!Value;

/// Returns a human-readable type name for `(type x)` and error
/// messages. Filled in by the backend so it can dispatch over its own
/// heap shape (e.g. distinguish two record kinds with the same
/// HeapTag).
pub const ValueTypeKeyFn = *const fn (val: Value) []const u8;

/// Macro-expansion entry point implemented by the analyzer. Called
/// when the backend encounters an invocation whose head resolves to a
/// macro Var.
pub const ExpandMacroFn = *const fn (
    rt: *Runtime,
    env: *Env,
    macro_val: Value,
    args: []const Value,
) anyerror!Value;

/// Layer-0 → Layer-1+ dispatch table. Stored as a field on `Runtime`,
/// not as a `pub var`, so multiple Runtimes can carry independent
/// backends (parallel tests, multi-tenant nREPL, mock injection).
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
    expandMacro: ExpandMacroFn,
};

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

fn mockCallFn(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value) anyerror!Value {
    _ = rt;
    _ = env;
    _ = fn_val;
    _ = args;
    return .true_val;
}

fn mockValueTypeKey(val: Value) []const u8 {
    _ = val;
    return "mock";
}

fn mockExpandMacro(rt: *Runtime, env: *Env, macro_val: Value, args: []const Value) anyerror!Value {
    _ = rt;
    _ = env;
    _ = macro_val;
    _ = args;
    return .nil_val;
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
        .expandMacro = mockExpandMacro,
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
        .expandMacro = mockExpandMacro,
    };

    const args = [_]Value{};
    const result = try fix.rt.vtable.?.callFn(&fix.rt, &env, .nil_val, &args);
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
