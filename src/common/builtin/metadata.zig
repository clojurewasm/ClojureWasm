// Metadata builtins — meta, with-meta, vary-meta, alter-meta!, reset-meta!
//
// Clojure metadata system: immutable maps attached to values that support
// the IMeta protocol (collections, symbols, fns). Mutable metadata on
// reference types (Var, Atom) via alter-meta! / reset-meta!.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../value.zig").Value;
const PersistentArrayMap = @import("../collections.zig").PersistentArrayMap;
const err = @import("../error.zig");

const testing = std.testing;

// ============================================================
// meta — return metadata map from a value
// ============================================================

pub fn metaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to meta", .{args.len});
    if (args[0].tag() == .var_ref) return getVarMeta(allocator, args[0].asVarRef());
    return getMeta(args[0]);
}

/// Extract metadata from a Value. Returns nil if the value has no metadata
/// or doesn't support metadata.
pub fn getMeta(val: Value) Value {
    return switch (val.tag()) {
        .list => if (val.asList().meta) |m| m.* else Value.nil_val,
        .vector => if (val.asVector().meta) |m| m.* else Value.nil_val,
        .map => if (val.asMap().meta) |meta| meta.* else Value.nil_val,
        .hash_map => if (val.asHashMap().meta) |meta| meta.* else Value.nil_val,
        .set => if (val.asSet().meta) |m| m.* else Value.nil_val,
        .fn_val => if (val.asFn().meta) |m| m.* else Value.nil_val,
        .symbol => if (val.asSymbol().meta) |m| m.* else Value.nil_val,
        .atom => if (val.asAtom().meta) |m| m.* else Value.nil_val,
        .var_ref => if (val.asVarRef().meta) |m| Value.initMap(m) else Value.nil_val,
        else => Value.nil_val,
    };
}

/// Build a synthetic metadata map for a Var, merging struct fields with user meta.
/// JVM Clojure returns :name, :ns, :doc, :arglists, :macro, :added, :file, :line.
fn getVarMeta(allocator: Allocator, v: *const var_mod.Var) !Value {
    // Count entries: always :name and :ns, then optional fields
    var count: usize = 2; // :name, :ns
    if (v.doc != null) count += 1;
    if (v.arglists != null) count += 1;
    if (v.added != null) count += 1;
    if (v.file != null) count += 1;
    if (v.line > 0) count += 1;
    if (v.macro) count += 1;
    if (v.dynamic) count += 1;
    if (v.private) count += 1;

    // Count user meta entries
    var user_meta_len: usize = 0;
    if (v.meta) |m| user_meta_len = m.entries.len / 2;
    count += user_meta_len;

    const entries = allocator.alloc(Value, count * 2) catch return error.OutOfMemory;
    var i: usize = 0;

    // :name
    entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "name" });
    entries[i + 1] = Value.initSymbol(allocator, .{ .ns = null, .name = v.sym.name });
    i += 2;

    // :ns
    entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "ns" });
    entries[i + 1] = Value.initSymbol(allocator, .{ .ns = null, .name = v.ns_name });
    i += 2;

    if (v.doc) |doc| {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "doc" });
        entries[i + 1] = Value.initString(allocator, doc);
        i += 2;
    }
    if (v.arglists) |arglists| {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "arglists" });
        entries[i + 1] = Value.initString(allocator, arglists);
        i += 2;
    }
    if (v.added) |added| {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "added" });
        entries[i + 1] = Value.initString(allocator, added);
        i += 2;
    }
    if (v.file) |file| {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "file" });
        entries[i + 1] = Value.initString(allocator, file);
        i += 2;
    }
    if (v.line > 0) {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "line" });
        entries[i + 1] = Value.initInteger(@intCast(v.line));
        i += 2;
    }
    if (v.macro) {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "macro" });
        entries[i + 1] = Value.true_val;
        i += 2;
    }
    if (v.dynamic) {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "dynamic" });
        entries[i + 1] = Value.true_val;
        i += 2;
    }
    if (v.private) {
        entries[i] = Value.initKeyword(allocator, .{ .ns = null, .name = "private" });
        entries[i + 1] = Value.true_val;
        i += 2;
    }

    // Merge user meta
    if (v.meta) |m| {
        var j: usize = 0;
        while (j < m.entries.len) : (j += 2) {
            entries[i] = m.entries[j];
            entries[i + 1] = m.entries[j + 1];
            i += 2;
        }
    }

    const map = allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
    map.* = .{ .entries = entries[0..i] };
    return Value.initMap(map);
}

