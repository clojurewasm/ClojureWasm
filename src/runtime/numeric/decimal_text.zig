// SPDX-License-Identifier: EPL-2.0
//! Base-10 text of an arbitrary-precision integer, with no size ceiling.
//!
//! std's `Const.format` (the `{f}` spec on a `Managed` / `Const`) renders
//! through a fixed stack buffer of 64 limbs (Zig 0.16) and, past it, writes the
//! literal "(BigInt)" instead of the digits. 64 limbs is about 1233 decimal
//! digits, so `(str (reduce *' (range 1N 1000N)))` printed "(BigInt)"
//! (CLJW-BIGINT-STR-PLACEHOLDER). Every BigInt / Ratio / BigDecimal print path
//! renders through `writeDecimal` instead of `{f}`.

const std = @import("std");
const Managed = std.math.big.int.Managed;

/// Largest limb count std's `Const.format` renders without the placeholder.
const std_format_max_limbs = 64;

/// Write the base-10 digits of `m` (leading `-` when negative) to `w`. A value
/// within std's stack bound renders there; a wider one through a scratch
/// string on the Managed's own allocator.
pub fn writeDecimal(w: *std.Io.Writer, m: *const Managed) !void {
    const c = m.toConst();
    if (c.limbs.len <= std_format_max_limbs) return c.format(w);
    const s = try c.toStringAlloc(m.allocator, 10, .lower);
    defer m.allocator.free(s);
    try w.writeAll(s);
}

/// Base-10 digits of `m` as a fresh string on `alloc` (the allocating twin of
/// `writeDecimal`). Caller owns the result.
pub fn decimalAlloc(alloc: std.mem.Allocator, m: *const Managed) ![]u8 {
    return m.toConst().toStringAlloc(alloc, 10, .lower);
}

/// Write `n/d` (a big Ratio's reader text) to `w`, no size ceiling.
pub fn writeFraction(w: *std.Io.Writer, n: *const Managed, d: *const Managed) !void {
    try writeDecimal(w, n);
    try w.writeByte('/');
    try writeDecimal(w, d);
}

/// `n/d` as a fresh string on `alloc`. Caller owns the result.
pub fn fractionAlloc(alloc: std.mem.Allocator, n: *const Managed, d: *const Managed) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    writeFraction(&aw.writer, n, d) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "writeDecimal renders a value past std's 64-limb format bound" {
    // 10^3000: 3001 digits, far past the 64-limb (about 1233 digit) bound.
    var m = try Managed.initSet(testing.allocator, 1);
    defer m.deinit();
    var ten = try Managed.initSet(testing.allocator, 10);
    defer ten.deinit();
    for (0..3000) |_| try m.mul(&m, &ten);
    try testing.expect(m.toConst().limbs.len > std_format_max_limbs);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeDecimal(&aw.writer, &m);
    const out = aw.written();
    try testing.expectEqual(@as(usize, 3001), out.len);
    try testing.expectEqual(@as(u8, '1'), out[0]);
    for (out[1..]) |ch| try testing.expectEqual(@as(u8, '0'), ch);

    m.negate();
    aw.clearRetainingCapacity();
    try writeDecimal(&aw.writer, &m);
    try testing.expectEqual(@as(usize, 3002), aw.written().len);
    try testing.expectEqual(@as(u8, '-'), aw.written()[0]);
}

test "writeDecimal small values match std format" {
    var m = try Managed.initSet(testing.allocator, -12345);
    defer m.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeDecimal(&aw.writer, &m);
    try testing.expectEqualStrings("-12345", aw.written());
}
