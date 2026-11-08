// SPDX-License-Identifier: EPL-2.0
//! Total UTF-8 decoding: a codepoint iterator defined over ARBITRARY bytes.
//!
//! A cljw String is a byte slice that is not validated at construction
//! (`slurp` of a binary file, `(String. bytes)`), so every walk over a
//! String's codepoints must terminate without a safety panic whatever the
//! bytes are. `std.unicode.Utf8Iterator` does not: it is `catch unreachable`
//! on an invalid lead byte and slices past the end on a truncated tail.
//!
//! `Iterator` is a drop-in for `std.unicode.Utf8Iterator` (same fields, same
//! `nextCodepointSlice` / `nextCodepoint` / `peek`). On well-formed UTF-8 it
//! yields exactly what std yields. On ill-formed input each ill-formed span
//! decodes to U+FFFD, and the spans are the ones the JDK's UTF-8 String
//! decoder replaces (JDK 25/26, measured): Unicode "maximal subpart"
//! substitution, except that `ED` accepts `80..BF` as its second byte and a
//! complete 3-byte sequence encoding a surrogate is ONE ill-formed span.
//! That makes a decoded cljw String equal, code unit for code unit, to the
//! JVM String `new String(bytes, UTF_8)` over the same bytes.

const std = @import("std");

pub const replacement_character: u21 = std.unicode.replacement_character;

/// One decoding step at a byte offset: the span length consumed (1..4) and
/// the decoded codepoint, or null when the span is ill-formed.
pub const Step = struct {
    len: u3,
    cp: ?u21,
};

/// Decode the sequence starting at `bytes[i]`. Precondition: `i < bytes.len`.
/// Never reads past `bytes.len`; always consumes at least one byte.
pub fn step(bytes: []const u8, i: usize) Step {
    const b0 = bytes[i];
    if (b0 < 0x80) return .{ .len = 1, .cp = b0 };
    var need: u3 = undefined;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    var cp: u21 = undefined;
    switch (b0) {
        0xC2...0xDF => {
            need = 1;
            cp = b0 & 0x1F;
        },
        0xE0 => {
            need = 2;
            lo = 0xA0;
            cp = 0;
        },
        0xE1...0xEF => {
            // ED included: JDK takes 80..BF after ED and rejects the
            // decoded surrogate as a whole 3-byte span below.
            need = 2;
            cp = b0 & 0x0F;
        },
        0xF0 => {
            need = 3;
            lo = 0x90;
            cp = 0;
        },
        0xF1...0xF3 => {
            need = 3;
            cp = b0 & 0x07;
        },
        0xF4 => {
            need = 3;
            hi = 0x8F;
            cp = 4;
        },
        else => return .{ .len = 1, .cp = null },
    }
    var k: u3 = 1;
    while (k <= need) : (k += 1) {
        const at = i + k;
        if (at >= bytes.len) return .{ .len = k, .cp = null };
        const b = bytes[at];
        const l: u8 = if (k == 1) lo else 0x80;
        const h: u8 = if (k == 1) hi else 0xBF;
        if (b < l or b > h) return .{ .len = k, .cp = null };
        cp = (cp << 6) | @as(u21, b & 0x3F);
    }
    if (cp >= 0xD800 and cp <= 0xDFFF) return .{ .len = need + 1, .cp = null };
    return .{ .len = need + 1, .cp = cp };
}

/// Drop-in, total replacement for `std.unicode.Utf8Iterator`.
pub const Iterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .i = 0 };
    }

    /// The bytes of the next codepoint (a well-formed sequence or one
    /// ill-formed span), or null at the end.
    pub fn nextCodepointSlice(it: *Iterator) ?[]const u8 {
        if (it.i >= it.bytes.len) return null;
        const s = step(it.bytes, it.i);
        const start = it.i;
        it.i += s.len;
        return it.bytes[start..it.i];
    }

    /// The next codepoint; U+FFFD for an ill-formed span; null at the end.
    pub fn nextCodepoint(it: *Iterator) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const s = step(it.bytes, it.i);
        it.i += s.len;
        return s.cp orelse replacement_character;
    }

    /// Look ahead at the next `n` codepoints without advancing. Returns the
    /// remainder of the input when fewer than `n` are left.
    pub fn peek(it: *Iterator, n: usize) []const u8 {
        const original_i = it.i;
        defer it.i = original_i;
        var found: usize = 0;
        while (found < n) : (found += 1) {
            _ = it.nextCodepointSlice() orelse return it.bytes[original_i..];
        }
        return it.bytes[original_i..it.i];
    }
};