// ============================================================
// with-meta — return a copy of the value with new metadata
// ============================================================

pub fn withMetaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to with-meta", .{args.len});
    const obj = args[0];
    const new_meta = args[1];

    // Validate meta is a map or nil
    switch (new_meta.tag()) {
        .map, .hash_map, .nil => {},
        else => return err.setErrorFmt(.eval, .type_error, .{}, "with-meta expects a map for metadata, got {s}", .{@tagName(new_meta.tag())}),
    }

    const meta_ptr: ?*const Value = if (new_meta.tag() == .nil) null else blk: {
        const ptr = try allocator.create(Value);
        ptr.* = new_meta;
        break :blk ptr;
    };

    return switch (obj.tag()) {
        .list => blk: {
            const l = obj.asList();
            const new_list = try allocator.create(@import("../collections.zig").PersistentList);
            new_list.* = .{ .items = l.items, .meta = meta_ptr };
            break :blk Value.initList(new_list);
        },
        .vector => blk: {
            const v = obj.asVector();
            const new_vec = try allocator.create(@import("../collections.zig").PersistentVector);
            new_vec.* = .{ .items = v.items, .meta = meta_ptr };
            break :blk Value.initVector(new_vec);
        },
        .map => blk: {
            const m = obj.asMap();
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = m.entries, .meta = meta_ptr };
            break :blk Value.initMap(new_map);
        },
        .hash_map => blk: {
            const hm = obj.asHashMap();
            const new_hm = try allocator.create(@import("../collections.zig").PersistentHashMap);
            new_hm.* = .{
                .count = hm.count,
                .root = hm.root,
                .has_null = hm.has_null,
                .null_val = hm.null_val,
                .meta = meta_ptr,
            };
            break :blk Value.initHashMap(new_hm);
        },
        .set => blk: {
            const s = obj.asSet();
            const new_set = try allocator.create(@import("../collections.zig").PersistentHashSet);
            new_set.* = .{ .items = s.items, .meta = meta_ptr };
            break :blk Value.initSet(new_set);
        },
        .fn_val => blk: {
            const f = obj.asFn();
            const new_fn = try allocator.create(@import("../value.zig").Fn);
            new_fn.* = .{
                .proto = f.proto,
                .kind = f.kind,
                .closure_bindings = f.closure_bindings,
                .extra_arities = f.extra_arities,
                .meta = meta_ptr,
                .defining_ns = f.defining_ns,
            };
            break :blk Value.initFn(new_fn);
        },
        .symbol => Value.initSymbol(allocator, .{ .ns = obj.asSymbol().ns, .name = obj.asSymbol().name, .meta = meta_ptr }),
        // Lazy seq / cons — realize to list, then apply meta
        .lazy_seq, .cons => {
            const collections = @import("collections.zig");
            const realized = try collections.realizeValue(allocator, obj);
            const with_meta_args = [2]Value{ realized, new_meta };
            return withMetaFn(allocator, &with_meta_args);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "with-meta expects a collection, symbol, or fn, got {s}", .{@tagName(obj.tag())}),
    };
}

// ============================================================
// alter-meta! — mutate metadata on reference types (Atom)
// ============================================================

const bootstrap = @import("../bootstrap.zig");

