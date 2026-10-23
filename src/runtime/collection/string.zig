// SPDX-License-Identifier: EPL-2.0
//! Heap-backed string Value.
//!
//! An immutable byte slice tagged `HeapTag.string`. The wrapper struct
//! owns its own `[]u8` (duplicated from caller bytes at `alloc` time),
//! so the resulting Value outlives any per-eval arena. The bytes are
//! freed by a per-tag GC finaliser (registered via `registerGcHooks`;
//! see L24-34) before mark-sweep rawFrees the wrapper.
//!
//! Why not a Phase-1 small-string optimisation (inline tail of bytes
//! after the header)? Because Clojure strings are arbitrary-length and
//! the analyser's `.string` literal already arrives as a slice; one
//! `gpa.dupe` is cheaper than the branch-on-length the inline form
//! would need. A future string-interning pass could revisit this.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");

/// Heap String. `bytes_ptr` + `bytes_len` decompose what was previously
/// a `[]const u8` slice; the decomposition lets the struct be `extern`,
/// which preserves declaration order so `header` lands at offset 0
/// (required by `gc.alloc(T)`'s comptime invariant). Use `bytes()` to
/// recover the slice view.
///
/// Lifetime: the byte storage is owned (duplicated at `alloc` time via
/// `gc.infra.dupe`); the wrapper struct itself is GC-managed through
/// `gc.alloc(String)`. The per-tag finaliser (`finaliseGc`, registered
/// at `Runtime.init` time via `registerGcHooks`) frees the bytes back
/// to `gc.infra` before sweep rawFrees the wrapper memory.
pub const String = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    bytes_ptr: [*]const u8,
    bytes_len: usize,

    comptime {
        std.debug.assert(@alignOf(String) >= 8);
        std.debug.assert(@offsetOf(String, "header") == 0);
    }

    pub fn bytes(self: *const String) []const u8 {
        return self.bytes_ptr[0..self.bytes_len];
    }
};

/// Allocate a heap String holding a copy of `bytes`. The byte storage
/// is `dupe`d through `rt.gc.infra` (= `rt.gpa`) so the per-tag
/// finaliser can release it back; the wrapper struct goes through
/// `rt.gc.alloc(String)` so it appears on the GC's allocations list +
/// participates in mark / sweep like any other Value.
pub fn alloc(rt: *Runtime, byte_view: []const u8) !Value {
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
    gc.infra.free(s.bytes());
}

/// Register the string finaliser into `tag_ops.tag_finaliser_table`.
/// Idempotent at the same fn pointer (`tag_ops.registerFinaliser`);
/// `Runtime.init` calls this so registration lands before the first
/// allocation.
/// D-573: a live String's cost is its byte payload, not its 32-byte wrapper.
fn ownedBytes(header: *HeapHeader) usize {
    const str: *String = @ptrCast(@alignCast(header));
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