/// UTF-16 code units of `cp`: one unit below U+10000, else a surrogate pair.
/// Returns the unit count (1 or 2) written to `out`.
pub fn utf16Units(cp: u21, out: *[2]u16) u2 {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v: u32 = @as(u32, cp) - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

// --- tests ---

const testing = std.testing;

fn expectDecode(bytes: []const u8, expected: []const u21) !void {
    var it = Iterator.init(bytes);
    var got: [16]u21 = undefined;
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| : (n += 1) got[n] = cp;
    try testing.expectEqualSlices(u21, expected, got[0..n]);
    try testing.expectEqual(bytes.len, it.i);
}

const R = replacement_character;

test "well-formed UTF-8 decodes exactly as std.unicode does" {
    const samples = [_][]const u8{ "", "abc", "あいう", "𠮷野家", "\u{20AC}", "\u{1F600}x", "\u{10FFFF}" };
    for (samples) |s| {
        var ours = Iterator.init(s);
        var theirs = (try std.unicode.Utf8View.init(s)).iterator();
        while (true) {
            const a = ours.nextCodepoint();
            const b = theirs.nextCodepoint();
            try testing.expectEqual(b, a);
            if (a == null) break;
        }
    }
}

test "ill-formed spans match the JDK's String(bytes, UTF_8) replacement" {
    // Expected sequences measured on JDK 25 and 26:
    // (mapv int (String. (byte-array ...) "UTF-8")).
    try expectDecode(&.{ 0xFF, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0x80, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0x41, 0xE2, 0x82 }, &.{ 'A', R });
    try expectDecode(&.{ 0x41, 0xE2 }, &.{ 'A', R });
    try expectDecode(&.{ 0xC0, 0xAF, 0x42 }, &.{ R, R, 'B' });
    try expectDecode(&.{ 0xC2, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0xE0, 0x80, 0x80 }, &.{ R, R, R });
    try expectDecode(&.{ 0xE0, 0xA0 }, &.{R});
    try expectDecode(&.{ 0xE0, 0xA0, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0xE2, 0x41, 0x82 }, &.{ R, 'A', R });
    try expectDecode(&.{ 0xED, 0xA0, 0x80 }, &.{R});
    try expectDecode(&.{ 0xED, 0xA0 }, &.{R});
    try expectDecode(&.{ 0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80 }, &.{ R, R });
    try expectDecode(&.{ 0xF0, 0x80, 0x80 }, &.{ R, R, R });
    try expectDecode(&.{ 0xF0, 0x90 }, &.{R});
    try expectDecode(&.{ 0xF0, 0x90, 0x80 }, &.{R});
    try expectDecode(&.{ 0xF0, 0x90, 0x80, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0xF0, 0x90, 0x41, 0x80 }, &.{ R, 'A', R });
    try expectDecode(&.{ 0xF4, 0x90, 0x80, 0x80 }, &.{ R, R, R, R });
    try expectDecode(&.{ 0xF5, 0x41 }, &.{ R, 'A' });
    try expectDecode(&.{ 0xF8, 0x43 }, &.{ R, 'C' });
}

test "total over every 1-, 2- and 3-byte input; slices tile the input" {
    var buf: [3]u8 = undefined;
    var a: usize = 0;
    while (a < 256) : (a += 1) {
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            var c: usize = 0;
            while (c < 256) : (c += 17) {
                buf = .{ @intCast(a), @intCast(b), @intCast(c) };
                for (1..4) |len| {
                    var it = Iterator.init(buf[0..len]);
                    var covered: usize = 0;
                    while (it.nextCodepointSlice()) |s| covered += s.len;
                    try testing.expectEqual(len, covered);
                }
            }
        }
    }
}

test "peek does not advance and stops at the end" {
    var it = Iterator.init(&.{ 0xFF, 'a', 0xE2 });
    try testing.expectEqualSlices(u8, &.{ 0xFF, 'a' }, it.peek(2));
    try testing.expectEqual(@as(usize, 0), it.i);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 'a', 0xE2 }, it.peek(9));
}

test "utf16Units splits astral codepoints into a surrogate pair" {
    var out: [2]u16 = undefined;
    try testing.expectEqual(@as(u2, 1), utf16Units('A', &out));
    try testing.expectEqual(@as(u16, 'A'), out[0]);
    try testing.expectEqual(@as(u2, 2), utf16Units(0x20BB7, &out));
    try testing.expectEqual(@as(u16, 0xD842), out[0]);
    try testing.expectEqual(@as(u16, 0xDFB7), out[1]);
}