pub fn alterMetaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to alter-meta!", .{args.len});
    const ref = args[0];
    const f = args[1];
    const extra = args[2..];

    // Build args for (f current-meta extra...)
    const call_args = try allocator.alloc(Value, 1 + extra.len);
    @memcpy(call_args[1..], extra);

    switch (ref.tag()) {
        .atom => {
            const a = ref.asAtom();
            call_args[0] = if (a.meta) |m| m.* else Value.nil_val;
            const new_meta = try bootstrap.callFnVal(allocator, f, call_args);
            switch (new_meta.tag()) {
                .map, .hash_map => {
                    const ptr = try allocator.create(Value);
                    ptr.* = new_meta;
                    a.meta = ptr;
                },
                .nil => a.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects a map for metadata, got {s}", .{@tagName(new_meta.tag())}),
            }
            return new_meta;
        },
        .var_ref => {
            const v = ref.asVarRef();
            call_args[0] = if (v.meta) |m| Value.initMap(m) else Value.nil_val;
            const new_meta = try bootstrap.callFnVal(allocator, f, call_args);
            switch (new_meta.tag()) {
                .map => v.meta = @constCast(new_meta.asMap()),
                .hash_map => {
                    // Var meta is *const PersistentArrayMap; convert hash_map to ArrayMap
                    const flat = try new_meta.asHashMap().toEntries(allocator);
                    const am = try allocator.create(PersistentArrayMap);
                    am.* = .{ .entries = flat };
                    v.meta = am;
                },
                .nil => v.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects a map for metadata, got {s}", .{@tagName(new_meta.tag())}),
            }
            return new_meta;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects an atom or var, got {s}", .{@tagName(ref.tag())}),
    }
}

// ============================================================
// reset-meta! — replace metadata on reference types (Atom)
// ============================================================

pub fn resetMetaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset-meta!", .{args.len});
    const ref = args[0];
    const new_meta = args[1];

    switch (ref.tag()) {
        .atom => {
            const a = ref.asAtom();
            switch (new_meta.tag()) {
                .map, .hash_map => {
                    const ptr = try allocator.create(Value);
                    ptr.* = new_meta;
                    a.meta = ptr;
                },
                .nil => a.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects a map for metadata, got {s}", .{@tagName(new_meta.tag())}),
            }
            return new_meta;
        },
        .var_ref => {
            const v = ref.asVarRef();
            switch (new_meta.tag()) {
                .map => v.meta = @constCast(new_meta.asMap()),
                .hash_map => {
                    // Var meta is *const PersistentArrayMap; convert hash_map to ArrayMap
                    const flat = try new_meta.asHashMap().toEntries(allocator);
                    const am = try allocator.create(PersistentArrayMap);
                    am.* = .{ .entries = flat };
                    v.meta = am;
                },
                .nil => v.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects a map for metadata, got {s}", .{@tagName(new_meta.tag())}),
            }
            return new_meta;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects an atom or var, got {s}", .{@tagName(ref.tag())}),
    }
}

// ============================================================
// Builtin definitions
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "meta",
        .func = &metaFn,
        .doc = "Returns the metadata of obj, returns nil if there is no metadata.",
        .arglists = "([obj])",
        .added = "1.0",
    },
    .{
        .name = "with-meta",
        .func = &withMetaFn,
        .doc = "Returns an object of the same type and value as obj, with map m as its metadata.",
        .arglists = "([obj m])",
        .added = "1.0",
    },
    .{
        .name = "alter-meta!",
        .func = &alterMetaFn,
        .doc = "Atomically sets the metadata of a reference to be (apply f its-current-meta args).",
        .arglists = "([ref f & args])",
        .added = "1.0",
    },
    .{
        .name = "reset-meta!",
        .func = &resetMetaFn,
        .doc = "Atomically resets the metadata of a reference to be m.",
        .arglists = "([ref m])",
        .added = "1.0",
    },
};

// ============================================================
// Tests
// ============================================================

