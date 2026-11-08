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
//! (separators / os.name / os.arch / file.encoding / user.dir /
//! user.home / java.io.tmpdir), nil for an unknown key. Both bare
//! `(System/...)` and FQCN `(java.lang.System/...)` forms resolve
//! (java.lang auto-import).
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
const map_collection = @import("../../collection/map.zig");

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
/// A new static property is one entry here; getProperty and getProperties
/// both read this table.
const static_properties = blk: {
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
    break :blk .{
        .{ "line.separator", if (is_windows) "\r\n" else "\n" },
        .{ "file.separator", if (is_windows) "\\" else "/" },
        .{ "path.separator", if (is_windows) ";" else ":" },
        .{ "file.encoding", "UTF-8" },
        .{ "os.name", os_name },
        .{ "os.arch", os_arch },
        // The JVM's Unix default ignores $TMPDIR; parity over convenience.
        .{ "java.io.tmpdir", "/tmp" },
    };
};

fn staticProperty(name: []const u8) ?[]const u8 {
    inline for (static_properties) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// Property-to-environment mapping. New environment-backed properties are
/// registered here; both getProperty and getProperties read this same table.
const environment_properties = .{
    .{ "user.home", "HOME", @as(?[]const u8, null) },
};

fn environmentProperty(name: []const u8) ?[]const u8 {
    inline for (environment_properties) |entry| {
        if (std.mem.eql(u8, name, entry[0]))
            return process_env.get(entry[1]) orelse entry[2];
    }
    return null;
}

/// The runtime's source path rendered as a `path.separator`-joined string —
/// the value of `java.class.path`. Caller owns the returned Value's string.
/// Null when no source path is configured (nothing to name).
fn classPath(rt: *Runtime) anyerror!?Value {
    if (rt.load_paths.len == 0) return null;
    const joined = try std.mem.join(rt.gpa, staticProperty("path.separator").?, rt.load_paths);
    defer rt.gpa.free(joined);
    return try string_mod.alloc(rt, joined);
}

/// Implements `(java.lang.System/getProperty key)` + 2-arg
/// `(getProperty key default)`.
/// Spec: returns the system property for `key`, else nil (1-arg) or
/// `default` (2-arg). cw v1 answers OS-truthful properties (separators,
/// os.name/os.arch, file.encoding, user.dir, user.home, java.io.tmpdir)
/// plus `java.class.path` — the resolved source path. Other
/// keys (incl. the rest of `java.*`) miss (no-JVM: cljw has no Java runtime).
/// JVM reference: java.lang.System#getProperty.
/// cw v1 tier: A.
fn getProperty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.lang.System/getProperty", args, 1, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/getProperty", .actual = @tagName(args[0].tag()) });
    const name = string_mod.asString(args[0]);
    // A user-set property (setProperty) overrides the OS-truthful static set,
    // matching the JVM (a set value wins for any key, incl. e.g. user.dir).
    if (rt.system_properties.get(name)) |val| return string_mod.alloc(rt, val);
    if (staticProperty(name)) |val| return string_mod.alloc(rt, val);
    if (environmentProperty(name)) |val| return string_mod.alloc(rt, val);
    if (std.mem.eql(u8, name, "user.dir")) {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(rt.io, &buf) catch return propertyMiss(args);
        return string_mod.alloc(rt, buf[0..n]);
    }
    if (std.mem.eql(u8, name, "java.class.path")) {
        if (try classPath(rt)) |v| return v;
    }
    return propertyMiss(args);
}

/// 1-arg miss → nil; 2-arg miss → the supplied default (JVM semantics).
fn propertyMiss(args: []const Value) Value {
    return if (args.len == 2) args[1] else Value.nil_val;
}

