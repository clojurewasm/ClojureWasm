// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.protocols — Protocol definitions and extend-type implementations.
//!
//! Defines CollReduce, InternalReduce, IKVReduce, Datafiable, Navigable protocols
//! and registers nil/Object fallback implementations.
//! Replaces clojure/core/protocols.clj.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const Protocol = value_mod.Protocol;
const ProtocolFn = value_mod.ProtocolFn;
const MethodSig = value_mod.MethodSig;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Namespace = @import("../../runtime/namespace.zig").Namespace;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const collections = @import("../collections.zig");
const sequences = @import("../sequences.zig");
const predicates = @import("../predicates.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Protocol method implementations (extend-type functions)
// ============================================================

// --- CollReduce ---

/// nil CollReduce/coll-reduce: (f) for 2-arity, val for 3-arity
fn nilCollReduceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 2) {
        // (coll-reduce nil f) → (f)
        return bootstrap.callFnVal(allocator, args[1], &.{});
    } else if (args.len == 3) {
        // (coll-reduce nil f val) → val
        return args[2];
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to coll-reduce", .{args.len});
}

/// Object CollReduce/coll-reduce: seq-reduce for 2-arity, __zig-reduce for 3-arity
fn objectCollReduceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 2) {
        // (coll-reduce coll f) → (seq-reduce coll f)
        return seqReduce2(allocator, args[0], args[1]);
    } else if (args.len == 3) {
        // (coll-reduce coll f val) → (__zig-reduce f val coll)
        return sequences.zigReduceFn(allocator, &.{ args[1], args[2], args[0] });
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to coll-reduce", .{args.len});
}

// --- InternalReduce ---

/// nil InternalReduce/internal-reduce: returns val
fn nilInternalReduceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to internal-reduce", .{args.len});
    return args[2]; // val
}

/// Object InternalReduce/internal-reduce: naive-seq-reduce
fn objectInternalReduceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to internal-reduce", .{args.len});
    return naiveSeqReduce(allocator, args[0], args[1], args[2]);
}

// --- IKVReduce ---

/// nil IKVReduce/kv-reduce: returns init
fn nilKvReduceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to kv-reduce", .{args.len});
    return args[2]; // init
}

/// Object IKVReduce/kv-reduce: delegate to clojure.core/reduce-kv
fn objectKvReduceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to kv-reduce", .{args.len});
    // (reduce-kv f init amap)
    return collections.reduceKvBuiltin(allocator, &.{ args[1], args[2], args[0] });
}

// --- Datafiable ---

/// nil Datafiable/datafy: returns nil
fn nilDatafyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to datafy", .{args.len});
    return Value.nil_val;
}

/// Object Datafiable/datafy: returns x (identity)
fn objectDatafyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to datafy", .{args.len});
    return args[0];
}

// --- Navigable ---

/// Object Navigable/nav: returns x (third arg)
fn objectNavFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to nav", .{args.len});
    return args[2]; // v
}

// ============================================================
// Private helper functions (naive-seq-reduce, seq-reduce)
// ============================================================

/// Reduces a seq, ignoring any opportunities to switch to a more specialized implementation.
/// Equivalent to upstream naive-seq-reduce.
fn naiveSeqReduce(allocator: Allocator, s_arg: Value, f: Value, init: Value) anyerror!Value {
    var s = try collections.seqFn(allocator, &.{s_arg});
    var val = init;
    while (s.tag() != .nil) {
        const item = try collections.firstFn(allocator, &.{s});
        val = try bootstrap.callFnVal(allocator, f, &.{ val, item });
        if (val.tag() == .reduced) {
            return val.asReduced().value;
        }
        s = try predicates.nextFn(allocator, &.{s});
    }
    return val;
}

/// (seq-reduce coll f) — 2-arity: use first element as init
fn seqReduce2(allocator: Allocator, coll: Value, f: Value) anyerror!Value {
    const s = try collections.seqFn(allocator, &.{coll});
    if (s.tag() == .nil) {
        return bootstrap.callFnVal(allocator, f, &.{});
    }
    const first_val = try collections.firstFn(allocator, &.{s});
    const rest_val = try predicates.nextFn(allocator, &.{s});
    return naiveSeqReduce(allocator, rest_val, f, first_val);
}

// ============================================================
// Protocol registration
// ============================================================

/// Create a protocol and register it in the given namespace.
/// Returns the Protocol pointer for use in ProtocolFn creation.
pub fn createProtocol(
    allocator: Allocator,
    ns: *Namespace,
    name: []const u8,
    sigs: []const MethodSig,
    extend_via_meta: bool,
) !*Protocol {
    const protocol = try allocator.create(Protocol);
    const empty_map = try allocator.create(PersistentArrayMap);
    empty_map.* = .{ .entries = &.{} };
    protocol.* = .{
        .name = name,
        .method_sigs = sigs,
        .impls = empty_map,
        .extend_via_metadata = extend_via_meta,
        .defining_ns = ns.name,
    };

    // Bind protocol to var
    const proto_var = try ns.intern(name);
    proto_var.bindRoot(Value.initProtocol(protocol));

    // Create ProtocolFn for each unique method name
    var i: usize = 0;
    while (i < sigs.len) {
        const method_name = sigs[i].name;
        const pf = try allocator.create(ProtocolFn);
        pf.* = .{
            .protocol = protocol,
            .method_name = method_name,
        };
        const method_var = try ns.intern(method_name);
        method_var.bindRoot(Value.initProtocolFn(pf));

        // Skip duplicate names (multi-arity: same name appears multiple times)
        i += 1;
        while (i < sigs.len and std.mem.eql(u8, sigs[i].name, method_name)) {
            i += 1;
        }
    }

    return protocol;
}

