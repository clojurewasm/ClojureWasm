// SPDX-License-Identifier: EPL-2.0
//! nREPL transport layer (ADR-0170): bencode framing over a growable
//! receive buffer + the single reply choke point that stamps every
//! response with the request's `session` + `id` (babashka
//! `response-for` idiom — op handlers cannot mis-stamp a reply).
//!
//! Framing contract: `Framer.next` decodes EVERY complete message
//! already buffered before the caller blocks for more socket bytes —
//! the pre-ADR-0170 loop blocked in `fillMore()` with complete dicts
//! sitting buffered, stranding pipelined requests off-by-one (the
//! CIDER REPL-prompt killer). `bencode.DecodeError.UnexpectedEof`
//! fires only on truncation → `need_more`; any other decode error is
//! a protocol error → the connection closes. The message size cap is
//! load-bearing, not hygiene: a huge declared string length
//! (`999999999:…`) reads as truncation forever without it.
//!
//! Memory contract: the framer's receive buffer is gpa-owned and
//! persistent across messages; decoded values + encoded replies live
//! on the caller's per-message scratch arena (reset after each reply
//! flushes), so a long editor session no longer grows the process
//! arena per request.

const std = @import("std");
const Writer = std.Io.Writer;
const bencode = @import("../../runtime/bencode/bencode.zig");

/// Upper bound on a single bencode message. Large enough for any real
/// editor buffer (`load-file` sends whole files), small enough that a
/// malformed length prefix cannot balloon the receive buffer.
pub const max_message_bytes: usize = 16 * 1024 * 1024;

pub const NextResult = union(enum) {
    /// One decoded request (allocated on the scratch arena passed in).
    message: bencode.Decoded,
    /// The buffer holds only a truncated prefix — read more bytes.
    need_more,
};

pub const Framer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Consumed-prefix offset into `buf` (compacted lazily so repeated
    /// small messages don't memmove per message).
    off: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Framer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Framer) void {
        self.buf.deinit(self.gpa);
    }

    /// Append raw socket bytes.
    pub fn feed(self: *Framer, bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }

    fn pending(self: *const Framer) []const u8 {
        return self.buf.items[self.off..];
    }

    /// Decode the next complete message, if one is buffered. `scratch`
    /// receives the decoded value (per-message arena). Errors:
    /// `error.MessageTooBig` (cap breached while still truncated) or a
    /// malformed-bencode decode error — both mean "close the connection".
    pub fn next(self: *Framer, scratch: std.mem.Allocator) !NextResult {
        const bytes = self.pending();
        if (bytes.len == 0) return .need_more;
        const r = bencode.decode(scratch, bytes) catch |err| switch (err) {
            error.UnexpectedEof => {
                if (bytes.len > max_message_bytes) return error.MessageTooBig;
                return .need_more;
            },
            else => return err,
        };
        self.off += r.consumed;
        // Compact once the dead prefix dominates, so `buf` stays bounded
        // by live data + one message.
        if (self.off > 4096 and self.off * 2 > self.buf.items.len) {
            const live = self.buf.items.len - self.off;
            std.mem.copyForwards(u8, self.buf.items[0..live], self.buf.items[self.off..]);
            self.buf.shrinkRetainingCapacity(live);
            self.off = 0;
        }
        return .{ .message = r.value };
    }
};

/// Fetch a string field from a (dict) request; null when absent or
/// non-string.
pub fn requestStr(request: bencode.Decoded, key: []const u8) ?[]const u8 {
    const v = bencode.dictGet(request, key) orelse return null;
    return if (v == .str) v.str else null;
}

/// The reply choke point: every response dict opens with the request's
/// `id` + `session` echoed back (bb defaults for absent fields), then
/// the op's own entries, then flushes. Ops build `entries` only —
/// they cannot mis-stamp routing fields.
pub fn respond(
    w: *Writer,
    scratch: std.mem.Allocator,
    request: ?bencode.Decoded,
    entries: []const bencode.Decoded.Entry,
) !void {
    var all = try scratch.alloc(bencode.Decoded.Entry, entries.len + 2);
    const id_v: bencode.Decoded = if (request) |req|
        (bencode.dictGet(req, "id") orelse bencode.Decoded{ .str = "unknown" })
    else
        .{ .str = "unknown" };
    const session_v: bencode.Decoded = if (request) |req|
        (bencode.dictGet(req, "session") orelse bencode.Decoded{ .str = "none" })
    else
        .{ .str = "none" };
    all[0] = .{ .key = "id", .value = id_v };
    all[1] = .{ .key = "session", .value = session_v };
    @memcpy(all[2..], entries);
    const bytes = try bencode.encode(scratch, .{ .dict = all });
    try w.writeAll(bytes);
    try w.flush();
}

