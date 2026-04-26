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