/// Add a type implementation to a protocol's impls map.
pub fn extendType(
    allocator: Allocator,
    protocol: *Protocol,
    type_key: []const u8,
    methods: []const struct { name: []const u8, func: *const fn (Allocator, []const Value) anyerror!Value },
) !void {
    // Build method map: [name1, fn1, name2, fn2, ...]
    const method_entries = try allocator.alloc(Value, methods.len * 2);
    for (methods, 0..) |m, i| {
        method_entries[i * 2] = Value.initString(allocator, m.name);
        method_entries[i * 2 + 1] = Value.initBuiltinFn(m.func);
    }
    const method_map = try allocator.create(PersistentArrayMap);
    method_map.* = .{ .entries = method_entries };

    // Add to impls: grow the impls map
    const old_impls = protocol.impls;
    const new_entries = try allocator.alloc(Value, old_impls.entries.len + 2);
    @memcpy(new_entries[0..old_impls.entries.len], old_impls.entries);
    new_entries[old_impls.entries.len] = Value.initString(allocator, type_key);
    new_entries[old_impls.entries.len + 1] = Value.initMap(method_map);
    const new_impls = try allocator.create(PersistentArrayMap);
    new_impls.* = .{ .entries = new_entries };
    protocol.impls = new_impls;
    protocol.generation +%= 1;
}

/// Register all protocols and implementations in clojure.core.protocols namespace.
fn registerProtocols(allocator: Allocator, env: *Env) anyerror!void {
    const ns = try env.findOrCreateNamespace("clojure.core.protocols");

    // === CollReduce ===
    const coll_reduce_sigs = &[_]MethodSig{
        .{ .name = "coll-reduce", .arity = 2 },
        .{ .name = "coll-reduce", .arity = 3 },
    };
    const coll_reduce = try createProtocol(allocator, ns, "CollReduce", coll_reduce_sigs, false);
    try extendType(allocator, coll_reduce, "nil", &.{
        .{ .name = "coll-reduce", .func = &nilCollReduceFn },
    });
    try extendType(allocator, coll_reduce, "Object", &.{
        .{ .name = "coll-reduce", .func = &objectCollReduceFn },
    });

    // === InternalReduce ===
    const internal_reduce_sigs = &[_]MethodSig{
        .{ .name = "internal-reduce", .arity = 3 },
    };
    const internal_reduce = try createProtocol(allocator, ns, "InternalReduce", internal_reduce_sigs, false);
    try extendType(allocator, internal_reduce, "nil", &.{
        .{ .name = "internal-reduce", .func = &nilInternalReduceFn },
    });
    try extendType(allocator, internal_reduce, "Object", &.{
        .{ .name = "internal-reduce", .func = &objectInternalReduceFn },
    });

    // === IKVReduce ===
    const ikv_reduce_sigs = &[_]MethodSig{
        .{ .name = "kv-reduce", .arity = 3 },
    };
    const ikv_reduce = try createProtocol(allocator, ns, "IKVReduce", ikv_reduce_sigs, false);
    try extendType(allocator, ikv_reduce, "nil", &.{
        .{ .name = "kv-reduce", .func = &nilKvReduceFn },
    });
    try extendType(allocator, ikv_reduce, "Object", &.{
        .{ .name = "kv-reduce", .func = &objectKvReduceFn },
    });

    // === Datafiable (extend-via-metadata) ===
    const datafiable_sigs = &[_]MethodSig{
        .{ .name = "datafy", .arity = 1 },
    };
    const datafiable = try createProtocol(allocator, ns, "Datafiable", datafiable_sigs, true);
    try extendType(allocator, datafiable, "nil", &.{
        .{ .name = "datafy", .func = &nilDatafyFn },
    });
    try extendType(allocator, datafiable, "Object", &.{
        .{ .name = "datafy", .func = &objectDatafyFn },
    });

    // === Navigable (extend-via-metadata) ===
    const navigable_sigs = &[_]MethodSig{
        .{ .name = "nav", .arity = 3 },
    };
    const navigable = try createProtocol(allocator, ns, "Navigable", navigable_sigs, true);
    try extendType(allocator, navigable, "Object", &.{
        .{ .name = "nav", .func = &objectNavFn },
    });

    // Store protocol pointers as module-level for access by clojure_datafy, collections
    datafiable_protocol = datafiable;
    navigable_protocol = navigable;
    coll_reduce_protocol = coll_reduce;
}

/// Protocol pointers accessible by other modules (e.g., clojure_datafy, collections).
pub var datafiable_protocol: ?*Protocol = null;
pub var navigable_protocol: ?*Protocol = null;
pub var coll_reduce_protocol: ?*Protocol = null;

// ============================================================
// Namespace definition
// ============================================================

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.protocols",
    .post_register = &registerProtocols,
};

// ============================================================
// Tests
// ============================================================

test "naiveSeqReduce with empty seq" {
    const allocator = std.heap.page_allocator;
    // naive-seq-reduce on nil returns init
    const result = try naiveSeqReduce(allocator, Value.nil_val, Value.nil_val, Value.initInteger(42));
    try std.testing.expectEqual(@as(i64, 42), result.asInteger());
}
