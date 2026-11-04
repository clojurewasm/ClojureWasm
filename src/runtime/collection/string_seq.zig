// SPDX-License-Identifier: EPL-2.0
//! StringSeq (A13) — an O(1) VIEW seq over a string's codepoints, standing in
//! for the JVM's `clojure.lang.StringSeq`.
//!
//! `(seq s)` used to build an EAGER cons chain of every codepoint
//! (`sequence.zig` `stringToList`), and it built that chain by calling
//! `charset.codepointAt(s, i)` once per codepoint — a function that restarts a
//! `Utf8Iterator` at byte 0 and walks `i` codepoints to answer. n calls each
//! costing O(i) is O(n^2): measured 27 ms at 2 000 chars, 390 ms at 8 000,
//! 3 862 ms at 32 000, and **89 910 ms at 146 670**, against 0 ms on babashka
//! at every size. A downstream `(seq s)` used only as a truthiness test cost
//! 79 seconds. [refs: D-179]
//!
//! This is the view the `.string` arms of `seq` / `rest` / `next` already
//! named as their finished form. It holds `(string, byte offset)`, allocates
//! one fixed-size cell per step whatever the length, and copies nothing.
//!
//! Tag: A13 `.string_seq` was a day-1 reservation already declared across
//! every protocol table (`interface_membership.zig` ISeq / Sequential /
//! Counted / IHashEq / java.util.List / java.util.Collection) and already
//! named in `class_name.zig`, but had NO producer — the same position A14
//! `.array_seq` was in before O-058. So this costs no slot from
//! `heap_tag.unallocated`: the address and its protocol membership were
//! already spent, only the producer was missing.
//!
//! ## Why the cursor is a BYTE offset, not a codepoint index
//!
//! A codepoint index would reintroduce the very defect this replaces: every
//! `first` would have to walk the UTF-8 from the start to find its element. A
//! byte offset is the position itself, so `first` decodes in place and `rest`
//! advances by the length of the codepoint it just read — both O(1), whatever
//! the string's length or encoding.
//!
//! Invariant: `offset` is always ON a codepoint boundary and always strictly
//! inside the backing bytes. `make` answers nil rather than mint a view at or
//! past the end, mirroring `.range` and `.array_seq`, and that is what makes
//! `first` total.
//!
//! ## `count` is the one operation that stays a walk
//!
//! `.array_seq` counts by subtraction because a vector's length is its
//! element count. UTF-8 has no such identity: the remaining codepoint count is
//! only knowable by scanning. `countOf` scans (with an ASCII fast path), which
//! is what counting a seq costs anyway, and — unlike the eager chain — it
//! allocates nothing to do it. `(count "…")` on the STRING is likewise a scan
//! in this runtime, so the view is no worse than its backing.
//!
//! ## GC
//!
//! Holds `Value` children (`backing`, `meta`), so it registers a trace fn.
//! `make` performs exactly ONE allocation and stores `backing` after it, so a
//! collect inside `alloc` must not sweep `backing` — every call site passes a
//! value already rooted by its own caller (`args[0]` of seq/rest/next, or the
//! receiver StringSeq whose trace reaches the same backing). No fabrication
//! bracket is needed for a single-alloc builder. [ref: .dev/gc_rooting.md §A]
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.lang.StringSeq

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const string = @import("string.zig");

/// StringSeq (A13) — `backing` viewed from `offset` to its end.
pub const StringSeq = extern struct {
    header: HeapHeader,
    /// Read cursor in BYTES. Invariants: on a codepoint boundary, and
    /// `offset < backingBytes(backing).len`.
    offset: u32 = 0,
    /// Codepoints remaining from `offset`, or `COUNT_UNKNOWN` until first
    /// asked. A memo, not state: the backing is immutable, so once known it
    /// is exact forever, and `rest`/`drop` hand the successor `count - k` so
    /// a walk never rescans. Occupies the bytes the old `_pad` + alignment
    /// gap held, so the cell is still 32 bytes. [refs: CLJW-STRING-SEQ]
    cached_count: u32 = COUNT_UNKNOWN,
    /// The viewed string — a `.string`.
    backing: Value = Value.nil_val,
    /// Optional metadata map. A seq is IObj on the JVM (`ASeq` implements it),
    /// so `(with-meta (seq s) m)` must round-trip; dropping it would regress
    /// the eager chain this replaces, which carried meta for free.
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(StringSeq) >= 8);
        std.debug.assert(@offsetOf(StringSeq, "header") == 0);
    }
};

/// `cached_count` sentinel: not yet scanned. A view can never hold this many
/// codepoints — `offset` is a u32, so the backing is < 4 GiB of bytes.
pub const COUNT_UNKNOWN: u32 = std.math.maxInt(u32);

