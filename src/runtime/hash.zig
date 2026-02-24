// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Value hashing — Murmur3-based hash functions for CW values.
//!
//! Extracted from lang/builtins/predicates.zig and lang/builtins/misc.zig (D109 Z3).
//! Lives in Layer 0 (runtime/) so that collections.zig can use it without
//! importing from lang/.

const Value = @import("value.zig").Value;

// ============================================================
// Murmur3 constants and helpers
// ============================================================

const M3_C1: i32 = @bitCast(@as(u32, 0xcc9e2d51));
const M3_C2: i32 = @bitCast(@as(u32, 0x1b873593));

fn mixK1(k: i32) i32 {
    var k1: u32 = @bitCast(k);
    k1 *%= @bitCast(M3_C1);
    k1 = @import("std").math.rotl(u32, k1, 15);
    k1 *%= @bitCast(M3_C2);
    return @bitCast(k1);
}

fn mixH1(h: i32, k1: i32) i32 {
    var h1: u32 = @bitCast(h);
    h1 ^= @as(u32, @bitCast(k1));
    h1 = @import("std").math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% @as(u32, 0xe6546b64);
    return @bitCast(h1);
}

fn fmix(h: i32, length: i32) i32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0x85ebca6b)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 13));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0xc2b2ae35)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    return h1;
}

pub fn mixCollHash(hash_val: i32, count: i32) i32 {
    var h1: i32 = 0; // seed
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

// ============================================================
// Value hashing
// ============================================================

fn stringHash(s: []const u8) i64 {
    var h: i64 = 0;
    for (s) |c| {
        h = h *% 31 +% @as(i64, c);
    }
    return h;
}

pub fn computeHash(v: Value) i64 {
    return switch (v.tag()) {
        .nil => 0,
        .boolean => if (v.asBoolean()) @as(i64, 1231) else @as(i64, 1237),
        .integer => v.asInteger(),
        .float => @as(i64, @bitCast(@as(u64, @bitCast(v.asFloat())))),
        .big_int => blk: {
            const bi = v.asBigInt();
            if (bi.toI64()) |i| break :blk i;
            var h: i64 = 0x9e3779b9;
            const c = bi.managed.toConst();
            for (c.limbs[0..c.limbs.len]) |limb| {
                h = h *% 31 +% @as(i64, @bitCast(limb));
            }
            if (!c.positive) h = ~h;
            break :blk h;
        },
        .big_decimal => @as(i64, @intFromFloat(v.asBigDecimal().toF64() * 1000003)),
        .char => @as(i64, @intCast(v.asChar())),
        .string => stringHash(v.asString()),
        .keyword => blk: {
            const kw = v.asKeyword();
            var h: i64 = 0x9e3779b9;
            if (kw.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(kw.name);
            break :blk h;
        },
        .symbol => blk: {
            const sym = v.asSymbol();
            var h: i64 = 0x517cc1b7;
            if (sym.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(sym.name);
            break :blk h;
        },
        .vector => blk: {
            const items = v.asVector().items;
            var h: i32 = 1;
            for (items) |item| {
                h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, mixCollHash(h, @intCast(items.len)));
        },
        .list => blk: {
            const items = v.asList().items;
            var h: i32 = 1;
            for (items) |item| {
                h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, mixCollHash(h, @intCast(items.len)));
        },
        .map => blk: {
            const entries = v.asMap().entries;
            var h: i32 = 0;
            var i: usize = 0;
            while (i + 1 < entries.len) : (i += 2) {
                const kh: i32 = @truncate(computeHash(entries[i]));
                const vh: i32 = @truncate(computeHash(entries[i + 1]));
                h +%= kh ^ vh;
            }
            break :blk @as(i64, mixCollHash(h, @intCast(entries.len / 2)));
        },
        .set => blk: {
            const items = v.asSet().items;
            var h: i32 = 0;
            for (items) |item| {
                h +%= @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, mixCollHash(h, @intCast(items.len)));
        },
        .cons => blk: {
            var h: i32 = 1;
            var n: i32 = 0;
            var cur = v;
            while (true) {
                const tag = cur.tag();
                if (tag == .cons) {
                    const cell = cur.asCons();
                    h = h *% 31 +% @as(i32, @truncate(computeHash(cell.first)));
                    n += 1;
                    cur = cell.rest;
                } else if (tag == .list) {
                    for (cur.asList().items) |item| {
                        h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
                        n += 1;
                    }
                    break;
                } else if (tag == .nil) {
                    break;
                } else {
                    break;
                }
            }
            break :blk @as(i64, mixCollHash(h, n));
        },
        .lazy_seq => blk: {
            const ls = v.asLazySeq();
            if (ls.realized) |realized| {
                break :blk computeHash(realized);
            }
            break :blk 42;
        },
        else => 42,
    };
}
