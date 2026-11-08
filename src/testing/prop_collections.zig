// SPDX-License-Identifier: EPL-2.0
//! Layer 7 (Property) — laws the persistent collections must obey for any
//! sequence of operations. ADR-0186.
//!
//! Each property drives the persistent structure and a naive model (a plain
//! Zig array) with the same operations and requires them to agree.
//!
//! Representation boundaries the generator sizes straddle: ArrayMap ->
//! PersistentHashMap at 16 entries, set at 8, vector tail at 32, trie level
//! at 1057.

const std = @import("std");
const prop = @import("prop.zig");
const build_options = @import("build_options");

const value_mod = @import("../runtime/value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const map_collection = @import("../runtime/collection/map.zig");
const set_collection = @import("../runtime/collection/set.zig");
const vector_collection = @import("../runtime/collection/vector.zig");

const testing = std.testing;

/// Gate defaults, overridable for a sweep: `zig build test -Dprop-seed=0x… -Dprop-iters=…`.
fn config() prop.Config {
    return .{ .seed = build_options.prop_seed, .iters = build_options.prop_iters };
}

/// A fresh runtime per property evaluation.
const Fixture = struct {
    fn run(comptime body: fn (*Runtime, []i64) anyerror!void, xs: []i64) anyerror!void {
        var th = std.Io.Threaded.init(testing.allocator, .{});
        defer th.deinit();
        var rt = Runtime.init(th.io(), testing.allocator);
        defer rt.deinit();
        try body(&rt, xs);
    }
};

/// The model: last write wins, in insertion order. Returns the distinct keys in
/// first-seen order plus the value each key ended up with.
const MapModel = struct {
    keys: std.ArrayList(i64) = .empty,
    vals: std.ArrayList(i64) = .empty,

    fn put(self: *MapModel, alloc: std.mem.Allocator, k: i64, v: i64) !void {
        for (self.keys.items, 0..) |existing, i| {
            if (existing == k) {
                self.vals.items[i] = v;
                return;
            }
        }
        try self.keys.append(alloc, k);
        try self.vals.append(alloc, v);
    }

    fn deinit(self: *MapModel, alloc: std.mem.Allocator) void {
        self.keys.deinit(alloc);
        self.vals.deinit(alloc);
    }
};

// --- map ---

test "property: a map agrees with a last-write-wins model on every key" {
    const gen = prop.IntSlice{ .distinct = 12, .max_len = 64 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var model: MapModel = .{};
            defer model.deinit(testing.allocator);

            var m = map_collection.empty();
            for (xs, 0..) |k, i| {
                const v: i64 = @intCast(i);
                m = try map_collection.assoc(rt, m, Value.initInteger(k), Value.initInteger(v));
                try model.put(testing.allocator, k, v);
            }

            try testing.expectEqual(@as(u32, @intCast(model.keys.items.len)), map_collection.count(m));
            for (model.keys.items, model.vals.items) |k, v| {
                try testing.expect(try map_collection.contains(m, Value.initInteger(k)));
                const got = try map_collection.get(m, Value.initInteger(k));
                try testing.expectEqual(v, @as(i64, got.asInteger()));
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: a map's contents do not depend on the order the keys arrived" {
    const gen = prop.IntSlice{ .distinct = 40, .max_len = 48 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var forward = map_collection.empty();
            for (xs) |k| forward = try map_collection.assoc(rt, forward, Value.initInteger(k), Value.initInteger(k * 3));

            var backward = map_collection.empty();
            var i = xs.len;
            while (i > 0) {
                i -= 1;
                backward = try map_collection.assoc(rt, backward, Value.initInteger(xs[i]), Value.initInteger(xs[i] * 3));
            }

            try testing.expectEqual(map_collection.count(forward), map_collection.count(backward));
            try testing.expect(map_collection.contentEq(forward, backward));
            try testing.expectEqual(map_collection.contentHash(forward), map_collection.contentHash(backward));
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: dissoc undoes assoc, one key at a time, in any order" {
    const gen = prop.IntSlice{ .distinct = 30, .max_len = 48 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var m = map_collection.empty();
            for (xs) |k| m = try map_collection.assoc(rt, m, Value.initInteger(k), Value.initInteger(k));

            var seen: std.ArrayList(i64) = .empty;
            defer seen.deinit(testing.allocator);
            var i = xs.len;
            while (i > 0) {
                i -= 1;
                const k = xs[i];
                var already = false;
                for (seen.items) |s| {
                    if (s == k) already = true;
                }
                if (already) continue;
                try seen.append(testing.allocator, k);

                const before = map_collection.count(m);
                m = try map_collection.dissoc(rt, m, Value.initInteger(k));
                try testing.expectEqual(before - 1, map_collection.count(m));
                try testing.expect(!try map_collection.contains(m, Value.initInteger(k)));
            }
            try testing.expectEqual(@as(u32, 0), map_collection.count(m));
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: every entry survives the ArrayMap -> PersistentHashMap promotion" {
    const gen = prop.IntSlice{ .distinct = 64, .max_len = 40 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var m = map_collection.empty();
            var inserted: std.ArrayList(i64) = .empty;
            defer inserted.deinit(testing.allocator);

            for (xs, 0..) |_, i| {
                const k: i64 = @intCast(i); // distinct by construction
                m = try map_collection.assoc(rt, m, Value.initInteger(k), Value.initInteger(k * 7));
                try inserted.append(testing.allocator, k);

                try testing.expectEqual(@as(u32, @intCast(inserted.items.len)), map_collection.count(m));
                for (inserted.items) |key| {
                    const got = try map_collection.get(m, Value.initInteger(key));
                    try testing.expectEqual(key * 7, @as(i64, got.asInteger()));
                }
            }

            // The ArrayMap -> PersistentHashMap ceiling is 16 entries.
            if (inserted.items.len > 16) {
                try testing.expect(m.tag() == .hash_map);
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

// --- set ---

test "property: a set holds exactly the distinct elements conj'd into it" {
    const gen = prop.IntSlice{ .distinct = 24, .max_len = 64 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var distinct: std.ArrayList(i64) = .empty;
            defer distinct.deinit(testing.allocator);

            var s = set_collection.empty();
            for (xs) |x| {
                s = try set_collection.conj(rt, s, Value.initInteger(x));
                var already = false;
                for (distinct.items) |d| {
                    if (d == x) already = true;
                }
                if (!already) try distinct.append(testing.allocator, x);
            }

            try testing.expectEqual(@as(u32, @intCast(distinct.items.len)), set_collection.count(s));
            for (distinct.items) |d| try testing.expect(try set_collection.contains(s, Value.initInteger(d)));

            // disj is conj's inverse over the distinct elements.
            for (distinct.items) |d| s = try set_collection.disj(rt, s, Value.initInteger(d));
            try testing.expectEqual(@as(u32, 0), set_collection.count(s));
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

// --- vector ---

test "property: a vector reads back what was conj'd, index by index" {
    const gen = prop.IntSlice{ .distinct = 1000, .max_len = 96 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var v = vector_collection.empty();
            for (xs) |x| v = try vector_collection.conj(rt, v, Value.initInteger(x));

            try testing.expectEqual(@as(u32, @intCast(xs.len)), vector_collection.count(v));
            for (xs, 0..) |x, i| {
                try testing.expectEqual(x, @as(i64, vector_collection.nth(v, @intCast(i)).asInteger()));
            }

            // fromSlice must agree with repeated conj — two construction paths,
            // one value.
            var built: std.ArrayList(Value) = .empty;
            defer built.deinit(testing.allocator);
            for (xs) |x| try built.append(testing.allocator, Value.initInteger(x));
            const w = try vector_collection.fromSlice(rt, built.items);
            try testing.expectEqual(vector_collection.count(v), vector_collection.count(w));
            for (xs, 0..) |_, i| {
                try testing.expectEqual(
                    @as(i64, vector_collection.nth(v, @intCast(i)).asInteger()),
                    @as(i64, vector_collection.nth(w, @intCast(i)).asInteger()),
                );
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: pop undoes conj all the way back to empty" {
    const gen = prop.IntSlice{ .distinct = 1000, .max_len = 96 };
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            var v = vector_collection.empty();
            for (xs) |x| v = try vector_collection.conj(rt, v, Value.initInteger(x));

            var i = xs.len;
            while (i > 0) {
                i -= 1;
                try testing.expectEqual(xs[i], @as(i64, vector_collection.nth(v, @intCast(i)).asInteger()));
                v = try vector_collection.pop(rt, v);
                try testing.expectEqual(@as(u32, @intCast(i)), vector_collection.count(v));
            }
            try testing.expectEqual(@as(u32, 0), vector_collection.count(v));
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: pop collapses a DEEP trie correctly, level by level" {
    // popTail recurses only past one trie level: tail (32) + a full level
    // (32*32) = 1057 elements. These sizes straddle that transition.
    const deep_sizes = [_]u32{ 1024, 1056, 1057, 1088, 2048, 2080 };
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    for (deep_sizes) |n| {
        var v = vector_collection.empty();
        var i: u32 = 0;
        while (i < n) : (i += 1) v = try vector_collection.conj(&rt, v, Value.initInteger(@intCast(i)));
        try testing.expectEqual(n, vector_collection.count(v));

        var remaining = n;
        while (remaining > 0) {
            remaining -= 1;
            try testing.expectEqual(
                @as(i64, @intCast(remaining)),
                @as(i64, vector_collection.nth(v, remaining).asInteger()),
            );
            v = try vector_collection.pop(&rt, v);
            try testing.expectEqual(remaining, vector_collection.count(v));
            if (remaining > 0) {
                try testing.expectEqual(@as(i64, 0), @as(i64, vector_collection.nth(v, 0).asInteger()));
                const mid = remaining / 2;
                try testing.expectEqual(@as(i64, @intCast(mid)), @as(i64, vector_collection.nth(v, mid).asInteger()));
            }
        }
    }
}
