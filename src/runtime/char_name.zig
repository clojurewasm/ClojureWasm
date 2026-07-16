// SPDX-License-Identifier: EPL-2.0
//! Character NAME surface (D-561): the impl behind `Character/getName` +
//! `Character/codePointOf`, over the generated UCD 16.0.0 table
//! (`unicode_names.zig` — pre-compressed word-indexed blobs) plus the
//! JVM's derivation rules, all clj-oracle-verified:
//!
//!   - a NAMED codepoint renders its UCD name (word-dict decode; the
//!     reserved word index 0 re-derives a trailing own-hex token, e.g.
//!     "CJK COMPATIBILITY IDEOGRAPH-F900");
//!   - a CONTROL renders its pinned JVM alias ("NULL", "BEL", …);
//!   - an ASSIGNED-but-unnamed codepoint renders "<BLOCK NAME> <HEX>"
//!     ("TANGUT 17000", "HANGUL SYLLABLES AC00" — the JVM does NOT
//!     synthesize UCD algorithmic names);
//!   - UNASSIGNED (Cn) → null.
//!
//! `codePointOf` is the trimmed, case-insensitive inverse (control alias →
//! stored-name scan → block-hex parse), confirmed by forward-name equality
//! so it accepts exactly the strings `getName` can produce (JVM-faithful:
//! "HANGUL SYLLABLE GA" — a UCD algorithmic name the JVM never emits —
//! is rejected there too).
//!
//! The decompressed blobs are a process-lifetime lazy singleton
//! (page_allocator, never freed — shared across Runtimes like the
//! interners; an atomic pointer publishes it, a losing racer's build
//! leaks one copy at worst). The flate decode is local (10 lines) because
//! `serialize.zig`'s helper lives in the eval layer this zone must not
//! import; the two std pitfalls it documents apply here too (REAL history
//! window; read EXACTLY uncompressed_len).

const std = @import("std");
const data = @import("unicode_names.zig");
const charset = @import("charset.zig");

const Tables = struct {
    /// word index → slice into the decompressed words blob (index 0 = the
    /// CPHEX sentinel, an empty slice).
    words: []const []const u8,
    /// varint word-index sequences ((idx << 1) | joins-next-without-space).
    names: []const u8,
    /// 8-byte LE records: cp u32, then (tokens << 24) | offset u32; cp-sorted.
    index: []const u8,
};

var tables_ptr: std.atomic.Value(?*const Tables) = .init(null);

fn flateDecompressRaw(gpa: std.mem.Allocator, bytes: []const u8, uncompressed_len: u32) ![]const u8 {
    const flate = std.compress.flate;
    const out = try gpa.alloc(u8, uncompressed_len);
    errdefer gpa.free(out);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(bytes);
    var d: flate.Decompress = .init(&in, .raw, window);
    try d.reader.readSliceAll(out);
    return out;
}

fn tables() !*const Tables {
    if (tables_ptr.load(.acquire)) |t| return t;
    const gpa = std.heap.page_allocator;
    const words_raw = try flateDecompressRaw(gpa, data.words_deflate, data.words_len);
    const names_raw = try flateDecompressRaw(gpa, data.names_deflate, data.names_len);
    const index_raw = try flateDecompressRaw(gpa, data.cp_index_deflate, data.cp_index_len);
    defer gpa.free(@constCast(index_raw));
    var words = try gpa.alloc([]const u8, data.word_count);
    var it = std.mem.splitScalar(u8, words_raw, '\n');
    var i: usize = 0;
    while (it.next()) |w| : (i += 1) words[i] = w;
    std.debug.assert(i == data.word_count);
    // The wire index is a delta-varint stream (cp_delta, then
    // (offset_delta << 5) | tokens) — decode once into fixed 8-byte
    // records for binary search.
    const index = try gpa.alloc(u8, @as(usize, data.named_count) * RECORD);
    var pos: u32 = 0;
    var cp: u32 = 0;
    var off: u32 = 0;
    var r: usize = 0;
    while (r < data.named_count) : (r += 1) {
        cp += readVarint(index_raw, &pos);
        const packed_v = readVarint(index_raw, &pos);
        off += packed_v >> 5;
        std.mem.writeInt(u32, index[r * RECORD ..][0..4], cp, .little);
        std.mem.writeInt(u32, index[r * RECORD ..][4..8], ((packed_v & 0x1F) << 24) | off, .little);
    }
    const t = try gpa.create(Tables);
    t.* = .{ .words = words, .names = names_raw, .index = index };
    tables_ptr.store(t, .release);
    return t;
}

