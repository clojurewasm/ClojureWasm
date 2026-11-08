// SPDX-License-Identifier: EPL-2.0
//! `print-method` writer handle (D-370, ADR-0127 Choice A2).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none (minted internally by the print path)
//!
//! A `host_instance` Value wrapping the ACTIVE `*std.Io.Writer` sink that the
//! native pr path is writing to, so a user `(defmethod print-method T [o w] …)`
//! receives `w` as a Clojure value it can thread back into `(print-method child
//! w)` (the native default unwraps it) or write to via `(.write w s)` /
//! `(.append w s)`. NOT a `java.io.Writer` class (AD-003 / ADR-0059 — cljw has no
//! java.io); `(class w)` is the simple name `Writer`. This is the F-004-declared
//! writer home (host_instance B13, no new NaN-box slot).
//!
//! LIFETIME (ADR-0127 invariant): the wrapped `*std.Io.Writer` is stack-scoped per
//! print call. `state[1]` is a liveness flag — `mint` sets it 1, `invalidate`
//! clears it after the print returns, and `unwrap` returns null once stale so a
//! `(.write w …)` AFTER the print raises a clean error instead of dereferencing a
//! dangling stack pointer. The handle is single-print-scoped; do not retain it.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const type_descriptor = @import("type_descriptor.zig");
const host_instance = @import("host_instance.zig");
const string_collection = @import("collection/string.zig");
const error_catalog = @import("error/catalog.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;

const Writer = std.Io.Writer;

/// `state[0]` = `@intFromPtr(*std.Io.Writer)`; `state[1]` = liveness (1 live, 0 stale);
/// `state[2]` = the printer's `consult` flag (1 = consult `print-method` per value).
fn writerPtr(recv: Value) ?*Writer {
    const inst = host_instance.asHostInstance(recv);
    if (inst.state[1] == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(inst.state[0])));
}

fn writeStr(args: []const Value, loc: SourceLocation, fn_name: []const u8) anyerror!void {
    const w = writerPtr(args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "write to a print-method writer after the print completed" });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[1].tag()) });
    try w.writeAll(string_collection.asString(args[1]));
}

/// `(.write w s)` — write the string to the wrapped sink; returns nil (Java write is void).
fn writeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("write", args, 2, loc);
    try writeStr(args, loc, "write");
    return .nil_val;
}

/// `(.append w s)` — write the string; returns the writer (Java append is chainable).
fn appendMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("append", args, 2, loc);
    try writeStr(args, loc, "append");
    return args[0];
}

/// `(.flush w)` — no-op (the underlying buffer is flushed by the print driver); nil.
fn flushMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("flush", args, 1, loc);
    return .nil_val;
}

// method_table backed by STATIC storage filled once at bootstrap: `initBuiltinFn`
// is a runtime `@intFromPtr` (not comptime), so the entries can't be a `const`, but
// a module-global `var` array filled once needs NO heap (method names are literals)
// → no leak. Unlike Random.zig's `gpa.dupe` (per-type, freed at rt.deinit), this one
// process-global descriptor never frees, so a static array is the leak-free home.
var writer_methods: [3]type_descriptor.TypeDescriptor.MethodEntry = undefined;
var writer_methods_inited: bool = false;

var writer_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "Writer",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

/// Fill the Writer descriptor's static method_table (idempotent). Called at bootstrap.
pub fn initWriterType() void {
    if (writer_methods_inited) return;
    writer_methods[0] = .{ .protocol_name = "", .method_name = "write", .method_val = Value.initBuiltinFn(&writeMethod) };
    writer_methods[1] = .{ .protocol_name = "", .method_name = "append", .method_val = Value.initBuiltinFn(&appendMethod) };
    writer_methods[2] = .{ .protocol_name = "", .method_name = "flush", .method_val = Value.initBuiltinFn(&flushMethod) };
    writer_descriptor.method_table = &writer_methods;
    writer_methods_inited = true;
}

/// Mint a single-print-scoped writer handle around `w`. Pair every `mint` with an
/// `invalidate` (typically `defer`) so a retained handle cannot read a dangling ptr.
pub fn mint(rt: *Runtime, w: *Writer, consult: bool) !Value {
    return host_instance.alloc(rt, &writer_descriptor, .{ @intFromPtr(w), 1, @intFromBool(consult), 0 });
}

/// The printer's `consult` flag as it was when this handle was minted. The
/// handle is the only value that crosses into a user `print-method` body and
/// back into the `:default` implementation, so it is what carries the flag
/// across that boundary. False for a stale handle.
pub fn consultOf(v: Value) bool {
    if (!isWriter(v)) return false;
    return host_instance.asHostInstance(v).state[2] == 1;
}

/// Mark a minted handle stale (its wrapped `*Writer` is about to leave scope).
pub fn invalidate(v: Value) void {
    @constCast(host_instance.asHostInstance(v)).state[1] = 0;
}

/// Is `v` a writer handle minted by `mint` (so the native default can unwrap it)?
pub fn isWriter(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == &writer_descriptor;
}

/// The live `*Writer` a handle wraps, or null if not a (live) writer handle.
pub fn unwrap(v: Value) ?*Writer {
    if (!isWriter(v)) return null;
    return writerPtr(v);
}
