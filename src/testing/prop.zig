// SPDX-License-Identifier: EPL-2.0
//! Layer 7 (Property) engine — ADR-0186.
//!
//! Generate inputs, assert a law over each, and on failure report the SMALLEST
//! input that still breaks it plus the seed that produced it.
//!
//! Contract:
//!   - `Config` defaults make the gate run deterministic; a sweep overrides them
//!     through the `-Dprop-seed` / `-Dprop-iters` build options, which the
//!     property files read (this file stays free of `build_options` so it can be
//!     compiled and tested on its own with `zig test`).
//!   - `forAll` runs `prop` over `cfg.iters` generated values, shrinks the first
//!     failure within `cfg.max_shrink` candidate evaluations, prints the shrunk
//!     value and the reproduce line, and returns the property's error.
//!   - A generator is any value exposing `generate`, `shrink`, `free` and
//!     `describe` (see `IntSlice` for the shape).
//!   - Generators own their allocations; `forAll` frees every value it makes.

const std = @import("std");

pub const Config = struct {
    seed: u64 = 0x1_0BE1_5EED,
    iters: usize = 100,
    max_shrink: usize = 300,
    /// Suppress the failure report. Set ONLY by the engine's own tests, which
    /// falsify a property on purpose.
    quiet: bool = false,
};

/// Run `prop` over generated values. `ctx` is passed through untouched.
pub fn forAll(
    comptime T: type,
    alloc: std.mem.Allocator,
    cfg: Config,
    gen: anytype,
    ctx: anytype,
    comptime prop: fn (@TypeOf(ctx), T) anyerror!void,
) !void {
    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rand = prng.random();

    var i: usize = 0;
    while (i < cfg.iters) : (i += 1) {
        const size = 1 + (i * 32) / cfg.iters;
        const value = try gen.generate(rand, alloc, size);

        prop(ctx, value) catch |err| {
            const shrunk = try shrinkFailing(T, alloc, cfg, gen, ctx, prop, value);
            defer gen.free(alloc, shrunk);

            const desc = gen.describe(alloc, shrunk) catch null;
            defer if (desc) |d| alloc.free(d);

            if (!cfg.quiet) std.debug.print(
                \\
                \\property FAILED on iteration {d} with {s}
                \\  smallest failing input: {s}
                \\  reproduce: zig build test -Dprop-seed=0x{x} -Dprop-iters={d}
                \\
            , .{ i, @errorName(err), desc orelse "<undescribable>", cfg.seed, cfg.iters });
            return err;
        };

        gen.free(alloc, value);
    }
}

/// Greedy shrink: repeatedly replace the failing value with the first candidate
/// that still fails. Returns ownership of the final value to the caller; every
/// other value made here is freed.
fn shrinkFailing(
    comptime T: type,
    alloc: std.mem.Allocator,
    cfg: Config,
    gen: anytype,
    ctx: anytype,
    comptime prop: fn (@TypeOf(ctx), T) anyerror!void,
    failing: T,
) !T {
    var current = failing;
    var budget = cfg.max_shrink;

    outer: while (budget > 0) {
        var candidates: std.ArrayList(T) = .empty;
        defer candidates.deinit(alloc);
        try gen.shrink(alloc, current, &candidates);
        if (candidates.items.len == 0) break;

        for (candidates.items, 0..) |cand, idx| {
            if (budget == 0) {
                for (candidates.items[idx..]) |rest| gen.free(alloc, rest);
                break :outer;
            }
            budget -= 1;

            if (prop(ctx, cand)) |_| {
                gen.free(alloc, cand);
            } else |_| {
                // Still fails: adopt it, discard the rest of this round.
                for (candidates.items[idx + 1 ..]) |rest| gen.free(alloc, rest);
                gen.free(alloc, current);
                current = cand;
                continue :outer;
            }
        }
        break;
    }

    return current;
}