/// One decoded codepoint and the byte width it occupied.
pub const Step = struct { cp: u21, len: u32 };

/// Bytes of a viewable backing. A tag with no arm is not viewable and answers
/// the empty slice, which makes `make` return nil rather than mint a view
/// whose `first` would be undefined.
fn backingBytes(backing: Value) []const u8 {
    return switch (backing.tag()) {
        .string => string.asString(backing),
        else => &.{},
    };
}

/// Decode the codepoint at byte `off`. TOTAL: malformed UTF-8 yields the raw
/// byte as a one-byte codepoint rather than an error, so a view can never
/// wedge or loop on a string some other subsystem mis-encoded. Valid UTF-8 —
/// which every string minted by this runtime is — takes the exact path.
pub fn decodeAt(bytes: []const u8, off: usize) Step {
    const len = std.unicode.utf8ByteSequenceLength(bytes[off]) catch
        return .{ .cp = bytes[off], .len = 1 };
    if (off + len > bytes.len) return .{ .cp = bytes[off], .len = 1 };
    // utf8Decode is deprecated (awkward API); the fixed-width variants take a
    // [N]u8 by value (mirrors runtime/io/text_io.zig).
    const cp: u21 = switch (len) {
        2 => std.unicode.utf8Decode2(bytes[off..][0..2].*) catch
            return .{ .cp = bytes[off], .len = 1 },
        3 => std.unicode.utf8Decode3(bytes[off..][0..3].*) catch
            return .{ .cp = bytes[off], .len = 1 },
        4 => std.unicode.utf8Decode4(bytes[off..][0..4].*) catch
            return .{ .cp = bytes[off], .len = 1 },
        else => bytes[off],
    };
    return .{ .cp = cp, .len = @intCast(len) };
}

/// True when `seq` over this collection can be served as a view rather than a
/// copy. The one predicate producers consult, so adding a backing type is a
/// single arm in `backingBytes` plus this.
pub fn viewable(backing: Value) bool {
    return backing.tag() == .string;
}

/// View `backing` from byte `offset`. nil when the view would be empty — a
/// StringSeq is never empty (see the header invariant).
pub fn make(rt: *Runtime, backing: Value, offset: u32) !Value {
    return makeCounted(rt, backing, offset, COUNT_UNKNOWN);
}

/// `make` with the remaining codepoint count already known (or
/// `COUNT_UNKNOWN`) — how `rest`/`drop` carry the memo forward.
fn makeCounted(rt: *Runtime, backing: Value, offset: u32, count: u32) !Value {
    if (offset >= backingBytes(backing).len) return Value.nil_val;
    const ss = try rt.gc.alloc(StringSeq);
    ss.* = .{
        .header = HeapHeader.init(.string_seq),
        .offset = offset,
        .cached_count = count,
        .backing = backing,
    };
    return Value.encodeHeapPtr(.string_seq, ss);
}

pub fn backingOf(v: Value) Value {
    return v.decodePtr(*const StringSeq).backing;
}

pub fn offsetOf(v: Value) u32 {
    return v.decodePtr(*const StringSeq).offset;
}

/// The not-yet-seen bytes. The linear-walk entry point: a consumer that wants
/// every element decodes this slice in place instead of asking for element i.
pub fn remainingBytes(v: Value) []const u8 {
    const ss = v.decodePtr(*const StringSeq);
    return backingBytes(ss.backing)[ss.offset..];
}

/// `(first ss)` — total, by the never-empty invariant. O(1).
pub fn first(v: Value) Value {
    const ss = v.decodePtr(*const StringSeq);
    const bytes = backingBytes(ss.backing);
    return Value.initChar(@intCast(decodeAt(bytes, ss.offset).cp));
}

/// `(count ss)` — codepoints remaining. The first ask on a chain scans the
/// remaining bytes (see the header on why it cannot be a subtraction); the
/// answer is memoised in the cell and inherited by `rest`/`drop`, so every
/// later ask on this view or any successor is O(1). Without the memo a
/// count-guarded walk (`(> (count s) 1)` per step) is O(n^2).
pub fn countOf(v: Value) u32 {
    const ss = v.decodePtr(*StringSeq);
    if (ss.cached_count != COUNT_UNKNOWN) return ss.cached_count;
    const n = scanCount(remainingBytes(v));
    ss.cached_count = n;
    return n;
}

fn scanCount(rest_bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < rest_bytes.len) {
        // Continuation bytes are 0b10xxxxxx; every other byte starts a
        // codepoint. Counting starts is cheaper than decoding them.
        if (rest_bytes[i] < 0x80) {
            i += 1;
        } else {
            i += std.unicode.utf8ByteSequenceLength(rest_bytes[i]) catch 1;
        }
        n += 1;
    }
    return n;
}

