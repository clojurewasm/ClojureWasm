// SPDX-License-Identifier: EPL-2.0
//! Heap-backed string Value.
//!
//! An immutable byte slice tagged `HeapTag.string`, copied from the
//! caller's bytes at `alloc` time so the Value outlives any per-eval arena.
//!
//! Storage is chosen by length. A payload that fits a page-heap cell
//! (`max_inline_bytes`) lives in the tail of the String's own GC cell: one
//! allocation, freed with the cell by sweep. A larger one is an `infra`
//! allocation freed by the per-tag finaliser (`registerGcHooks`). Measured
//! 2026-10-23: the separate `gpa.dupe` + finaliser `free` per String was the
//! dominant non-interpreter cost of `(str i)` in a loop (libc malloc/free
//! about 12% of the profile), on top of the cell allocation it duplicated.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const page_heap_mod = @import("../gc/page_heap.zig");

/// Heap String. `bytes_ptr` + `bytes_len` decompose what was previously
/// a `[]const u8` slice; the decomposition lets the struct be `extern`,
/// which preserves declaration order so `header` lands at offset 0
/// (required by `gc.alloc(T)`'s comptime invariant). Use `bytes()` to
/// recover the slice view.
///
/// Lifetime: the wrapper is GC-managed. `storage` says where the bytes
/// are: `.inline_tail` bytes are part of the cell and die with it;
/// `.owned` bytes were `gc.infra.dupe`d and the per-tag finaliser
/// (`finaliseGc`) frees them before sweep frees the wrapper.
pub const String = extern struct {
    header: HeapHeader,
    /// Where the payload lives. Occupies a former padding byte.
    storage: Storage = .owned,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    bytes_ptr: [*]const u8,
    bytes_len: usize,

    pub const Storage = enum(u8) {
        /// `bytes_ptr` is an `infra` allocation the finaliser frees.
        owned = 0,
        /// `bytes_ptr` is the tail of this String's own GC cell.
        inline_tail = 1,
    };

    comptime {
        std.debug.assert(@alignOf(String) >= 8);
        std.debug.assert(@offsetOf(String, "header") == 0);
    }

    pub fn bytes(self: *const String) []const u8 {
        return self.bytes_ptr[0..self.bytes_len];
    }
};

/// Longest payload stored inline, as the tail of the String's own GC cell,
/// so the whole cell stays a page-heap cell (`page_heap.max_small_bytes`).
pub const max_inline_bytes: usize = page_heap_mod.max_small_bytes - @sizeOf(String);

/// Allocate a heap String holding a copy of `bytes`.
///
/// A payload of up to `max_inline_bytes` goes into the tail of the String's
/// own GC cell: one page-heap allocation, and nothing for the finaliser to
/// free. The allocation runs inside a fabrication region (no collect in the
/// alloc prologue) because `byte_view` may be the inline tail of a String
/// the caller holds unrooted, and it must survive until it is copied. A
/// larger payload is `dupe`d through `rt.gc.infra` (= `rt.gpa`) before the
/// cell exists, and released by the per-tag finaliser.
pub fn alloc(rt: *Runtime, byte_view: []const u8) !Value {
    if (byte_view.len <= max_inline_bytes) {
        const n = byte_view.len;
        rt.gc.enterFabrication();
        defer rt.gc.exitFabrication();
        const s = try rt.gc.allocWithTail(String, n);
        const tail: [*]u8 = @ptrCast(@as([*]String, @ptrCast(s)) + 1);
        @memcpy(tail[0..n], byte_view);
        s.* = .{
            .header = HeapHeader.init(.string),
            .storage = .inline_tail,
            .bytes_ptr = tail,
            .bytes_len = n,
        };
        return Value.encodeHeapPtr(.string, s);
    }
    const owned = try rt.gc.infra.dupe(u8, byte_view);
    errdefer rt.gc.infra.free(owned);
    rt.gc.noteOwnedAlloc(owned.len);
    const s = try rt.gc.alloc(String);
    s.* = .{
        .header = HeapHeader.init(.string),
        .bytes_ptr = owned.ptr,
        .bytes_len = owned.len,
    };
    return Value.encodeHeapPtr(.string, s);
}

