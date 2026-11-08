// SPDX-License-Identifier: EPL-2.0
//! Murmur3 hash for ClojureWasm — Clojure-compatible hash values.
//!
//! Mirrors `clojure.lang.Murmur3` in Clojure JVM. All multiplications
//! and additions wrap (`*%` / `+%`) to match Java's `int` overflow
//! semantics; that's load-bearing for value hashes to round-trip
//! correctly across runtimes (e.g. when comparing `hash` results in a
//! shared test).
//!
//! `hashString` hashes UTF-8 bytes directly, **not** the UTF-16 code
//! units that Clojure JVM hashes. This matches v1's choice and trades
//! exact-bit compatibility for working in a Wasm/edge environment
//! where UTF-8 is the natural encoding.

const std = @import("std");
const utf8_total = @import("utf8_total.zig");

const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const SEED: u32 = 0;

fn mixK1(k: u32) u32 {
    var k1 = k;
    k1 *%= C1;
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= C2;
    return k1;
}

fn mixH1(h: u32, k1: u32) u32 {
    var h1 = h;
    h1 ^= k1;
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% 0xe6546b64;
    return h1;
}

fn fmix(h: u32, length: u32) u32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= h1 >> 16;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    h1 *%= 0xc2b2ae35;
    h1 ^= h1 >> 16;
    return h1;
}

/// Hash a 32-bit integer. `0` hashes to `0` (Clojure compat).
pub fn hashInt(input: i32) u32 {
    if (input == 0) return 0;
    const k1 = mixK1(@bitCast(input));
    const h1 = mixH1(SEED, k1);
    return fmix(h1, 4);
}

/// Hash a 64-bit integer. `0` hashes to `0`.
pub fn hashLong(input: i64) u32 {
    if (input == 0) return 0;
    const bits: u64 = @bitCast(input);
    const low: u32 = @truncate(bits);
    const high: u32 = @truncate(bits >> 32);
    var h1 = mixH1(SEED, mixK1(low));
    h1 = mixH1(h1, mixK1(high));
    return fmix(h1, 8);
}

/// Hash a UTF-8 byte string.
pub fn hashString(input: []const u8) u32 {
    var h1: u32 = SEED;
    const nblocks = input.len / 4;

    for (0..nblocks) |i| {
        const offset = i * 4;
        const k: u32 = @as(u32, input[offset]) |
            (@as(u32, input[offset + 1]) << 8) |
            (@as(u32, input[offset + 2]) << 16) |
            (@as(u32, input[offset + 3]) << 24);
        h1 = mixH1(h1, mixK1(k));
    }

    const tail_offset = nblocks * 4;
    var k1: u32 = 0;
    const tail_len = input.len - tail_offset;
    if (tail_len >= 3) k1 ^= @as(u32, input[tail_offset + 2]) << 16;
    if (tail_len >= 2) k1 ^= @as(u32, input[tail_offset + 1]) << 8;
    if (tail_len >= 1) {
        k1 ^= @as(u32, input[tail_offset]);
        h1 ^= mixK1(k1);
    }

    return fmix(h1, @truncate(input.len));
}

/// JVM `clojure.lang.Murmur3.hashUnencodedChars` bit-parity: Murmur3 over
/// the string's UTF-16 CODE UNITS (surrogate pairs for astral codepoints),
/// two units per 32-bit block, `fmix` over `2 * unit-count` bytes. Distinct
/// from `hashString` (cljw-native UTF-8 bytes, AD-009) — this serves the
/// `Murmur3/hashUnencodedChars` static (data.xml), where JVM value-parity is
/// achievable because the input is pure code units, not value identity (D-376).
/// Total over arbitrary bytes: ill-formed spans hash as U+FFFD, the unit the
/// JVM's `String(bytes, UTF_8)` holds for them (`utf8_total`).
pub fn hashUnencodedChars(utf8: []const u8) u32 {
    var h1: u32 = SEED;
    var unit_count: u32 = 0;
    var pending: ?u32 = null;
    var it = utf8_total.Iterator.init(utf8);
    while (it.nextCodepoint()) |cp| {
        var units: [2]u32 = .{ @as(u32, cp), 0 };
        var n: usize = 1;
        if (cp >= 0x10000) {
            const v: u32 = @as(u32, cp) - 0x10000;
            units[0] = 0xD800 + (v >> 10);
            units[1] = 0xDC00 + (v & 0x3FF);
            n = 2;
        }
        for (units[0..n]) |u| {
            unit_count += 1;
            if (pending) |lo| {
                h1 = mixH1(h1, mixK1(lo | (u << 16)));
                pending = null;
            } else {
                pending = u;
            }
        }
    }
    if (pending) |lo| h1 ^= mixK1(lo);
    return fmix(h1, 2 *% unit_count);
}

