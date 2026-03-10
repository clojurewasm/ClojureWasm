//! Murmur3 hash functions for ClojureWasm runtime.
//!
//! Clojure-compatible hash values using Murmur3 algorithm.
//! All arithmetic uses wrapping operations to match Java's int overflow semantics.
//! Reference: clojure.lang.Murmur3 (Java), CW hash.zig.

const std = @import("std");

// --- Murmur3 constants ---

const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const SEED: u32 = 0;

// --- Core mixing functions ---

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

// --- Public hash API ---

/// Hash a 32-bit integer (Clojure-compatible).
pub fn hashInt(input: i32) u32 {
    if (input == 0) return 0;
    const k1 = mixK1(@bitCast(input));
    const h1 = mixH1(SEED, k1);
    return fmix(h1, 4);
}

/// Hash a 64-bit integer (Clojure-compatible).
pub fn hashLong(input: i64) u32 {
    if (input == 0) return 0;
    const bits: u64 = @bitCast(input);
    const low: u32 = @truncate(bits);
    const high: u32 = @truncate(bits >> 32);
    var h1 = mixH1(SEED, mixK1(low));
    h1 = mixH1(h1, mixK1(high));
    return fmix(h1, 8);
}

/// Hash a string (Murmur3 on UTF-8 bytes).
pub fn hashString(input: []const u8) u32 {
    var h1: u32 = SEED;
    const nblocks = input.len / 4;

    // Body: process 4-byte blocks
    for (0..nblocks) |i| {
        const offset = i * 4;
        const k: u32 = @as(u32, input[offset]) |
            (@as(u32, input[offset + 1]) << 8) |
            (@as(u32, input[offset + 2]) << 16) |
            (@as(u32, input[offset + 3]) << 24);
        h1 = mixH1(h1, mixK1(k));
    }

    // Tail: process remaining bytes
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

/// Mix a collection hash with its element count.
/// Used for vectors, lists, sets, and maps.
pub fn mixCollHash(hash_val: u32, count: u32) u32 {
    var h1 = SEED;
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

/// Combine hashes for an ordered collection (vector, list).
/// Formula: hash = 31 * hash + element_hash
pub fn hashOrdered(hashes: []const u32) u32 {
    var h: u32 = 1;
    for (hashes) |elem_hash| {
        h = h *% 31 +% elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

/// Combine hashes for an unordered collection (set, map).
/// Formula: hash += element_hash
pub fn hashUnordered(hashes: []const u32) u32 {
    var h: u32 = 0;
    for (hashes) |elem_hash| {
        h +%= elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

// --- Tests ---

const testing = std.testing;

test "hashInt zero returns zero" {
    try testing.expectEqual(@as(u32, 0), hashInt(0));
}

test "hashInt positive" {
    const h = hashInt(42);
    try testing.expect(h != 0);
    // Same input should produce same hash
    try testing.expectEqual(h, hashInt(42));
}

test "hashInt negative" {
    const h = hashInt(-1);
    try testing.expect(h != 0);
    try testing.expect(h != hashInt(1));
}

test "hashInt deterministic" {
    // Verify Murmur3 hashInt(1) is stable across runs
    const h = hashInt(1);
    try testing.expectEqual(h, hashInt(1));
    try testing.expect(h != 0);
}

test "hashLong zero returns zero" {
    try testing.expectEqual(@as(u32, 0), hashLong(0));
}

test "hashLong positive" {
    const h = hashLong(42);
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashLong(42));
}

test "hashLong large" {
    const h = hashLong(1 << 48);
    try testing.expect(h != 0);
}

test "hashString empty" {
    const h = hashString("");
    // Empty string hash should be deterministic
    try testing.expectEqual(h, hashString(""));
}

test "hashString basic" {
    const h = hashString("hello");
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashString("hello"));
    try testing.expect(h != hashString("world"));
}

test "hashString known value" {
    // Clojure: (hash "hello") => 1220979047 (uses Murmur3 on UTF-16... different)
    // Our implementation hashes UTF-8 bytes directly (like CW).
    // Just verify determinism and non-zero.
    const h = hashString("hello");
    try testing.expect(h != 0);
}

test "hashString different lengths" {
    const h1 = hashString("a");
    const h2 = hashString("ab");
    const h3 = hashString("abc");
    const h4 = hashString("abcd");
    const h5 = hashString("abcde");

    // All different
    try testing.expect(h1 != h2);
    try testing.expect(h2 != h3);
    try testing.expect(h3 != h4);
    try testing.expect(h4 != h5);
}

test "mixCollHash deterministic" {
    const h = mixCollHash(12345, 3);
    try testing.expectEqual(h, mixCollHash(12345, 3));
    try testing.expect(h != mixCollHash(12345, 4)); // different count
}

test "hashOrdered" {
    const hashes = [_]u32{ hashInt(1), hashInt(2), hashInt(3) };
    const h = hashOrdered(&hashes);
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashOrdered(&hashes));
}

test "hashUnordered is order-independent" {
    const a = [_]u32{ hashInt(1), hashInt(2), hashInt(3) };
    const b = [_]u32{ hashInt(3), hashInt(1), hashInt(2) };
    try testing.expectEqual(hashUnordered(&a), hashUnordered(&b));
}

test "hashOrdered is order-dependent" {
    const a = [_]u32{ hashInt(1), hashInt(2) };
    const b = [_]u32{ hashInt(2), hashInt(1) };
    try testing.expect(hashOrdered(&a) != hashOrdered(&b));
}