/// Per-tag finaliser called by sweep / GcHeap.deinit before unlinking +
/// rawFree. Frees the owned bytes slice back to `gc.infra`; the wrapper
/// struct's memory is then rawFreed by the calling layer.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const s: *String = @ptrCast(@alignCast(header));
    if (s.storage == .inline_tail) return;
    gc.infra.free(s.bytes());
}

/// Register the string finaliser into `tag_ops.tag_finaliser_table`.
/// Idempotent at the same fn pointer (`tag_ops.registerFinaliser`);
/// `Runtime.init` calls this so registration lands before the first
/// allocation.
/// D-573: a live String's cost is its byte payload, not its 32-byte wrapper.
/// An inline payload is already part of the cell's recorded size.
fn ownedBytes(header: *HeapHeader) usize {
    const str: *String = @ptrCast(@alignCast(header));
    if (str.storage == .inline_tail) return 0;
    return str.bytes_len;
}

pub fn registerGcHooks() void {
    tag_ops.registerOwnedBytes(.string, &ownedBytes);
    tag_ops.registerFinaliser(.string, &finaliseGc);
}

/// Decode a String Value into its byte slice. Caller must already know
/// `val.tag() == .string`.
pub fn asString(val: Value) []const u8 {
    std.debug.assert(val.tag() == .string);
    return val.decodePtr(*String).bytes();
}

/// Number of Unicode codepoints in `s` (the cljw `(count "…")` unit — cljw
/// chars are codepoints, not UTF-16 units; ASCII matches the JVM char count).
/// Falls back to the byte length if `s` is not valid UTF-8.
pub fn codepointCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The `idx`-th codepoint of `s` (0-based), or `null` if `idx` is out of
/// range. Used by `nth`/`get` on a String (clj indexes a String as Indexed).
/// Indexed by codepoint to match cljw's char model; ASCII matches the JVM.
pub fn codepointAt(s: []const u8, idx: usize) ?u21 {
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| : (n += 1) {
        if (n == idx) return cp;
    }
    return null;
}

// --- tests ---

const testing = std.testing;

test "String alignment" {
    try testing.expect(@alignOf(String) >= 8);
}

test "alloc returns a .string-tagged Value with the original bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const v = try alloc(&rt, "hello");
    try testing.expect(v.tag() == .string);
    try testing.expectEqualStrings("hello", asString(v));
}

test "alloc duplicates the input bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var src_buf: [8]u8 = "abc-temp".*;
    const v = try alloc(&rt, src_buf[0..3]);
    // Mutate the source after alloc: the heap String must not change.
    src_buf[0] = 'Z';
    try testing.expectEqualStrings("abc", asString(v));
}

fn allocFailingHarness(alloc_inner: std.mem.Allocator) !void {
    var th = std.Io.Threaded.init(alloc_inner, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), alloc_inner);
    defer rt.deinit();
    _ = try alloc(&rt, "hello-world");
}

test "alloc returns OOM without leaking under each allocation failure (uniform errdefer)" {
    try testing.checkAllAllocationFailures(testing.allocator, allocFailingHarness, .{});
}

test "a short payload is stored inline; a long one is an owned infra block" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const short = try alloc(&rt, "12345");
    const s = short.decodePtr(*String);
    try testing.expectEqual(String.Storage.inline_tail, s.storage);
    try testing.expectEqual(@as(usize, 0), ownedBytes(&s.header));
    try testing.expectEqualStrings("12345", asString(short));

    const big = try testing.allocator.alloc(u8, max_inline_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const long = try alloc(&rt, big);
    const l = long.decodePtr(*String);
    try testing.expectEqual(String.Storage.owned, l.storage);
    try testing.expectEqual(big.len, ownedBytes(&l.header));
    try testing.expectEqualSlices(u8, big, asString(long));

    const edge = try alloc(&rt, big[0..max_inline_bytes]);
    try testing.expectEqual(String.Storage.inline_tail, edge.decodePtr(*String).storage);
}

test "alloc handles the empty string" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const v = try alloc(&rt, "");
    try testing.expectEqualStrings("", asString(v));
}

test "Runtime.deinit frees tracked Strings (no leak)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    _ = try alloc(&rt, "leaked-without-tracking");
    _ = try alloc(&rt, "second");
    rt.deinit();
    // No assertion — testing.allocator's leak detector is the gate.
}
