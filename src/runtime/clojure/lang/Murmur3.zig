// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.Murmur3` static helpers (ADR-0108 am1).
//!
//! Backend: impl-only
//! Impl deps: hash
//! Clojure peer: clojure.core/hash-ordered-coll, clojure.core/hash-unordered-coll
//!
//! gvec / core.clj / data.* call these from custom-collection hasheq bodies.
//! `runtime/hash.zig`'s mixCollHash/hashOrdered/hashUnordered are byte-for-byte
//! identical to JVM Murmur3, so `hashOrdered`/`hashUnordered` simply delegate to
//! the existing `clojure.core/hash-ordered-coll`/`hash-unordered-coll` (the same
//! coll-fold), and `mixCollHash` to the raw `hash.mixCollHash`. AD-009: the
//! per-element value-hash is cljw-native (e.g. strings UTF-8), so the result is
//! intra-cljw consistent, not JVM bit-parity.

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const hash = @import("../../hash.zig");
const string_mod = @import("../../collection/string.zig");

/// Resolve `clojure.core/<name>` and call it through the backend vtable.
fn callCore(rt: *Runtime, env: *Env, name: []const u8, args: []const Value, loc: SourceLocation) !Value {
    const core = env.findNs("clojure.core") orelse return error.NoVTable;
    const v = core.resolve(name) orelse return error.NoVTable;
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, v.deref(), args, loc);
}

/// `(clojure.lang.Murmur3/hashOrdered xs)` — ordered collection hash; delegates
/// to `clojure.core/hash-ordered-coll` (the same fold, JVM-Murmur3-shaped).
fn hashOrdered(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.Murmur3/hashOrdered", args, 1, loc);
    return callCore(rt, env, "hash-ordered-coll", &.{args[0]}, loc);
}

/// `(clojure.lang.Murmur3/hashUnordered xs)` — unordered collection hash;
/// delegates to `clojure.core/hash-unordered-coll`.
fn hashUnordered(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.Murmur3/hashUnordered", args, 1, loc);
    return callCore(rt, env, "hash-unordered-coll", &.{args[0]}, loc);
}

/// `(clojure.lang.Murmur3/mixCollHash hash count)` — the raw mix-finalize step
/// (i32 in, i32 out; intra-cljw per AD-009).
fn mixCollHash(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Murmur3/mixCollHash", args, 2, loc);
    const h: i32 = @truncate(try error_catalog.expectInteger(args[0], "clojure.lang.Murmur3/mixCollHash", loc));
    const n: i32 = @truncate(try error_catalog.expectInteger(args[1], "clojure.lang.Murmur3/mixCollHash", loc));
    const mixed = hash.mixCollHash(@as(u32, @bitCast(h)), @as(u32, @bitCast(n)));
    return Value.initInteger(@as(i32, @bitCast(mixed)));
}

/// `(clojure.lang.Murmur3/hashUnencodedChars s)` — Murmur3 over the string's
/// UTF-16 code units. Unlike the AD-009 collection hashes this is JVM
/// BIT-PARITY (the input is pure code units — no cljw-native value hash is
/// involved), so clj and cljw agree on the value (D-376; data.xml's 2 sites).
fn hashUnencodedChars(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Murmur3/hashUnencodedChars", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "clojure.lang.Murmur3/hashUnencodedChars", .expected = "string", .actual = @tagName(args[0].tag()) });
    const h = hash.hashUnencodedChars(string_mod.asString(args[0]));
    return Value.initInteger(@as(i32, @bitCast(h)));
}

fn initMurmur3(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "hashOrdered", &hashOrdered },
        .{ "hashUnordered", &hashUnordered },
        .{ "mixCollHash", &mixCollHash },
        .{ "hashUnencodedChars", &hashUnencodedChars },
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
    .cljw_ns = "cljw.clojure.lang.Murmur3",
    .descriptor = &descriptor,
    .init = &initMurmur3,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.Murmur3",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
