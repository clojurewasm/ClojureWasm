// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.System`.
//!
//! Backend: impl-only
//! Impl deps: clock
//! Clojure peer: none
//!
//! Thin wrapper over `runtime/clock.zig` per F-009. Static methods
//! `currentTimeMillis` and `nanoTime` map to `clock.currentMillis` /
//! `clock.nanoTime`; `getProperty` answers OS-truthful system properties
//! (separators / os.name / os.arch / file.encoding / user.dir), nil for an
//! unknown key. Both bare `(System/...)` and FQCN `(java.lang.System/...)`
//! forms resolve (java.lang auto-import).
//!
//! D-121 + ADR-0050: populates `method_table` for `currentTimeMillis`,
//! `nanoTime`, `getProperty`, `getenv`, `lineSeparator`, `exit`, `arraycopy`.
//! Dispatched via `InteropCallNode { .kind = .static_method }`. Runtime init
//! per UUID.zig rationale.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const clock = @import("../../clock.zig");
const process_env = @import("../../process_env.zig");
const java_array = @import("../../collection/java_array.zig");

/// Implements `(java.lang.System/currentTimeMillis)`.
/// Spec: returns the current epoch milliseconds as a long.
/// JVM reference: java.lang.System#currentTimeMillis.
/// cw v1 tier: A (Phase 14 / D-121).
fn currentTimeMillis(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/currentTimeMillis", args, 0, loc);
    return Value.initInteger(clock.currentMillis(rt.io));
}

/// Implements `(java.lang.System/nanoTime)`.
/// Spec: returns a monotonic nanosecond counter as a long. The
/// absolute value has no meaning; only differences are meaningful.
/// JVM reference: java.lang.System#nanoTime.
/// cw v1 tier: A (Phase 14 / D-121).
fn nanoTime(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/nanoTime", args, 0, loc);
    return Value.initInteger(clock.nanoTime(rt.io));
}

const std = @import("std");
const builtin = @import("builtin");
const string_mod = @import("../../collection/string.zig");

/// The OS-truthful JVM system-property values cljw can answer. POSIX
/// separators + UTF-8 default encoding + os.name/os.arch from the compile
/// target. Any key outside this set (incl. `java.*`) returns nil — matching
/// JVM `getProperty` for an unknown key, and the no-JVM stance (cljw has no
/// Java runtime). `user.dir` (cwd) is resolved at call time, not here.
fn staticProperty(name: []const u8) ?[]const u8 {
    const os_name = switch (builtin.target.os.tag) {
        .macos => "Mac OS X",
        .linux => "Linux",
        .windows => "Windows",
        else => @tagName(builtin.target.os.tag),
    };
    // JVM os.arch uses "amd64" for x86_64; "aarch64" matches as-is.
    const os_arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        else => @tagName(builtin.target.cpu.arch),
    };
    const is_windows = builtin.target.os.tag == .windows;
    const table = .{
        .{ "line.separator", if (is_windows) "\r\n" else "\n" },
        .{ "file.separator", if (is_windows) "\\" else "/" },
        .{ "path.separator", if (is_windows) ";" else ":" },
        .{ "file.encoding", "UTF-8" },
        .{ "os.name", os_name },
        .{ "os.arch", os_arch },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// Implements `(java.lang.System/getProperty key)` + 2-arg
/// `(getProperty key default)`.
/// Spec: returns the system property for `key`, else nil (1-arg) or
/// `default` (2-arg). cw v1 answers OS-truthful properties (separators,
/// os.name/os.arch, file.encoding, user.dir); other keys (incl. `java.*`)
/// miss (no-JVM: cljw has no Java runtime).
/// JVM reference: java.lang.System#getProperty.
/// cw v1 tier: A.
fn getProperty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.lang.System/getProperty", args, 1, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/getProperty", .actual = @tagName(args[0].tag()) });
    const name = string_mod.asString(args[0]);
    if (staticProperty(name)) |val| return string_mod.alloc(rt, val);
    if (std.mem.eql(u8, name, "user.dir")) {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(rt.io, &buf) catch return propertyMiss(args);
        return string_mod.alloc(rt, buf[0..n]);
    }
    return propertyMiss(args);
}

/// 1-arg miss → nil; 2-arg miss → the supplied default (JVM semantics).
fn propertyMiss(args: []const Value) Value {
    return if (args.len == 2) args[1] else Value.nil_val;
}