/// Java `String.hashCode`: the 31-fold over UTF-16 code units (surrogate
/// pairs for astral codepoints). Feeds `hashInt` for clj's String hasheq
/// and `hashCombine` for the Symbol/Keyword hasheq ns part. Total over
/// arbitrary bytes: ill-formed spans fold as U+FFFD (`utf8_total`), so the
/// result equals the JVM's `new String(bytes, UTF_8).hashCode()`.
pub fn javaStringHashCode(utf8: []const u8) i32 {
    var h: i32 = 0;
    var it = utf8_total.Iterator.init(utf8);
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v: u32 = @as(u32, cp) - 0x10000;
            h = h *% 31 +% @as(i32, @intCast(0xD800 + (v >> 10)));
            h = h *% 31 +% @as(i32, @intCast(0xDC00 + (v & 0x3FF)));
        } else {
            h = h *% 31 +% @as(i32, @intCast(cp));
        }
    }
    return h;
}

/// `java.math.BigInteger.hashCode` for an i64-fitting value: the 31-fold
/// over the magnitude's 32-bit words, times the signum. Backs clj's Ratio
/// (num.hashCode ^ den.hashCode) and normalized-BigDecimal
/// (31*unscaled.hashCode + scale) hasheq values.
pub fn javaBigIntegerHashCodeI64(v: i64) i32 {
    if (v == 0) return 0;
    const neg = v < 0;
    const abs: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v);
    const hi: u32 = @truncate(abs >> 32);
    const lo: u32 = @truncate(abs);
    var h: i32 = 0;
    if (hi != 0) h = 31 *% h +% @as(i32, @bitCast(hi));
    h = 31 *% h +% @as(i32, @bitCast(lo));
    return if (neg) -%h else h;
}

/// `clojure.lang.Util.hashCombine` (the boost-style combiner Symbol.hasheq
/// folds its ns hash with).
pub fn hashCombine(seed_val: u32, hash_val: u32) u32 {
    const seed: i32 = @bitCast(seed_val);
    const h: i32 = @bitCast(hash_val);
    const golden: i32 = @bitCast(@as(u32, 0x9e3779b9));
    return @bitCast(seed ^ (h +% golden +% (seed << 6) +% (seed >> 2)));
}