/// `(rest ss)` / `(next ss)` — the same view one codepoint along, or nil at
/// the end. Callers apply the `rest`/`next` empty-tail convention (`rest`
/// lifts nil to the empty list at its own exit, `next` keeps nil). O(1).
pub fn rest(rt: *Runtime, v: Value) !Value {
    const ss = v.decodePtr(*const StringSeq);
    const bytes = backingBytes(ss.backing);
    const step = decodeAt(bytes, ss.offset);
    // Carry the count memo: one codepoint fewer, if it was known.
    const c = if (ss.cached_count == COUNT_UNKNOWN) COUNT_UNKNOWN else ss.cached_count - 1;
    return try makeCounted(rt, ss.backing, ss.offset + step.len, c);
}

/// Byte offset `n` codepoints past `from`, clamped to the end of `bytes`.
/// One forward pass — the walk `codepointAt` used to redo per element.
fn advance(bytes: []const u8, from: u32, n: u32) u32 {
    var off: usize = from;
    var left: u32 = n;
    while (left > 0 and off < bytes.len) : (left -= 1) {
        off += decodeAt(bytes, off).len;
    }
    return @intCast(@min(off, bytes.len));
}

/// `(nth ss i)` — O(i), a forward walk. Indexed access into UTF-8 is a walk by
/// nature; a consumer that wants every element should decode `remainingBytes`
/// once rather than call this in a loop, which would be quadratic again.
pub fn nth(v: Value, i: u32) Value {
    const ss = v.decodePtr(*const StringSeq);
    const bytes = backingBytes(ss.backing);
    const off = advance(bytes, ss.offset, i);
    if (off >= bytes.len) return Value.nil_val;
    return Value.initChar(@intCast(decodeAt(bytes, off).cp));
}

/// Drop `n` codepoints in ONE forward pass — `(nthrest ss n)` without minting
/// n intermediate views.
pub fn drop(rt: *Runtime, v: Value, n: u32) !Value {
    const ss = v.decodePtr(*const StringSeq);
    const bytes = backingBytes(ss.backing);
    const c = if (ss.cached_count == COUNT_UNKNOWN) COUNT_UNKNOWN else ss.cached_count -| n;
    return try makeCounted(rt, ss.backing, advance(bytes, ss.offset, n), c);
}

pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const StringSeq).meta;
}

/// `(with-meta ss m)` — a fresh view over the same backing at the same cursor.
/// Not routed through `make`, which carries no meta and would re-check an
/// invariant the receiver already satisfies. Meta does NOT propagate to `rest`,
/// matching the JVM: `ASeq.next()` returns a seq without the receiver's meta.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const src = v.decodePtr(*const StringSeq);
    const ss = try rt.gc.alloc(StringSeq);
    ss.* = .{
        .header = HeapHeader.init(.string_seq),
        .offset = src.offset,
        .cached_count = src.cached_count,
        .backing = src.backing,
        .meta = m,
    };
    return Value.encodeHeapPtr(.string_seq, ss);
}

/// Per-tag trace fn — the `backing` and `meta` children.
pub fn traceStringSeq(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ss: *StringSeq = @ptrCast(@alignCast(header));
    if (ss.backing.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ss.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register the StringSeq trace fn. Idempotent; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.string_seq, &traceStringSeq);
}

// --- tests ---

const testing = std.testing;

test {
    _ = @import("string_seq_count_test.zig");
}

const RuntimeFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() RuntimeFixture {
        var fix: RuntimeFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *RuntimeFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "StringSeq struct layout: HeapHeader at offset 0, 8-byte aligned" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(StringSeq, "header"));
    try testing.expect(@alignOf(StringSeq) >= 8);
    // 8-byte HeapHeader + cursor + backing + meta. Fixed size no matter how
    // long the string — that constancy, not the absolute number, is what
    // replaces the n-cell copy.
    try testing.expectEqual(@as(usize, 32), @sizeOf(StringSeq));
    try testing.expectEqual(@as(usize, 16), @offsetOf(StringSeq, "backing"));
}

test "make: never mints an empty view" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = try string.alloc(&fix.rt, "abc");
    // At or past the end is nil, not a count-0 StringSeq — the invariant that
    // makes `first` total.
    try testing.expect((try make(&fix.rt, s, 3)).isNil());
    try testing.expect((try make(&fix.rt, s, 99)).isNil());
    // An empty string has no view at all.
    try testing.expect((try make(&fix.rt, try string.alloc(&fix.rt, ""), 0)).isNil());
    // A non-viewable backing answers nil rather than minting a view whose
    // `first` would be undefined.
    try testing.expect((try make(&fix.rt, Value.initInteger(1), 0)).isNil());
}