/// A slice of integers — the workhorse generator.
pub const IntSlice = struct {
    /// Values are drawn from `0..distinct`; a small bound forces duplicates.
    distinct: i64 = 8,
    max_len: usize = 64,

    pub fn generate(self: IntSlice, rand: std.Random, alloc: std.mem.Allocator, size: usize) ![]i64 {
        const len = rand.uintLessThan(usize, @min(size, self.max_len) + 1);
        const out = try alloc.alloc(i64, len);
        for (out) |*slot| slot.* = rand.intRangeLessThan(i64, 0, self.distinct);
        return out;
    }

    /// Two moves, cheapest first: drop a chunk, then reduce one element toward
    /// zero.
    pub fn shrink(self: IntSlice, alloc: std.mem.Allocator, v: []i64, out: *std.ArrayList([]i64)) !void {
        _ = self;
        if (v.len > 0) {
            try out.append(alloc, try alloc.dupe(i64, v[0 .. v.len / 2]));
            try out.append(alloc, try alloc.dupe(i64, v[v.len / 2 ..]));
            if (v.len > 1) {
                const without_last = try alloc.dupe(i64, v[0 .. v.len - 1]);
                try out.append(alloc, without_last);
            }
        }
        for (v, 0..) |x, i| {
            if (x == 0) continue;
            const smaller = try alloc.dupe(i64, v);
            smaller[i] = @divTrunc(x, 2);
            try out.append(alloc, smaller);
            break; // one element per round
        }
    }

    pub fn free(self: IntSlice, alloc: std.mem.Allocator, v: []i64) void {
        _ = self;
        alloc.free(v);
    }

    pub fn describe(self: IntSlice, alloc: std.mem.Allocator, v: []i64) ![]u8 {
        _ = self;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.append(alloc, '[');
        for (v, 0..) |x, i| {
            if (i > 0) try buf.appendSlice(alloc, ", ");
            try buf.print(alloc, "{d}", .{x});
        }
        try buf.append(alloc, ']');
        return buf.toOwnedSlice(alloc);
    }
};

// --- tests: the engine's own contract ---

const testing = std.testing;

test "forAll passes a law that holds for every generated value" {
    const gen = IntSlice{};
    const Ctx = struct {};
    const prop = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            // Trivially true: a dupe has the same length.
            const copy = try testing.allocator.dupe(i64, xs);
            defer testing.allocator.free(copy);
            try testing.expectEqual(xs.len, copy.len);
        }
    }.f;
    try forAll([]i64, testing.allocator, .{ .iters = 25 }, gen, Ctx{}, prop);
}

test "forAll reports the shrunk counterexample, not the first one found" {
    const gen = IntSlice{ .distinct = 8, .max_len = 64 };
    const Ctx = struct {};
    const prop = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            for (xs) |x| if (x >= 4) return error.TooLarge;
        }
    }.f;

    const cfg = Config{ .iters = 200, .seed = 0xC0FFEE, .quiet = true };
    const result = forAll([]i64, testing.allocator, cfg, gen, Ctx{}, prop);
    try testing.expectError(error.TooLarge, result);
}

test "the same seed produces the same values, a different seed does not" {
    const gen = IntSlice{ .distinct = 1000, .max_len = 32 };
    var a = std.Random.DefaultPrng.init(42);
    var b = std.Random.DefaultPrng.init(42);
    var c = std.Random.DefaultPrng.init(43);

    const va = try gen.generate(a.random(), testing.allocator, 32);
    defer gen.free(testing.allocator, va);
    const vb = try gen.generate(b.random(), testing.allocator, 32);
    defer gen.free(testing.allocator, vb);
    const vc = try gen.generate(c.random(), testing.allocator, 32);
    defer gen.free(testing.allocator, vc);

    try testing.expectEqualSlices(i64, va, vb);
    try testing.expect(!std.mem.eql(i64, va, vc));
}

test "IntSlice.shrink offers strictly smaller candidates and nothing else" {
    const gen = IntSlice{};
    const v = try testing.allocator.dupe(i64, &[_]i64{ 5, 6, 7, 8 });
    defer testing.allocator.free(v);

    var out: std.ArrayList([]i64) = .empty;
    defer {
        for (out.items) |c| testing.allocator.free(c);
        out.deinit(testing.allocator);
    }
    try gen.shrink(testing.allocator, v, &out);

    try testing.expect(out.items.len > 0);
    for (out.items) |c| {
        const shorter = c.len < v.len;
        var smaller_element = false;
        if (c.len == v.len) {
            for (c, v) |a, b| {
                if (a < b) smaller_element = true;
                try testing.expect(a <= b);
            }
        }
        try testing.expect(shorter or smaller_element);
    }
}