/// Mix a precomputed collection hash with its element count.
pub fn mixCollHash(hash_val: u32, count: u32) u32 {
    var h1 = SEED;
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

/// Order-dependent combination (vectors, lists). `h := 31*h + element`.
pub fn hashOrdered(hashes: []const u32) u32 {
    var h: u32 = 1;
    for (hashes) |elem_hash| {
        h = h *% 31 +% elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

/// Order-independent combination (sets, map keysets).
pub fn hashUnordered(hashes: []const u32) u32 {
    var h: u32 = 0;
    for (hashes) |elem_hash| {
        h +%= elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

// --- tests ---

const testing = std.testing;

test "hashInt(0) is zero (Clojure compat)" {
    try testing.expectEqual(@as(u32, 0), hashInt(0));
}

test "hashInt is deterministic and discriminates sign" {
    const h_pos = hashInt(42);
    try testing.expect(h_pos != 0);
    try testing.expectEqual(h_pos, hashInt(42));

    const h_neg = hashInt(-1);
    try testing.expect(h_neg != 0);
    try testing.expect(h_neg != hashInt(1));
}

test "hashLong(0) is zero; non-zero values hash deterministically" {
    try testing.expectEqual(@as(u32, 0), hashLong(0));
    const h = hashLong(42);
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashLong(42));
    try testing.expect(hashLong(1 << 48) != 0);
}

test "hashString deterministic; empty handled; lengths discriminate" {
    try testing.expectEqual(hashString(""), hashString(""));
    const h = hashString("hello");
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashString("hello"));
    try testing.expect(h != hashString("world"));

    const h1 = hashString("a");
    const h2 = hashString("ab");
    const h3 = hashString("abc");
    const h4 = hashString("abcd");
    const h5 = hashString("abcde");
    try testing.expect(h1 != h2);
    try testing.expect(h2 != h3);
    try testing.expect(h3 != h4);
    try testing.expect(h4 != h5);
}

test "mixCollHash differs on different counts" {
    const h = mixCollHash(12345, 3);
    try testing.expectEqual(h, mixCollHash(12345, 3));
    try testing.expect(h != mixCollHash(12345, 4));
}

test "hashOrdered is order-dependent" {
    const a = [_]u32{ hashInt(1), hashInt(2) };
    const b = [_]u32{ hashInt(2), hashInt(1) };
    try testing.expect(hashOrdered(&a) != hashOrdered(&b));
}

test "hashUnordered is order-independent" {
    const a = [_]u32{ hashInt(1), hashInt(2), hashInt(3) };
    const b = [_]u32{ hashInt(3), hashInt(1), hashInt(2) };
    try testing.expectEqual(hashUnordered(&a), hashUnordered(&b));
}

test "hashUnencodedChars matches JVM Murmur3 (clj oracle)" {
    // clj: (clojure.lang.Murmur3/hashUnencodedChars s) — UTF-16 code-unit
    // hash, JVM bit-parity (D-376). Values incl. a surrogate-pair case (𠮷 =
    // U+20BB7 → 2 UTF-16 units).
    try testing.expectEqual(@as(i32, 1118836419), @as(i32, @bitCast(hashUnencodedChars("abc"))));
    try testing.expectEqual(@as(i32, 1867108634), @as(i32, @bitCast(hashUnencodedChars("a"))));
    try testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(hashUnencodedChars(""))));
    try testing.expectEqual(@as(i32, 1689409188), @as(i32, @bitCast(hashUnencodedChars("hello world"))));
    try testing.expectEqual(@as(i32, 1524218000), @as(i32, @bitCast(hashUnencodedChars("あいう"))));
    try testing.expectEqual(@as(i32, -383720716), @as(i32, @bitCast(hashUnencodedChars("𠮷野家"))));
}

test "javaStringHashCode is total over invalid UTF-8 and matches the JVM" {
    // clj (JDK 25/26): (let [s (String. (byte-array ...) "UTF-8")]
    //                    [(.hashCode s) (hash s)])
    try testing.expectEqual(@as(i32, 2031588), javaStringHashCode(&.{ 0xFF, 0x41 }));
    try testing.expectEqual(@as(i32, 67548), javaStringHashCode(&.{ 0x41, 0xE2, 0x82 }));
    try testing.expectEqual(@as(i32, 65533), javaStringHashCode(&.{ 0xED, 0xA0, 0x80 }));
    try testing.expectEqual(@as(i32, 65008802), javaStringHashCode(&.{ 0xC0, 0xAF, 0x42 }));
    try testing.expectEqual(@as(i32, 2017367872), javaStringHashCode(&.{ 0xF4, 0x90, 0x80, 0x80 }));
    try testing.expectEqual(@as(i32, 1965378420), @as(i32, @bitCast(hashInt(javaStringHashCode(&.{ 0xFF, 0x41 })))));
    try testing.expectEqual(@as(i32, -2085789285), @as(i32, @bitCast(hashInt(javaStringHashCode(&.{ 0xC0, 0xAF, 0x42 })))));
}

test "string hashes are total over random bytes (property)" {
    var prng = std.Random.DefaultPrng.init(0x5eed_c1_1a);
    const rand = prng.random();
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    while (n < 20_000) : (n += 1) {
        const len = rand.uintAtMost(usize, buf.len);
        rand.bytes(buf[0..len]);
        const s = buf[0..len];
        _ = javaStringHashCode(s);
        _ = hashUnencodedChars(s);
        _ = hashString(s);
        // Equal bytes hash equal (the only obligation `=` places on hash).
        try testing.expectEqual(javaStringHashCode(s), javaStringHashCode(s));
    }
}
