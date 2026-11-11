// SPDX-License-Identifier: EPL-2.0
//! cljw.ffi failures as data (ADR-0202): every throw is
//! `(ex-info "ffi: ..." {:ffi/error <kind> ...})`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: the `{:ffi/error ...}` contract of cljw.ffi
//!
//! The data map is the contract shared with clojurust's `clojure.rust.ffi`, so
//! it is built here rather than through the error catalog, whose exceptions
//! carry no ex-data. Kinds: :open :symbol :signature :arity :arg-type :closed.
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Value = @import("../../value/value.zig").Value;
const string_mod = @import("../../collection/string.zig");
const map_mod = @import("../../collection/map.zig");
const ex_info = @import("../../collection/ex_info.zig");
const keyword_mod = @import("../../keyword.zig");
const dispatch = @import("../../dispatch.zig");

pub const Field = struct {
    key: []const u8,
    val: union(enum) { kw: []const u8, str: []const u8, int: i64, value: Value },
};

/// Throw `(ex-info msg {:ffi/error kind ...fields})`.
pub fn fail(rt: *Runtime, kind: []const u8, fields: []const Field, comptime fmt: []const u8, fmt_args: anytype) anyerror {
    const msg = try std.fmt.allocPrint(rt.gpa, "ffi: " ++ fmt, fmt_args);
    defer rt.gpa.free(msg);
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var data = map_mod.empty();
    data = try map_mod.assoc(rt, data, try keyword_mod.intern(rt, "ffi", "error"), try keyword_mod.intern(rt, null, kind));
    for (fields) |f| {
        const v = switch (f.val) {
            .kw => |s| try keyword_mod.intern(rt, null, s),
            .str => |s| try string_mod.alloc(rt, s),
            .int => |i| Value.initInteger(i),
            .value => |x| x,
        };
        data = try map_mod.assoc(rt, data, try keyword_mod.intern(rt, null, f.key), v);
    }
    dispatch.last_thrown_exception = try ex_info.alloc(rt, msg, data, Value.nil_val);
    return error.ThrownValue;
}

pub fn failArgType(rt: *Runtime, index: usize, type_name: []const u8) anyerror {
    return fail(rt, "arg-type", &.{
        .{ .key = "index", .val = .{ .int = @intCast(index) } },
        .{ .key = "type", .val = .{ .kw = type_name } },
    }, "argument {d} is not a valid :{s}", .{ index, type_name });
}

pub fn failClosed(rt: *Runtime) anyerror {
    return fail(rt, "closed", &.{}, "the library is closed", .{});
}

/// What a signature is built for, named in the `:signature` throw: a symbol
/// (`function`, `:symbol "name"`) or a raw address (`function-at`,
/// `:address n`).
pub const Callee = union(enum) {
    name: []const u8,
    address: usize,
};

pub fn failSignature(rt: *Runtime, callee: Callee, callee_v: Value, reason: []const u8) anyerror {
    const reason_f: Field = .{ .key = "reason", .val = .{ .str = reason } };
    return switch (callee) {
        .name => |s| fail(rt, "signature", &.{ .{ .key = "symbol", .val = .{ .str = s } }, reason_f }, "bad signature for {s}: {s}", .{ s, reason }),
        .address => |a| fail(rt, "signature", &.{ .{ .key = "address", .val = .{ .value = callee_v } }, reason_f }, "bad signature for the function at 0x{x}: {s}", .{ a, reason }),
    };
}

/// A NULL function address (`function-at` of 0 or nil): the `:symbol` throw a
/// failed lookup gives, since NULL names no function either.
pub fn failNullAddress(rt: *Runtime, addr_v: Value) anyerror {
    return fail(rt, "symbol", &.{.{ .key = "address", .val = .{ .value = addr_v } }}, "no function at a NULL address", .{});
}
