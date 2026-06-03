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
//! `nanoTime`, `getProperty`. Dispatched via `InteropCallNode { .kind =
//! .static_method }`. Runtime init per UUID.zig rationale.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const clock = @import("../../clock.zig");

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

fn initSystem(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 3);
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
