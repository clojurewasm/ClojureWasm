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

pub fn metaFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to meta", .{args.len});
    return getMeta(args[0]);
}

/// Extract metadata from a Value. Returns nil if the value has no metadata
/// or doesn't support metadata.
pub fn getMeta(val: Value) Value {
    return switch (val) {
        .list => |l| if (l.meta) |m| m.* else .nil,
        .vector => |v| if (v.meta) |m| m.* else .nil,
        .map => |m| if (m.meta) |meta| meta.* else .nil,
        .set => |s| if (s.meta) |m| m.* else .nil,
        .fn_val => |f| if (f.meta) |m| m.* else .nil,
        .atom => |a| if (a.meta) |m| m.* else .nil,
        .var_ref => |v| if (v.meta) |m| Value{ .map = m } else .nil,
        else => .nil,
    };
}

// ============================================================
// with-meta — return a copy of the value with new metadata
// ============================================================

pub fn withMetaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to with-meta", .{args.len});
    const obj = args[0];
    const new_meta = args[1];

    // Validate meta is a map or nil
    switch (new_meta) {
        .map, .nil => {},
        else => return err.setErrorFmt(.eval, .type_error, .{}, "with-meta expects a map for metadata, got {s}", .{@tagName(new_meta)}),
    }

    const meta_ptr: ?*const Value = if (new_meta == .nil) null else blk: {
        const ptr = try allocator.create(Value);
        ptr.* = new_meta;
        break :blk ptr;
    };

    return switch (obj) {
        .list => |l| blk: {
            const new_list = try allocator.create(@import("../collections.zig").PersistentList);
            new_list.* = .{ .items = l.items, .meta = meta_ptr };
            break :blk Value{ .list = new_list };
        },
        .vector => |v| blk: {
            const new_vec = try allocator.create(@import("../collections.zig").PersistentVector);
            new_vec.* = .{ .items = v.items, .meta = meta_ptr };
            break :blk Value{ .vector = new_vec };
        },
        .map => |m| blk: {
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = m.entries, .meta = meta_ptr };
            break :blk Value{ .map = new_map };
        },
        .set => |s| blk: {
            const new_set = try allocator.create(@import("../collections.zig").PersistentHashSet);
            new_set.* = .{ .items = s.items, .meta = meta_ptr };
            break :blk Value{ .set = new_set };
        },
        .fn_val => |f| blk: {
            const new_fn = try allocator.create(@import("../value.zig").Fn);
            new_fn.* = .{
                .proto = f.proto,
                .kind = f.kind,
                .closure_bindings = f.closure_bindings,
                .extra_arities = f.extra_arities,
                .meta = meta_ptr,
            };
            break :blk Value{ .fn_val = new_fn };
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "with-meta expects a collection or fn, got {s}", .{@tagName(obj)}),
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

    switch (ref) {
        .atom => |a| {
            call_args[0] = if (a.meta) |m| m.* else .nil;
            const new_meta = try bootstrap.callFnVal(allocator, f, call_args);
            switch (new_meta) {
                .map => {
                    const ptr = try allocator.create(Value);
                    ptr.* = new_meta;
                    a.meta = ptr;
                },
                .nil => a.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects a map for metadata, got {s}", .{@tagName(new_meta)}),
            }
            return new_meta;
        },
        .var_ref => |v| {
            call_args[0] = if (v.meta) |m| Value{ .map = m } else .nil;
            const new_meta = try bootstrap.callFnVal(allocator, f, call_args);
            switch (new_meta) {
                .map => |m| v.meta = @constCast(m),
                .nil => v.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects a map for metadata, got {s}", .{@tagName(new_meta)}),
            }
            return new_meta;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-meta! expects an atom or var, got {s}", .{@tagName(ref)}),
    }
}

// ============================================================
// reset-meta! — replace metadata on reference types (Atom)
// ============================================================