const RECORD = 8;

fn indexLookup(t: *const Tables, cp: u21) ?struct { offset: u32, tokens: u8 } {
    var lo: usize = 0;
    var hi: usize = t.index.len / RECORD;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec = t.index[mid * RECORD ..][0..RECORD];
        const rcp = std.mem.readInt(u32, rec[0..4], .little);
        if (rcp == cp) {
            const packed_v = std.mem.readInt(u32, rec[4..8], .little);
            return .{ .offset = packed_v & 0x00FF_FFFF, .tokens = @intCast(packed_v >> 24) };
        }
        if (rcp < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn readVarint(bytes: []const u8, pos: *u32) u32 {
    var shift: u5 = 0;
    var out: u32 = 0;
    while (true) {
        const b = bytes[pos.*];
        pos.* += 1;
        out |= @as(u32, b & 0x7F) << shift;
        if (b & 0x80 == 0) return out;
        shift += 7;
    }
}

/// Render the stored name for an entry into `w`.
fn writeStoredName(w: *std.Io.Writer, t: *const Tables, cp: u21, offset: u32, tokens: u8) !void {
    var pos = offset;
    var k: u8 = 0;
    while (k < tokens) : (k += 1) {
        const v = readVarint(t.names, &pos);
        const idx = v >> 1;
        const join = (v & 1) == 1;
        if (idx == 0) {
            try w.print("{X:0>4}", .{@as(u32, cp)});
        } else {
            try w.writeAll(t.words[idx]);
        }
        if (!join and k + 1 < tokens) try w.writeByte(' ');
    }
}

fn blockOf(cp: u21) ?[]const u8 {
    for (data.blocks) |b| {
        if (cp >= b.lo and cp <= b.hi) return b.name;
    }
    return null;
}

fn controlNameOf(cp: u21) ?[]const u8 {
    for (data.control_names) |c| {
        if (c.cp == cp) return c.name;
    }
    return null;
}

/// `Character.getName(cp)` — the name as an ALLOCATED string on `gpa`
/// (caller owns), or null for an unassigned codepoint. Caller validates
/// the codepoint range (JVM throws IAE for an invalid one).
pub fn getName(gpa: std.mem.Allocator, cp: u21) !?[]const u8 {
    if (controlNameOf(cp)) |n| return try gpa.dupe(u8, n);
    const t = try tables();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    if (indexLookup(t, cp)) |e| {
        try writeStoredName(&aw.writer, t, cp, e.offset, e.tokens);
        return try aw.toOwnedSlice();
    }
    if (charset.categoryOf(cp) == 0) return null; // Cn — unassigned
    const block = blockOf(cp) orelse return null;
    try aw.writer.print("{s} {X}", .{ block, @as(u32, cp) });
    return try aw.toOwnedSlice();
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// `Character.codePointOf(name)` — trimmed, ASCII-case-insensitive inverse
/// of `getName`; null when no codepoint has that name (the surface raises
/// the JVM's IllegalArgumentException shape).
pub fn codePointOf(name: []const u8) !?u21 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;
    for (data.control_names) |c| {
        if (eqIgnoreCase(c.name, trimmed)) return c.cp;
    }
    const t = try tables();
    // Stored-name scan: decode each entry into a bounded buffer and compare.
    // Linear over ~40k entries (a rare, human-driven call — clarity over an
    // inverse index; the longest UCD name is < 96 bytes).
    var buf: [128]u8 = undefined;
    const n_records = t.index.len / RECORD;
    var ri: usize = 0;
    while (ri < n_records) : (ri += 1) {
        const rec = t.index[ri * RECORD ..][0..RECORD];
        const rcp: u21 = @intCast(std.mem.readInt(u32, rec[0..4], .little));
        const packed_v = std.mem.readInt(u32, rec[4..8], .little);
        var fw: std.Io.Writer = .fixed(&buf);
        writeStoredName(&fw, t, rcp, packed_v & 0x00FF_FFFF, @intCast(packed_v >> 24)) catch continue;
        if (eqIgnoreCase(fw.buffered(), trimmed)) return rcp;
    }
    // Block-hex form ("CJK UNIFIED IDEOGRAPHS 4E00"): parse the trailing hex,
    // then confirm by forward-name equality so exactly getName's outputs are
    // accepted (an unassigned or named codepoint's block-hex spelling is
    // rejected, JVM-faithful).
    const last_space = std.mem.findScalarLast(u8, trimmed, ' ') orelse return null;
    const hex = trimmed[last_space + 1 ..];
    const cp_u32 = std.fmt.parseInt(u32, hex, 16) catch return null;
    if (cp_u32 > 0x10FFFF) return null;
    const cp: u21 = @intCast(cp_u32);
    if (charset.categoryOf(cp) == 0) return null;
    if (indexLookup(t, cp) != null or controlNameOf(cp) != null) return null;
    const block = blockOf(cp) orelse return null;
    if (!eqIgnoreCase(block, trimmed[0..last_space])) return null;
    return cp;
}

// --- tests ---

const testing = std.testing;

test "getName: stored / control / block-hex / unassigned (JVM-oracle values)" {
    const gpa = testing.allocator;
    const a = (try getName(gpa, 'A')).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("LATIN CAPITAL LETTER A", a);
    const nul = (try getName(gpa, 0)).?;
    defer gpa.free(nul);
    try testing.expectEqualStrings("NULL", nul);
    const bel = (try getName(gpa, 7)).?;
    defer gpa.free(bel);
    try testing.expectEqualStrings("BEL", bel);
    const cjk = (try getName(gpa, 0x4E00)).?;
    defer gpa.free(cjk);
    try testing.expectEqualStrings("CJK UNIFIED IDEOGRAPHS 4E00", cjk);
    const hangul = (try getName(gpa, 0xAC00)).?;
    defer gpa.free(hangul);
    try testing.expectEqualStrings("HANGUL SYLLABLES AC00", hangul);
    const compat = (try getName(gpa, 0xF900)).?;
    defer gpa.free(compat);
    try testing.expectEqualStrings("CJK COMPATIBILITY IDEOGRAPH-F900", compat);
    const tangut = (try getName(gpa, 0x17000)).?;
    defer gpa.free(tangut);
    try testing.expectEqualStrings("TANGUT 17000", tangut);
    try testing.expect((try getName(gpa, 0x0378)) == null);
    try testing.expect((try getName(gpa, 0x10FFFF)) == null);
}

test "codePointOf: inverse incl. case-insensitive + trim + block-hex; misses null" {
    try testing.expectEqual(@as(?u21, 'A'), try codePointOf("LATIN CAPITAL LETTER A"));
    try testing.expectEqual(@as(?u21, 'A'), try codePointOf("latin capital letter a"));
    try testing.expectEqual(@as(?u21, 0), try codePointOf(" NULL "));
    try testing.expectEqual(@as(?u21, 7), try codePointOf("BEL"));
    try testing.expectEqual(@as(?u21, 0x4E00), try codePointOf("CJK UNIFIED IDEOGRAPHS 4E00"));
    try testing.expectEqual(@as(?u21, 0xF900), try codePointOf("CJK COMPATIBILITY IDEOGRAPH-F900"));
    try testing.expectEqual(@as(?u21, null), try codePointOf("NO SUCH NAME"));
    // The UCD algorithmic Hangul spelling the JVM never emits is rejected.
    try testing.expectEqual(@as(?u21, null), try codePointOf("HANGUL SYLLABLE GA"));
}
