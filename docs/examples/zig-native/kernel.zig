//! What Zig is good at, called from Clojure. One source, two builds:
//!
//!   native (cljw.ffi):  zig build-lib -dynamic -O ReleaseFast kernel.zig
//!   wasm (wasm/load):   zig build-exe kernel.zig -target wasm32-freestanding \
//!                         -O ReleaseSmall -fno-entry -rdynamic -femit-bin=kernel.wasm
//!
//! Every export takes and returns C-ABI scalars or pointers. The wasm build
//! cannot see host memory, so it hands out its own buffers (`f64_addr`,
//! `byte_addr`) for the host to fill with wasm/mem-write!.
const std = @import("std");

// The first 10000 primes, computed by the compiler. The binary ships the table.
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

/// The ith prime (0-based) from the compile-time table; 0 when out of range.
export fn nth_prime(i: u32) u32 {
    return if (i < PRIMES.len) PRIMES[i] else 0;
}

// A keyword table, also built at compile time.
const OPS = std.StaticStringMap(i32).initComptime(.{
    .{ "add", 1 }, .{ "sub", 2 }, .{ "mul", 3 }, .{ "div", 4 }, .{ "pow", 5 },
});

/// Opcode for an operator name of `len` bytes at `ptr`; -1 when unknown.
export fn opcode(ptr: [*]const u8, len: usize) i32 {
    return OPS.get(ptr[0..len]) orelse -1;
}

/// Dot product of two f64 arrays of `len` elements, four lanes at a time.
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

/// Number of set bits in x.
export fn popcount(x: u64) u32 {
    return @popCount(x);
}

/// x with its 64 bits in reverse order.
export fn bitrev(x: u64) u64 {
    return @bitReverse(x);
}

/// BLAKE3 of `len` bytes at `ptr`, written to `out` as 64 hex chars and a NUL.
export fn blake3(ptr: [*]const u8, len: usize, out: [*]u8) void {
    var d: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(ptr[0..len], &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    @memcpy(out[0..64], &hex);
    out[64] = 0;
}

// Guest-owned buffers for the wasm build; unused by the native build.
var f64_buf: [4096]f64 = undefined;
var byte_buf: [4096]u8 = undefined;

/// Address and capacity (in elements) of the f64 buffer.
export fn f64_addr() usize {
    return @intFromPtr(&f64_buf);
}
export fn f64_cap() usize {
    return f64_buf.len;
}

/// Address and capacity (in bytes) of the byte buffer.
export fn byte_addr() usize {
    return @intFromPtr(&byte_buf);
}
export fn byte_cap() usize {
    return byte_buf.len;
}