pub fn resetMetaFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset-meta!", .{args.len});
    const ref = args[0];
    const new_meta = args[1];

    switch (ref) {
        .atom => |a| {
            switch (new_meta) {
                .map => {
                    const ptr = try allocator.create(Value);
                    ptr.* = new_meta;
                    a.meta = ptr;
                },
                .nil => a.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects a map for metadata, got {s}", .{@tagName(new_meta)}),
            }
            return new_meta;
        },
        .var_ref => |v| {
            switch (new_meta) {
                .map => |m| v.meta = @constCast(m),
                .nil => v.meta = null,
                else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects a map for metadata, got {s}", .{@tagName(new_meta)}),
            }
            return new_meta;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "reset-meta! expects an atom or var, got {s}", .{@tagName(ref)}),
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
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = @import("../collections.zig").PersistentVector{ .items = &items };
    const val = Value{ .vector = &vec };
    const result = try metaFn(testing.allocator, &.{val});
    try testing.expect(result == .nil);
}

test "meta on integer returns nil" {
    const result = try metaFn(testing.allocator, &.{Value{ .integer = 42 }});
    try testing.expect(result == .nil);
}

test "meta on nil returns nil" {
    const result = try metaFn(testing.allocator, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "with-meta on vector attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create vector [1 2]
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = try alloc.create(@import("../collections.zig").PersistentVector);
    vec.* = .{ .items = &items };
    const val = Value{ .vector = vec };

    // Create metadata map {:tag :int}
    const meta_entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "tag" } },
        .{ .keyword = .{ .ns = null, .name = "int" } },
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };
    const meta_val = Value{ .map = meta_map };

    // with-meta
    const result = try withMetaFn(alloc, &.{ val, meta_val });

    // Result is a vector
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.count());

    // Metadata is attached
    const retrieved_meta = try metaFn(alloc, &.{result});
    try testing.expect(retrieved_meta == .map);
    const tag_val = retrieved_meta.map.get(.{ .keyword = .{ .ns = null, .name = "tag" } });
    try testing.expect(tag_val != null);
    try testing.expect(tag_val.?.eql(.{ .keyword = .{ .ns = null, .name = "int" } }));
}

test "with-meta on list attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 10 } };
    const list = try alloc.create(@import("../collections.zig").PersistentList);
    list.* = .{ .items = &items };
    const val = Value{ .list = list };

    const meta_entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "source" } },
        .{ .string = "test" },
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ val, Value{ .map = meta_map } });
    try testing.expect(result == .list);

    const m = try metaFn(alloc, &.{result});
    try testing.expect(m == .map);
}

test "with-meta on map attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "a" } },
        .{ .integer = 1 },
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const meta_entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "type" } },
        .{ .keyword = .{ .ns = null, .name = "config" } },
    };
    const mm = try alloc.create(PersistentArrayMap);
    mm.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ Value{ .map = m }, Value{ .map = mm } });
    try testing.expect(result == .map);

    const meta_result = try metaFn(alloc, &.{result});
    try testing.expect(meta_result == .map);
}

test "with-meta on fn_val attaches metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a dummy fn_val
    var dummy_proto: u8 = 0;
    const fn_struct = try alloc.create(@import("../value.zig").Fn);
    fn_struct.* = .{ .proto = &dummy_proto };
    const val = Value{ .fn_val = fn_struct };

    const meta_entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "name" } },
        .{ .string = "my-fn" },
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const result = try withMetaFn(alloc, &.{ val, Value{ .map = meta_map } });
    try testing.expect(result == .fn_val);

    const m = try metaFn(alloc, &.{result});
    try testing.expect(m == .map);
}

test "with-meta with nil removes metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{.{ .integer = 1 }};
    const vec = try alloc.create(@import("../collections.zig").PersistentVector);
    vec.* = .{ .items = &items };

    // First add metadata
    const meta_entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "x" } },
        .{ .integer = 1 },
    };
    const meta_map = try alloc.create(PersistentArrayMap);
    meta_map.* = .{ .entries = &meta_entries };

    const with = try withMetaFn(alloc, &.{ Value{ .vector = vec }, Value{ .map = meta_map } });

    // Now remove with nil
    const without = try withMetaFn(alloc, &.{ with, Value.nil });
    const m = try metaFn(alloc, &.{without});
    try testing.expect(m == .nil);
}

test "with-meta on integer is type error" {
    const result = withMetaFn(testing.allocator, &.{ Value{ .integer = 42 }, Value.nil });
    try testing.expectError(error.TypeError, result);
}

test "meta arity error" {
    const result = metaFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}
