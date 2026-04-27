//! Heap-backed `ex-info` Value.
//!
//! Mirrors Clojure's `clojure.lang.ExceptionInfo`: a structured error
//! Value carrying a human-readable message, a data Value (typically a
//! map but we accept any Value at Phase 3.10), and an optional cause
//! Value (the originating exception, or nil).
//!
//! ### Layout
//!
//! ```
//! ┌─────────────┬────────┬────────────┬──────┬───────┐
//! │ HeapHeader  │ _pad   │ message    │ data │ cause │
//! │ 2 B         │ 6 B    │ slice 16 B │ 8 B  │ 8 B   │
//! └─────────────┴────────┴────────────┴──────┴───────┘
//! ```
//!
//! `message` is owned (duplicated at `alloc` time) so the Value
//! outlives the per-eval arena. `data` and `cause` are Values — they
//! are NOT duped here; the caller passes Values that already live on
//! the heap (or are immediates).
//!
//! ### Why a single struct, not a v1-style class hierarchy
//!
//! Clojure JVM's `ExceptionInfo` extends `RuntimeException`; its data
//! is reachable via `getData()`. We have no class hierarchy (ROADMAP
//! §13 rejects them) — every ex-info Value has the same shape, the
//! "class" name `"ExceptionInfo"` is a string compared at catch time.
//! Phase 5+ may revisit when interop / Tier-A test coverage forces
//! multi-class catch.

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;

/// Heap ExInfo. `message` is owned (duped from caller bytes); `data`
/// and `cause` are Values (`cause = .nil_val` when absent, mirroring
/// the `(quote ())` → nil convention from §9.5/3.6).
pub const ExInfo = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    message: []const u8,
    data: Value,
    cause: Value,

    comptime {
        std.debug.assert(@alignOf(ExInfo) >= 8);
    }
};

/// Allocate a heap ExInfo. `msg_bytes` is duplicated; `data_v` /
/// `cause_v` are stored by Value (no copy). Pass `cause_v = .nil_val`
/// for the 2-arg `(ex-info msg data)` form.
pub fn alloc(rt: *Runtime, msg_bytes: []const u8, data_v: Value, cause_v: Value) !Value {
    const owned_msg = try rt.gpa.dupe(u8, msg_bytes);
    errdefer rt.gpa.free(owned_msg);
    const ex = try rt.gpa.create(ExInfo);
    ex.* = .{
        .header = HeapHeader.init(.ex_info),
        .message = owned_msg,
        .data = data_v,
        .cause = cause_v,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(ex), .free = freeExInfo });
    return Value.encodeHeapPtr(.ex_info, ex);
}

fn freeExInfo(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const ex: *ExInfo = @ptrCast(@alignCast(ptr));
    gpa.free(ex.message);
    gpa.destroy(ex);
}

/// Decode an ExInfo Value into the heap struct pointer. Caller must
/// already know `val.tag() == .ex_info`.
pub fn asExInfo(val: Value) *const ExInfo {
    std.debug.assert(val.tag() == .ex_info);
    return val.decodePtr(*const ExInfo);
}

/// Convenience: pull the message slice without exposing the struct.
pub fn message(val: Value) []const u8 {
    return asExInfo(val).message;
}

/// Convenience: pull the data Value.
pub fn data(val: Value) Value {
    return asExInfo(val).data;
}

/// Convenience: pull the cause Value (`.nil_val` when no cause).
pub fn cause(val: Value) Value {
    return asExInfo(val).cause;
}

// --- tests ---

const testing = std.testing;

test "ExInfo alignment is at least 8 bytes" {
    try testing.expect(@alignOf(ExInfo) >= 8);
}

test "alloc returns an .ex_info-tagged Value with the original parts" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const data_val = Value.initInteger(42);
    const v = try alloc(&rt, "boom", data_val, .nil_val);
    try testing.expect(v.tag() == .ex_info);
    try testing.expectEqualStrings("boom", message(v));
    try testing.expectEqual(data_val, data(v));
    try testing.expect(cause(v).isNil());
}

test "alloc duplicates the message bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var src: [4]u8 = "boom".*;
    const v = try alloc(&rt, src[0..], .nil_val, .nil_val);
    src[0] = 'Z';
    try testing.expectEqualStrings("boom", message(v));
}

test "cause non-nil round-trips" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const inner = try alloc(&rt, "inner", .nil_val, .nil_val);
    const outer = try alloc(&rt, "outer", .nil_val, inner);
    try testing.expectEqualStrings("inner", message(cause(outer)));
}

test "Runtime.deinit frees ExInfo without leaking message bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    _ = try alloc(&rt, "leaked-without-tracking", .nil_val, .nil_val);
    rt.deinit();
    // No assertion — testing.allocator's leak detector is the gate.
}