/// Build a `status` list value from string literals.
pub fn statusValue(scratch: std.mem.Allocator, items: []const []const u8) !bencode.Decoded {
    const list_items = try scratch.alloc(bencode.Decoded, items.len);
    for (items, 0..) |s, i| list_items[i] = .{ .str = s };
    return .{ .list = list_items };
}

// --- tests ---

const testing = std.testing;

fn framerFixture() Framer {
    return Framer.init(testing.allocator);
}

test "Framer: two pipelined messages decode without further feeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = framerFixture();
    defer f.deinit();

    try f.feed("d2:op4:eval2:id2:p1e" ++ "d2:op4:eval2:id2:p2e");
    const m1 = try f.next(arena.allocator());
    try testing.expect(m1 == .message);
    try testing.expectEqualStrings("p1", requestStr(m1.message, "id").?);
    const m2 = try f.next(arena.allocator());
    try testing.expect(m2 == .message);
    try testing.expectEqualStrings("p2", requestStr(m2.message, "id").?);
    try testing.expect((try f.next(arena.allocator())) == .need_more);
}

test "Framer: split message needs more, then decodes across the seam" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = framerFixture();
    defer f.deinit();

    const msg = "d2:op4:eval4:code8:(+ 1 2)!e"; // 8-byte code incl. '!'
    try f.feed(msg[0..11]);
    try testing.expect((try f.next(arena.allocator())) == .need_more);
    try f.feed(msg[11..]);
    const m = try f.next(arena.allocator());
    try testing.expect(m == .message);
    try testing.expectEqualStrings("(+ 1 2)!", requestStr(m.message, "code").?);
}

test "Framer: larger-than-4KiB message decodes (the old rbuf ceiling)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = framerFixture();
    defer f.deinit();

    const big_len = 10_000;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var len_buf: [16]u8 = undefined;
    try msg.appendSlice(testing.allocator, "d4:code");
    try msg.appendSlice(testing.allocator, try std.fmt.bufPrint(&len_buf, "{d}:", .{big_len}));
    try msg.appendNTimes(testing.allocator, 'x', big_len);
    try msg.appendSlice(testing.allocator, "2:op4:evale");
    // feed in 4096-byte slabs, as a socket would
    var i: usize = 0;
    while (i < msg.items.len) : (i += 4096) {
        try f.feed(msg.items[i..@min(i + 4096, msg.items.len)]);
    }
    const m = try f.next(arena.allocator());
    try testing.expect(m == .message);
    try testing.expectEqual(big_len, requestStr(m.message, "code").?.len);
}

test "Framer: malformed bytes are a protocol error, truncation is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = framerFixture();
    defer f.deinit();

    try f.feed("i42"); // truncated integer — legal prefix
    try testing.expect((try f.next(arena.allocator())) == .need_more);
    try f.feed("e"); // completes i42e
    try testing.expect((try f.next(arena.allocator())) == .message);

    var g = framerFixture();
    defer g.deinit();
    try g.feed("x"); // invalid prefix byte
    try testing.expectError(error.InvalidPrefix, g.next(arena.allocator()));
}

test "respond echoes request id + session ahead of op entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req_entries = [_]bencode.Decoded.Entry{
        .{ .key = "op", .value = .{ .str = "eval" } },
        .{ .key = "id", .value = .{ .str = "42" } },
        .{ .key = "session", .value = .{ .str = "sess-a" } },
    };
    const req = bencode.Decoded{ .dict = &req_entries };

    var out_buf: [256]u8 = undefined;
    var w: Writer = .fixed(&out_buf);
    const entries = [_]bencode.Decoded.Entry{
        .{ .key = "value", .value = .{ .str = "3" } },
    };
    try respond(&w, a, req, &entries);

    const decoded = try bencode.decode(a, w.buffered());
    try testing.expectEqualStrings("42", requestStr(decoded.value, "id").?);
    try testing.expectEqualStrings("sess-a", requestStr(decoded.value, "session").?);
    try testing.expectEqualStrings("3", requestStr(decoded.value, "value").?);
}

test "respond defaults absent id/session to bb's placeholders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req_entries = [_]bencode.Decoded.Entry{
        .{ .key = "op", .value = .{ .str = "clone" } },
    };
    const req = bencode.Decoded{ .dict = &req_entries };
    var out_buf: [256]u8 = undefined;
    var w: Writer = .fixed(&out_buf);
    try respond(&w, a, req, &.{});
    const decoded = try bencode.decode(a, w.buffered());
    try testing.expectEqualStrings("unknown", requestStr(decoded.value, "id").?);
    try testing.expectEqualStrings("none", requestStr(decoded.value, "session").?);
}
