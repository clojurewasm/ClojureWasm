// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.io.StringWriter` — an in-memory character Writer
//! (ADR-0106 host_instance container). Landed for clojure.data.csv's JVM
//! write surface (`(write-csv (StringWriter.) data)` → `(str w)`), and any
//! lib that collects Writer output in memory.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none.
//!
//! The instance is a `.host_instance` whose state[0] holds a pointer to a
//! gc.infra-allocated `std.ArrayList(u8)` — the same container shape as
//! java.lang.StringBuilder. `.write` appends the str-form of its argument
//! (JVM Writer.write(String); a cljw char/int writes its character);
//! `.toString` / `(str w)` read the buffer; `.flush`/`.close` are no-ops
//! (JVM StringWriter contract).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const string_collection = @import("../../collection/string.zig");
const print_mod = @import("../../print.zig");

const ByteList = std.ArrayList(u8);

var sw_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn listOf(recv: Value) *ByteList {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// `(java.io.StringWriter.)` — empty buffer (Java's int-capacity ctor is a
/// hint only; cljw ignores it when given).
fn initSw(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.io.StringWriter.", .expected = 0 });
    const lp = try rt.gc.infra.create(ByteList);
    lp.* = .empty;
    const td = sw_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromPtr(lp), 0, 0, 0 });
}

/// `(.write w x)` — JVM Writer.write overloads: write(int) is a CHARACTER
/// code (`(.write w 99)` appends "c", unlike StringBuilder.append(int)'s
/// digits); write(String)/char append the text. Returns nil (void on JVM).
/// `(.append w x)` returns the writer (chains).
fn writeM(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("write", args, 2, loc);
    const lp = listOf(args[0]);
    if (args[1].tag() == .integer) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(args[1].asInteger()), &buf) catch
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".write", .expected = "valid character code", .actual = "out-of-range int" });
        try lp.appendSlice(rt.gc.infra, buf[0..n]);
        return .nil_val;
    }
    try appendStr(rt, env, lp, args[1]);
    return .nil_val;
}

fn appendM(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("append", args, 2, loc);
    try appendStr(rt, env, listOf(args[0]), args[1]);
    return args[0];
}

fn appendStr(rt: *Runtime, env: *Env, lp: *ByteList, v: Value) !void {
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try print_mod.writeStrValue(rt, env, &aw.writer, v);
    try lp.appendSlice(rt.gc.infra, aw.writer.buffered());
}

/// `(.toString w)` / `(str w)` — the accumulated characters as a cljw String.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    return string_collection.alloc(rt, listOf(args[0]).items);
}

/// `.flush` / `.close` — no-ops per the JVM StringWriter contract.
fn noOp(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = args;
    _ = loc;
    return .nil_val;
}

fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const lp: *ByteList = @ptrFromInt(state[0]);
    lp.deinit(infra);
    infra.destroy(lp);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initSw },
    .{ .name = "write", .f = &writeM },
    .{ .name = "append", .f = &appendM },
    .{ .name = "toString", .f = &toString },
    .{ .name = "flush", .f = &noOp },
    .{ .name = "close", .f = &noOp },
};

fn initSwDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    sw_descriptor = td;
    td.host_finalise = &finaliseState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.io.StringWriter",
    .descriptor = &descriptor,
    .init = &initSwDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.io.StringWriter",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
