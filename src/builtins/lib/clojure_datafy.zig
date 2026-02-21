// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.datafy — Functions to turn objects into data.
//! Replaces clojure/datafy.clj.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const metadata = @import("../metadata.zig");
const clojure_core_protocols = @import("clojure_core_protocols.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

/// (datafy x) — Attempts to return x as data.
/// Calls the Datafiable protocol's datafy method. If the result differs from x
/// and supports metadata, adds ::obj and ::class metadata.
fn datafyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to datafy", .{args.len});
    const x = args[0];

    // Call p/datafy on x via protocol dispatch
    const v = try callProtocolDatafy(allocator, x);

    if (v.eql(x)) {
        return v;
    }

    // If transformed and result supports metadata, add ::obj and ::class
    const can_have_meta = switch (v.tag()) {
        .map, .hash_map, .vector, .list, .set, .symbol, .keyword => true,
        else => false,
    };
    if (can_have_meta) {
        // Build metadata map with :clojure.datafy/obj and :clojure.datafy/class
        const obj_key = Value.initKeyword(allocator, .{ .ns = "clojure.datafy", .name = "obj" });
        const class_key = Value.initKeyword(allocator, .{ .ns = "clojure.datafy", .name = "class" });
        const type_val = try getTypeSymbol(allocator, x);

        // Get existing meta, assoc new keys, set as new meta
        const existing_meta = metadata.getMeta(v);
        const new_meta = try assocMeta(allocator, existing_meta, &.{
            obj_key, x,
            class_key, type_val,
        });
        return metadata.withMetaFn(allocator, &.{ v, new_meta });
    }

    return v;
}

/// (nav coll k v) — returns (possibly transformed) v in the context of coll and k.
fn navFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to nav", .{args.len});
    // Delegate to Navigable protocol's nav method
    return callProtocolNav(allocator, args[0], args[1], args[2]);
}

// ============================================================
// Helpers
// ============================================================

/// Call the Datafiable protocol's datafy method on x.
fn callProtocolDatafy(allocator: Allocator, x: Value) anyerror!Value {
    const protocol = clojure_core_protocols.datafiable_protocol orelse return x;

    // Check extend-via-metadata first
    if (protocol.extend_via_metadata) {
        if (protocol.defining_ns) |def_ns| {
            const meta_val = metadata.getMeta(x);
            if (meta_val.tag() == .map or meta_val.tag() == .hash_map) {
                const fq_key = Value.initSymbol(allocator, .{ .ns = def_ns, .name = "datafy" });
                const lookup = if (meta_val.tag() == .map) meta_val.asMap().get(fq_key) else meta_val.asHashMap().get(fq_key);
                if (lookup) |meta_method| {
                    return bootstrap.callFnVal(allocator, meta_method, &.{x});
                }
            }
        }
    }

    // Standard protocol dispatch
    const type_key = valueTypeKey(x);
    const method_map_val = protocol.impls.getByStringKey(type_key) orelse
        protocol.impls.getByStringKey("Object") orelse
        return x;
    if (method_map_val.tag() != .map) return x;
    const method_fn = method_map_val.asMap().getByStringKey("datafy") orelse return x;
    return bootstrap.callFnVal(allocator, method_fn, &.{x});
}

/// Call the Navigable protocol's nav method.
fn callProtocolNav(allocator: Allocator, coll: Value, k: Value, v: Value) anyerror!Value {
    const nav_protocol = clojure_core_protocols.navigable_protocol orelse return v;

    // Check extend-via-metadata first
    if (nav_protocol.extend_via_metadata) {
        if (nav_protocol.defining_ns) |def_ns| {
            const meta_val = metadata.getMeta(coll);
            if (meta_val.tag() == .map or meta_val.tag() == .hash_map) {
                const fq_key = Value.initSymbol(allocator, .{ .ns = def_ns, .name = "nav" });
                const lookup = if (meta_val.tag() == .map) meta_val.asMap().get(fq_key) else meta_val.asHashMap().get(fq_key);
                if (lookup) |meta_method| {
                    return bootstrap.callFnVal(allocator, meta_method, &.{ coll, k, v });
                }
            }
        }
    }

    // Standard protocol dispatch
    const type_key = valueTypeKey(coll);
    const method_map_val = nav_protocol.impls.getByStringKey(type_key) orelse
        nav_protocol.impls.getByStringKey("Object") orelse
        return v;
    if (method_map_val.tag() != .map) return v;
    const method_fn = method_map_val.asMap().getByStringKey("nav") orelse return v;
    return bootstrap.callFnVal(allocator, method_fn, &.{ coll, k, v });
}