/// Implements `(java.lang.System/getenv name)` + the 0-arg
/// `(java.lang.System/getenv)` returning the WHOLE environment as a map
/// (ADR-0174 D5; JVM returns an unmodifiable Map<String,String> — cljw's
/// persistent map is the natural equivalent).
/// Spec: 1-arg — the value of the environment variable `name`, or nil if
/// unset (JVM `null`); 0-arg — every environment variable as {name value}.
/// JVM reference: java.lang.System#getenv(String) / #getenv().
/// cw v1 tier: A.
fn getenv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.lang.System/getenv", args, 0, 1, loc);
    if (args.len == 0) {
        const m = process_env.all() orelse return map_collection.empty();
        // Fabrication region: the intermediate maps of the assoc fold are
        // live-but-unrooted between allocs; defer any collect to the end.
        rt.gc.enterFabrication();
        defer rt.gc.exitFabrication();
        var out = map_collection.empty();
        var it = m.iterator();
        while (it.next()) |entry| {
            const k = try string_mod.alloc(rt, entry.key_ptr.*);
            const v = try string_mod.alloc(rt, entry.value_ptr.*);
            out = try map_collection.assoc(rt, out, k, v);
        }
        return out;
    }
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/getenv", .actual = @tagName(args[0].tag()) });
    const name = string_mod.asString(args[0]);
    if (process_env.get(name)) |val| return string_mod.alloc(rt, val);
    return Value.nil_val;
}

/// Implements `(java.lang.System/getProperties)` (ADR-0174 D5).
/// Spec: every system property as a map — the OS-truthful static set +
/// `user.dir` + the `setProperty` overlay (overlay wins per key, matching
/// `getProperty`'s precedence). JVM returns `java.util.Properties` (a
/// mutable Map); cljw returns a persistent map — the map-shaped reads
/// (`get` / `into {}` / iteration) are oracle-identical, the mutable
/// Properties API is not modelled (AD-055).
/// JVM reference: java.lang.System#getProperties.
/// cw v1 tier: A.
fn getProperties(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/getProperties", args, 0, loc);
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var out = map_collection.empty();
    inline for (static_properties) |pair| {
        const k = try string_mod.alloc(rt, pair[0]);
        const v = try string_mod.alloc(rt, pair[1]);
        out = try map_collection.assoc(rt, out, k, v);
    }
    inline for (environment_properties) |entry| {
        const key = entry[0];
        if (environmentProperty(key)) |value| {
            const k = try string_mod.alloc(rt, key);
            const v = try string_mod.alloc(rt, value);
            out = try map_collection.assoc(rt, out, k, v);
        }
    }
    // user.dir resolves at call time (same as getProperty's arm).
    {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.process.currentPath(rt.io, &buf)) |n| {
            const k = try string_mod.alloc(rt, "user.dir");
            const v = try string_mod.alloc(rt, buf[0..n]);
            out = try map_collection.assoc(rt, out, k, v);
        } else |_| {
            // Unreadable cwd — the key is simply absent, like getProperty's miss.
        }
    }
    // java.class.path, likewise resolved at call time from the source path.
    if (try classPath(rt)) |v| {
        const k = try string_mod.alloc(rt, "java.class.path");
        out = try map_collection.assoc(rt, out, k, v);
    }
    var it = rt.system_properties.iterator();
    while (it.next()) |entry| {
        const k = try string_mod.alloc(rt, entry.key_ptr.*);
        const v = try string_mod.alloc(rt, entry.value_ptr.*);
        out = try map_collection.assoc(rt, out, k, v);
    }
    return out;
}

/// Implements `(java.lang.System/clearProperty key)` (ADR-0174 D5).
/// Spec: removes the user-set property `key` and returns its PREVIOUS value
/// (nil if unset), JVM-faithful. Only the `setProperty` overlay is
/// clearable — the OS-truthful static set is not a user-set entry (same
/// stance as `setProperty`'s previous-value rule), so clearing a static key
/// returns nil and `getProperty` keeps answering the OS truth.
/// JVM reference: java.lang.System#clearProperty.
/// cw v1 tier: A.
fn clearProperty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/clearProperty", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/clearProperty", .actual = @tagName(args[0].tag()) });
    const name = string_mod.asString(args[0]);
    if (rt.system_properties.fetchRemove(name)) |kv| {
        const prev = try string_mod.alloc(rt, kv.value);
        rt.gpa.free(kv.key);
        rt.gpa.free(kv.value);
        return prev;
    }
    return Value.nil_val;
}

