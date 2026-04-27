//! Heap-backed string Value.
//!
//! Phase-3 minimum: an immutable byte slice tagged `HeapTag.string`.
//! The wrapper struct owns its own `[]u8` (duplicated from caller bytes
//! at `alloc` time), so the resulting Value outlives any per-eval
//! arena. `Runtime.trackHeap` registers a `freeString` callback that
//! `Runtime.deinit` invokes — Phase-5's mark-sweep GC will replace
//! that bookkeeping.
//!
//! Why not a Phase-1 small-string optimisation (inline tail of bytes
//! after the header)? Because Clojure strings are arbitrary-length and
//! the analyser's `.string` literal already arrives as a slice; one
//! `gpa.dupe` is cheaper than the branch-on-length the inline form
//! would need. Phase 8's GC + interning pass can revisit.

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;

/// Heap String. `bytes` is owned (duplicated at `alloc` time) so the
/// Value lives until `Runtime.deinit` frees it.
pub const String = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    bytes: []const u8,

    comptime {
        std.debug.assert(@alignOf(String) >= 8);
    }
};

/// Allocate a heap String holding a copy of `bytes`. Registers cleanup
/// with `rt.trackHeap` so `Runtime.deinit` frees both struct and bytes.
pub fn alloc(rt: *Runtime, bytes: []const u8) !Value {
    const owned = try rt.gpa.dupe(u8, bytes);
    errdefer rt.gpa.free(owned);
    const s = try rt.gpa.create(String);
    s.* = .{ .header = HeapHeader.init(.string), .bytes = owned };
    try rt.trackHeap(.{ .ptr = @ptrCast(s), .free = freeString });
    return Value.encodeHeapPtr(.string, s);
}

fn freeString(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const s: *String = @ptrCast(@alignCast(ptr));
    gpa.free(s.bytes);
    gpa.destroy(s);
}

/// Decode a String Value into its byte slice. Caller must already know
/// `val.tag() == .string`.
pub fn asString(val: Value) []const u8 {
    std.debug.assert(val.tag() == .string);
    return val.decodePtr(*String).bytes;
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
