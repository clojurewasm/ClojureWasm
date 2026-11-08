//! The 47 KB module behind bench/wasm_percall.clj's `big-*` cells. Its size
//! comes from the compile-time tables; the bench calls only `popcount`, so a
//! per-call cost that grows with the module is all the cells can show.
//! Rebuild: zig build-exe -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseSmall zigcool.zig

const std = @import("std");

// The first 10000 primes, computed by the compiler: the binary ships the table.
const PRIMES = blk: {
    @setEvalBranchQuota(200_000_000);
    var table: [10_000]u32 = undefined;
    var n: usize = 0;
    var c: u32 = 2;
    while (n < table.len) : (c += 1) {
        var is_p = true;
        for (table[0..n]) |p| {
            if (p * p > c) break;
            if (c % p == 0) {
                is_p = false;
                break;
            }
        }
        if (is_p) {
            table[n] = c;
            n += 1;
        }
    }
    break :blk table;
};

/// The nth prime (0-based) from the compile-time table, 0 when out of range.
export fn nth_prime(i: u32) u32 {
    return if (i < PRIMES.len) PRIMES[i] else 0;
}

// A perfect-hash keyword map, also built at compile time.
const OPS = std.StaticStringMap(i32).initComptime(.{
    .{ "add", 1 }, .{ "sub", 2 }, .{ "mul", 3 }, .{ "div", 4 }, .{ "pow", 5 },
});

/// Opcode for an operator name, -1 when unknown.
export fn opcode(ptr: [*]const u8, len: usize) i32 {
    return OPS.get(ptr[0..len]) orelse -1;
}

/// Dot product of two f64 arrays, 4 lanes at a time with @Vector.
export fn dot(a: [*]const f64, b: [*]const f64, len: usize) f64 {
    const V = @Vector(4, f64);
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + 4 <= len) : (i += 4) {
        const va: V = a[i..][0..4].*;
        const vb: V = b[i..][0..4].*;
        acc += va * vb;
    }
    var sum = @reduce(.Add, acc);
    while (i < len) : (i += 1) sum += a[i] * b[i];
    return sum;
}

/// Set bits in x.
export fn popcount(x: u64) u32 {
    return @popCount(x);
}

/// x with its 64 bits in reverse order.
export fn bitrev(x: u64) u64 {
    return @bitReverse(x);
}

/// BLAKE3 hex digest of the input into `out` (64 bytes + NUL).
export fn blake3(ptr: [*]const u8, len: usize, out: [*]u8) void {
    var d: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(ptr[0..len], &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    @memcpy(out[0..64], &hex);
    out[64] = 0;
}