test "meta on vector with no metadata returns nil" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const vec = @import("../collections.zig").PersistentVector{ .items = &items };
    const val = Value.initVector(&vec);
    const result = try metaFn(testing.allocator, &.{val});
    try testing.expect(result.tag() == .nil);
}

test "meta on integer returns nil" {
    const result = try metaFn(testing.allocator, &.{Value.initInteger(42)});
    try testing.expect(result.tag() == .nil);
}

test "meta on nil returns nil" {
    const result = try metaFn(testing.allocator, &.{Value.nil_val});
    try testing.expect(result.tag() == .nil);
}

test "with-meta on vector attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create vector [1 2]
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const vec = try alloc.create(@import("../collections.zig").PersistentVector);
    vec.* = .{ .items = &items };
    const val = Value.initVector(vec);

    // Create metadata map {:tag :int}
    const meta_entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "tag" }),
        Value.initKeyword(alloc, .{ .ns = null, .name = "int" }),
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };
    const meta_val = Value.initMap(meta_map);

    // with-meta
    const result = try withMetaFn(alloc, &.{ val, meta_val });

    // Result is a vector
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().count());

    // Metadata is attached
    const retrieved_meta = try metaFn(alloc, &.{result});
    try testing.expect(retrieved_meta.tag() == .map);
    const tag_val = retrieved_meta.asMap().get(Value.initKeyword(alloc, .{ .ns = null, .name = "tag" }));
    try testing.expect(tag_val != null);
    try testing.expect(tag_val.?.eql(Value.initKeyword(alloc, .{ .ns = null, .name = "int" })));
}

test "with-meta on list attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(10) };
    const list = try alloc.create(@import("../collections.zig").PersistentList);
    list.* = .{ .items = &items };
    const val = Value.initList(list);

    const meta_entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "source" }),
        Value.initString(alloc, "test"),
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ val, Value.initMap(meta_map) });
    try testing.expect(result.tag() == .list);

    const m = try metaFn(alloc, &.{result});
    try testing.expect(m.tag() == .map);
}

test "with-meta on map attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "a" }),
        Value.initInteger(1),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const meta_entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "type" }),
        Value.initKeyword(alloc, .{ .ns = null, .name = "config" }),
    };
    const mm = try alloc.create(PersistentArrayMap);
    mm.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ Value.initMap(m), Value.initMap(mm) });
    try testing.expect(result.tag() == .map);

    const meta_result = try metaFn(alloc, &.{result});
    try testing.expect(meta_result.tag() == .map);
}

test "with-meta on fn_val attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a dummy fn_val
    var dummy_proto: u8 = 0;
    const fn_struct = try alloc.create(@import("../value.zig").Fn);
    fn_struct.* = .{ .proto = &dummy_proto };
    const val = Value.initFn(fn_struct);

    const meta_entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "name" }),
        Value.initString(alloc, "my-fn"),
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ val, Value.initMap(meta_map) });
    try testing.expect(result.tag() == .fn_val);

    const m = try metaFn(alloc, &.{result});
    try testing.expect(m.tag() == .map);
}

test "with-meta with nil removes metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{Value.initInteger(1)};
    const vec = try alloc.create(@import("../collections.zig").PersistentVector);
    vec.* = .{ .items = &items };

    // First add metadata
    const meta_entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "x" }),
        Value.initInteger(1),
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const with = try withMetaFn(alloc, &.{ Value.initVector(vec), Value.initMap(meta_map) });

    // Now remove with nil
    const without = try withMetaFn(alloc, &.{ with, Value.nil_val });
    const m = try metaFn(alloc, &.{without});
    try testing.expect(m.tag() == .nil);
}

test "with-meta on integer is type error" {
    const result = withMetaFn(testing.allocator, &.{ Value.initInteger(42), Value.nil_val });
    try testing.expectError(error.TypeError, result);
}

test "meta arity error" {
    const result = metaFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}
