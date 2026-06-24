// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Objects` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Null-aware helper statics over arbitrary Values: `isNull` / `nonNull` /
//! `equals` (cljw value equality, matching Java's null-safe `a.equals(b)`) /
//! `requireNonNull` (throws a real NullPointerException on nil, via the
//! ex_info host-throw path like atom.zig's IllegalStateException) /
//! `requireNonNullElse` / `toString` (the null-default forms). `hash` /
//! `hashCode` are intentionally omitted: Java's hashCode contract differs
//! from cljw's value hash, so they would diverge from the JVM.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const ex_info = @import("../../collection/ex_info.zig");
const dispatch = @import("../../dispatch.zig");
const equal = @import("../../equal.zig");
const print_mod = @import("../../print.zig");
const string_mod = @import("../../collection/string.zig");

/// Throw a real NullPointerException carrying `msg` (empty = no message), via
/// the ex_info host-throw path: publish the thrown value + return the sentinel
/// error that `(try …)` catch-matches against (the same shape atom.zig uses
/// for an IllegalStateException). cljw has no NullPointerException Kind, so a
/// constructed ex_info is the only way to throw the precise class.
fn throwNpe(rt: *Runtime, msg: []const u8) anyerror!Value {
    dispatch.last_thrown_exception = try ex_info.allocException(rt, msg, "NullPointerException");
    return error.ThrownValue;
}

/// `(java.util.Objects/isNull x)` — `x` is nil. JVM ref: Objects#isNull.
fn isNull(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.util.Objects/isNull", args, 1, loc);
    return if (args[0].tag() == .nil) .true_val else .false_val;
}

/// `(java.util.Objects/nonNull x)` — `x` is not nil. JVM ref: Objects#nonNull.
fn nonNull(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.util.Objects/nonNull", args, 1, loc);
    return if (args[0].tag() != .nil) .true_val else .false_val;
}

/// `(java.util.Objects/equals a b)` — null-safe value equality: both nil ⇒
/// true, one nil ⇒ false, else cljw `=`. Matches Java's
/// `(a == b) || (a != null && a.equals(b))` for value types.
fn equals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Objects/equals", args, 2, loc);
    return if (try equal.valueEqual(rt, env, args[0], args[1])) .true_val else .false_val;
}

/// `(java.util.Objects/requireNonNull x)` / `(… x msg)` — return `x` unless it
/// is nil, in which case throw NullPointerException (with `msg` when given).
/// JVM reference: java.util.Objects#requireNonNull.
fn requireNonNull(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "java.util.Objects/requireNonNull", .got = args.len, .min = 1, .max = 2 });
    if (args[0].tag() == .nil) {
        const msg = if (args.len == 2 and args[1].tag() == .string) string_mod.asString(args[1]) else "";
        return throwNpe(rt, msg);
    }
    return args[0];
}

/// `(java.util.Objects/requireNonNullElse x default)` — `x` if non-nil, else
/// `default` if non-nil, else throw NullPointerException (matching Java, which
/// `requireNonNull`s the default). JVM ref: Objects#requireNonNullElse.
fn requireNonNullElse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Objects/requireNonNullElse", args, 2, loc);
    if (args[0].tag() != .nil) return args[0];
    if (args[1].tag() != .nil) return args[1];
    return throwNpe(rt, "defaultObj");
}

/// `(java.util.Objects/toString x)` / `(… x nullDefault)` — `x`'s string form,
/// or `"null"` (1-arg) / `nullDefault` (2-arg) when `x` is nil. A non-nil
/// value renders via cljw `str` (= Java `toString` for value types). JVM
/// reference: java.util.Objects#toString.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "java.util.Objects/toString", .got = args.len, .min = 1, .max = 2 });
    if (args[0].tag() == .nil) {
        if (args.len == 2) return args[1];
        return string_mod.alloc(rt, "null");
    }
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try print_mod.writeStrValue(rt, env, &aw.writer, args[0]);
    return string_mod.alloc(rt, aw.writer.buffered());
}

fn initObjects(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "isNull", &isNull },
        .{ "nonNull", &nonNull },
        .{ "equals", &equals },
        .{ "requireNonNull", &requireNonNull },
        .{ "requireNonNullElse", &requireNonNullElse },
        .{ "toString", &toString },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.Objects",
    .descriptor = &descriptor,
    .init = &initObjects,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.Objects",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