/// Get the type key for a value (mirrors VM's valueTypeKey).
fn valueTypeKey(val: Value) []const u8 {
    return switch (val.tag()) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => if (val.asMap().getByStringKey("__type")) |_| "record" else "map",
        .hash_map => "map",
        .set => "set",
        .atom => "atom",
        .volatile_ref => "volatile",
        .regex => "regex",
        .char => "char",
        else => "Object",
    };
}

/// Get the type of a value as a symbol.
fn getTypeSymbol(allocator: Allocator, x: Value) anyerror!Value {
    const type_name = switch (x.tag()) {
        .nil => "nil",
        .boolean => "java.lang.Boolean",
        .integer => "java.lang.Long",
        .float => "java.lang.Double",
        .string => "java.lang.String",
        .symbol => "clojure.lang.Symbol",
        .keyword => "clojure.lang.Keyword",
        .list => "clojure.lang.PersistentList",
        .vector => "clojure.lang.PersistentVector",
        .map, .hash_map => "clojure.lang.PersistentArrayMap",
        .set => "clojure.lang.PersistentHashSet",
        .atom => "clojure.lang.Atom",
        else => "java.lang.Object",
    };
    return Value.initSymbol(allocator, .{ .ns = null, .name = type_name });
}

/// Assoc key-value pairs into a metadata map.
fn assocMeta(allocator: Allocator, existing: Value, kvs: []const Value) anyerror!Value {
    if (existing.tag() == .nil) {
        // Create new map from kvs
        const entries = try allocator.alloc(Value, kvs.len);
        @memcpy(entries, kvs);
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = entries };
        return Value.initMap(map);
    }
    // Assoc into existing map
    if (existing.tag() == .map) {
        const old = existing.asMap();
        // Allocate max possible size (old + new), will trim later
        const max_len = old.entries.len + kvs.len;
        const buf = try allocator.alloc(Value, max_len);
        @memcpy(buf[0..old.entries.len], old.entries);
        var len = old.entries.len;
        var i: usize = 0;
        while (i < kvs.len) : (i += 2) {
            const key = kvs[i];
            const val = kvs[i + 1];
            var found = false;
            var j: usize = 0;
            while (j < len) : (j += 2) {
                if (buf[j].eql(key)) {
                    buf[j + 1] = val;
                    found = true;
                    break;
                }
            }
            if (!found) {
                buf[len] = key;
                buf[len + 1] = val;
                len += 2;
            }
        }
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = buf[0..len] };
        return Value.initMap(map);
    }
    // For other meta types, create new map
    const map_entries = try allocator.alloc(Value, kvs.len);
    @memcpy(map_entries, kvs);
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = map_entries };
    return Value.initMap(map);
}

/// Register Datafiable extension for Exception (ex-info maps).
/// In CW, exceptions are maps with :__ex_info key, not a separate type.
/// The Object fallback (identity) already handles them correctly.
fn registerDatafyExtensions(allocator: Allocator, _: *@import("../../runtime/env.zig").Env) anyerror!void {
    _ = allocator;
    // In CW, exceptions are maps with __ex_info key.
    // The Object fallback (identity) already handles them correctly:
    // (datafy ex-info-map) returns the map itself.
    // No additional extension needed.
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{
        .name = "datafy",
        .func = &datafyFn,
        .doc = "Attempts to return x as data. If the value has been transformed and the result supports metadata, :clojure.datafy/obj will be set on the metadata.",
    },
    .{
        .name = "nav",
        .func = &navFn,
        .doc = "Returns (possibly transformed) v in the context of coll and k.",
    },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.datafy",
    .builtins = &builtins,
    .post_register = &registerDatafyExtensions,
};