/// Implements `(java.lang.System/identityHashCode x)` (ADR-0174 D5).
/// Spec: a hash for `x`'s IDENTITY — nil → 0 (JVM-exact); a heap value
/// hashes its reference bits (pointer-derived, stable for the value's
/// lifetime); an immediate hashes its value bits (two `=`-identical
/// immediates share an identity in cljw's NaN-box model — the same stance
/// as `locking` on immediates, AD-055; JVM object headers do not exist
/// here). Non-negative 31-bit result like the JVM's.
/// JVM reference: java.lang.System#identityHashCode.
/// cw v1 tier: A.
fn identityHashCode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.lang.System/identityHashCode", args, 1, loc);
    if (args[0].isNil()) return Value.initInteger(0);
    const bits: u64 = @intFromEnum(args[0]);
    const folded: u32 = @truncate(bits ^ (bits >> 32));
    return Value.initInteger(@as(i64, folded & 0x7fff_ffff));
}

/// Implements `(java.lang.System/gc)` (ADR-0174 D5).
/// Spec: "suggests that the runtime expend effort toward recycling unused
/// objects" — a HINT, exactly like the JVM. cljw runs a safe stop-the-world
/// collect when one is possible at the call point, else no-ops
/// (`GcHeap.requestCollect`). Returns nil.
/// JVM reference: java.lang.System#gc.
/// cw v1 tier: A.
fn gcFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/gc", args, 0, loc);
    rt.gc.requestCollect();
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
/// Both are cljw Java arrays of the same element kind (ADR-0204; a kind
/// mismatch is JVM ArrayStoreException, here `arg_value_invalid`). A same-array
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
    if (src.kind != dst.kind)
        return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "java.lang.System/arraycopy", .expected = "two arrays of the same element kind", .actual = @tagName(dst.kind) });
    java_array.copy(src, @intCast(src_pos), dst, @intCast(dst_pos), @intCast(length));
    return Value.nil_val;
}

/// Implements `(java.lang.System/setProperty key value)`.
/// Spec: sets the system property `key` to `value` and returns the PREVIOUS
/// value for `key` (nil if unset), JVM-faithful. The value is stored on the
/// runtime's `system_properties` map (gpa-owned dupe) and overrides the
/// OS-truthful static set on the next `getProperty`. A previously-set key's old
/// value is freed; the static-table value is NOT a "previous" (returns nil) —
/// matching the JVM, where the OS-derived defaults are not user-set entries.
/// JVM reference: java.lang.System#setProperty.
/// cw v1 tier: A.
fn setProperty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.System/setProperty", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/setProperty", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.lang.System/setProperty", .actual = @tagName(args[1].tag()) });
    const key = string_mod.asString(args[0]);
    const val = string_mod.asString(args[1]);
    const new_val = try rt.gpa.dupe(u8, val);
    errdefer rt.gpa.free(new_val);
    const gop = try rt.system_properties.getOrPut(rt.gpa, key);
    var prev: Value = Value.nil_val;
    if (gop.found_existing) {
        prev = try string_mod.alloc(rt, gop.value_ptr.*);
        rt.gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = rt.gpa.dupe(u8, key) catch |e| {
            rt.gpa.free(new_val);
            return e;
        };
    }
    gop.value_ptr.* = new_val;
    return prev;
}

fn initSystem(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "currentTimeMillis", &currentTimeMillis },
        .{ "nanoTime", &nanoTime },
        .{ "getProperty", &getProperty },
        .{ "getProperties", &getProperties },
        .{ "setProperty", &setProperty },
        .{ "clearProperty", &clearProperty },
        .{ "getenv", &getenv },
        .{ "lineSeparator", &lineSeparator },
        .{ "exit", &exit },
        .{ "arraycopy", &arraycopy },
        .{ "identityHashCode", &identityHashCode },
        .{ "gc", &gcFn },
    });
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.System",
    .descriptor = &descriptor,
    .init = &initSystem,
};

/// `System/in` / `System/out` / `System/err` (ADR-0174 D5b): heap-singleton
/// static fields (ADR-0087) resolving to the per-Runtime process-stdio
/// streams (`io/host_stream.zig::systemStream`). out/err are PrintStreams
/// (write/print/println/flush, per-call autoflush); in is the demand-filled
/// BufferedInputStream over process stdin.
const system_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "in", .value = .{ .singleton = .system_in } },
    .{ .name = "out", .value = .{ .singleton = .system_out } },
    .{ .name = "err", .value = .{ .singleton = .system_err } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.System",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .static_fields = &system_static_fields,
};