/// Implements `(java.lang.System/getenv name)`.
/// Spec: returns the value of the environment variable `name`, or nil if unset
///   (JVM returns `null`). The 0-arg `(getenv)` JVM form returning the whole map
///   is out of scope until cljw has a map-from-env need.
/// JVM reference: java.lang.System#getenv(String).
/// cw v1 tier: A.
fn getenv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/getenv", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/getenv", .actual = @tagName(args[0].tag()) });
    const name = string_mod.asString(args[0]);
    if (process_env.get(name)) |val| return string_mod.alloc(rt, val);
    return Value.nil_val;
}

/// Implements `(java.lang.System/lineSeparator)`.
/// Spec: returns the system line separator — "\n" (POSIX) / "\r\n" (Windows),
/// the same value as `(getProperty "line.separator")`.
/// JVM reference: java.lang.System#lineSeparator().
/// cw v1 tier: A.
fn lineSeparator(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/lineSeparator", args, 0, loc);
    return string_mod.alloc(rt, staticProperty("line.separator").?);
}

/// Implements `(java.lang.System/exit code)`.
/// Spec: terminates the process with status `code` (the OS sees the low 8 bits,
/// matching POSIX + the JVM's effective behaviour). cljw flushes the shared
/// stdout first so buffered output is not lost; it runs NO shutdown hooks
/// (cljw has none — a divergence from the JVM, which runs registered hooks).
/// JVM reference: java.lang.System#exit(int).
/// cw v1 tier: A.
fn exit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/exit", args, 1, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "java.lang.System/exit", .actual = @tagName(args[0].tag()) });
    if (rt.stdout) |out| out.flush() catch {};
    // The OS exit code is the low 8 bits (POSIX); `& 0xFF` is two's-complement
    // correct for a negative code too (JVM `exit(-1)` → 255).
    std.process.exit(@intCast(args[0].asInteger() & 0xFF));
}

/// Implements `(java.lang.System/arraycopy src srcPos dest destPos length)`.
/// Spec: copies `length` elements from `src[srcPos..]` into `dest[destPos..]`.
/// Both are cljw Java arrays (ADR-0105 type-erased []Value). A same-array
/// overlapping copy is correct (JVM semantics: as if through a temp — @memmove).
/// Out-of-range positions/length raise an index error (JVM throws
/// ArrayIndexOutOfBoundsException; cljw's Kind differs per AD-007).
/// JVM reference: java.lang.System#arraycopy.
/// cw v1 tier: A.
fn arraycopy(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.lang.System/arraycopy", args, 5, loc);
    if (!java_array.isArray(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.System/arraycopy", .expected = "array", .actual = @tagName(args[0].tag()) });
    if (!java_array.isArray(args[2]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.System/arraycopy", .expected = "array", .actual = @tagName(args[2].tag()) });
    for ([_]usize{ 1, 3, 4 }) |i| {
        if (args[i].tag() != .integer)
            return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "java.lang.System/arraycopy", .actual = @tagName(args[i].tag()) });
    }
    const src = java_array.asArray(args[0]);
    const dst = java_array.asArray(args[2]);
    const src_pos = args[1].asInteger();
    const dst_pos = args[3].asInteger();
    const length = args[4].asInteger();
    if (length < 0 or src_pos < 0 or dst_pos < 0 or
        src_pos + length > src.len or dst_pos + length > dst.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.lang.System/arraycopy" });
    const n: usize = @intCast(length);
    @memmove(dst.items_ptr[@intCast(dst_pos)..][0..n], src.items_ptr[@intCast(src_pos)..][0..n]);
    return Value.nil_val;
}

fn initSystem(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 7);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "currentTimeMillis"),
        .method_val = Value.initBuiltinFn(&currentTimeMillis),
    };
    entries[1] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "nanoTime"),
        .method_val = Value.initBuiltinFn(&nanoTime),
    };
    entries[2] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "getProperty"),
        .method_val = Value.initBuiltinFn(&getProperty),
    };
    entries[3] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "getenv"),
        .method_val = Value.initBuiltinFn(&getenv),
    };
    entries[4] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "lineSeparator"),
        .method_val = Value.initBuiltinFn(&lineSeparator),
    };
    entries[5] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "exit"),
        .method_val = Value.initBuiltinFn(&exit),
    };
    entries[6] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "arraycopy"),
        .method_val = Value.initBuiltinFn(&arraycopy),
    };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.System",
    .descriptor = &descriptor,
    .init = &initSystem,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.System",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