test "first/rest walk codepoints, not bytes" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // One 1-byte, one 2-byte, one 3-byte and one 4-byte codepoint: every
    // UTF-8 width in one string, so a byte cursor that ignored width would
    // desynchronise on the second element.
    const s = try string.alloc(&fix.rt, "aé→𝄞");
    var cur = try make(&fix.rt, s, 0);

    const want = [_]u21{ 'a', 0xE9, 0x2192, 0x1D11E };
    for (want) |cp| {
        try testing.expect(!cur.isNil());
        try testing.expectEqual(Value.initChar(@intCast(cp)), first(cur));
        cur = try rest(&fix.rt, cur);
    }
    // Exhausted: the view ends at nil rather than at an empty view.
    try testing.expect(cur.isNil());
}

test "countOf counts codepoints from the cursor, mixed widths" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = try string.alloc(&fix.rt, "aé→𝄞"); // 1+2+3+4 = 10 bytes
    try testing.expectEqual(@as(usize, 10), string.asString(s).len);

    var cur = try make(&fix.rt, s, 0);
    try testing.expectEqual(@as(u32, 4), countOf(cur));
    cur = try rest(&fix.rt, cur); // past 'a'
    try testing.expectEqual(@as(u32, 3), countOf(cur));
    cur = try rest(&fix.rt, cur); // past 'é'
    try testing.expectEqual(@as(u32, 2), countOf(cur));
}

test "nth and drop advance by codepoint" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = try string.alloc(&fix.rt, "aé→𝄞");
    const v = try make(&fix.rt, s, 0);

    try testing.expectEqual(Value.initChar('a'), nth(v, 0));
    try testing.expectEqual(Value.initChar(0x2192), nth(v, 2));
    try testing.expectEqual(Value.initChar(0x1D11E), nth(v, 3));
    // Past the end is nil, not a wrapped or mid-codepoint read.
    try testing.expect(nth(v, 4).isNil());

    const d = try drop(&fix.rt, v, 3);
    try testing.expectEqual(Value.initChar(0x1D11E), first(d));
    // Dropping everything, and more than everything, both land on nil.
    try testing.expect((try drop(&fix.rt, v, 4)).isNil());
    try testing.expect((try drop(&fix.rt, v, 99)).isNil());
}

test "the view is O(1) per step: no allocation scales with length" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // 64 KiB of ASCII. The eager chain this replaces allocated one cons per
    // codepoint and re-walked the UTF-8 for each of them; the view allocates
    // one 32-byte cell per STEP and decodes in place, so taking three elements
    // off a 65 536-character string touches three cells.
    var buf: [65536]u8 = undefined;
    @memset(&buf, 'x');
    const s = try string.alloc(&fix.rt, &buf);

    const v = try make(&fix.rt, s, 0);
    try testing.expectEqual(@as(u32, 65536), countOf(v));
    try testing.expectEqual(Value.initChar('x'), first(v));

    const one = try rest(&fix.rt, v);
    try testing.expectEqual(@as(u32, 65535), countOf(one));
    try testing.expectEqual(@as(u32, 1), offsetOf(one));

    // Remaining bytes is the linear-walk entry point and must stay a view of
    // the backing, not a copy of it.
    try testing.expectEqual(@as(usize, 65535), remainingBytes(one).len);
}

test "decodeAt is total on malformed UTF-8" {
    // A lone continuation byte and a truncated 3-byte lead: both yield the raw
    // byte with width 1, so a walk always advances and can never loop.
    const lone = [_]u8{0x80};
    try testing.expectEqual(@as(u32, 1), decodeAt(&lone, 0).len);
    const truncated = [_]u8{ 0xE2, 0x82 };
    try testing.expectEqual(@as(u32, 1), decodeAt(&truncated, 0).len);
}

test "withMeta keeps the cursor and does not propagate to rest" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = try string.alloc(&fix.rt, "abc");
    const v = try make(&fix.rt, s, 1);
    const m = Value.initInteger(42); // any non-nil stand-in for a meta map

    const with = try withMeta(&fix.rt, v, m);
    try testing.expectEqual(m, metaOf(with));
    try testing.expectEqual(@as(u32, 1), offsetOf(with));
    try testing.expectEqual(Value.initChar('b'), first(with));
    // The receiver is untouched, and the tail carries no meta (JVM ASeq.next).
    try testing.expect(metaOf(v).isNil());
    try testing.expect(metaOf(try rest(&fix.rt, with)).isNil());
}
