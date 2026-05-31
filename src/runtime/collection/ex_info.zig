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
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Heap ExInfo. `message` is owned (duped from caller bytes); `data`
/// and `cause` are Values (`cause = .nil_val` when absent, mirroring
/// the `(quote ())` → nil convention from §9.5/3.6). `extern struct`
/// for declaration-ordered layout (HeapHeader at offset 0); slice
/// decomposed into `message_ptr` + `message_len` with a `message()`
/// method for slice recovery.
pub const ExInfo = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    message_ptr: [*]const u8,
    message_len: usize,
    data: Value,
    cause: Value,
    // ADR-0060: the exception class this Value represents. `null` ≡
    // "ExceptionInfo" (a real `(ex-info …)`); a non-null class
    // (`"ArithmeticException"`, …) marks a runtime-synthesized internal
    // error. The bytes are a comptime-static catalog string (NOT duped,
    // NOT GC-traced/freed) — `kindToHostClass` only returns string
    // literals. So `finaliseGc`/`traceGc` are unchanged.
    class_name_ptr: ?[*]const u8 = null,
    class_name_len: usize = 0,

    comptime {
        std.debug.assert(@alignOf(ExInfo) >= 8);
        std.debug.assert(@offsetOf(ExInfo, "header") == 0);
    }

    pub fn message(self: *const ExInfo) []const u8 {
        return self.message_ptr[0..self.message_len];
    }

    /// The synthesized exception class, or `null` for a real ex-info.
    pub fn className(self: *const ExInfo) ?[]const u8 {
        const p = self.class_name_ptr orelse return null;
        return p[0..self.class_name_len];
    }
};

/// Allocate a heap ExInfo. `msg_bytes` is duplicated through
/// `rt.gc.infra`; `data_v` / `cause_v` are stored by Value (no copy).
/// Pass `cause_v = .nil_val` for the 2-arg `(ex-info msg data)` form.
pub fn alloc(rt: *Runtime, msg_bytes: []const u8, data_v: Value, cause_v: Value) !Value {
    const owned_msg = try rt.gc.infra.dupe(u8, msg_bytes);
    errdefer rt.gc.infra.free(owned_msg);
    const ex = try rt.gc.alloc(ExInfo);
    ex.* = .{
        .header = HeapHeader.init(.ex_info),
        .message_ptr = owned_msg.ptr,
        .message_len = owned_msg.len,
        .data = data_v,
        .cause = cause_v,
    };
    return Value.encodeHeapPtr(.ex_info, ex);
}

/// Allocate a synthesized internal-error exception (ADR-0060): an
/// `.ex_info` Value carrying the Kind-derived `class_name` (so `(catch
/// ArithmeticException …)` matches and `(instance? ExceptionInfo …)` is
/// false), `nil` data (matching JVM: a bare exception has no ex-data),
/// no cause. `class_name` is a comptime-static catalog string, stored by
/// pointer (not duped); `msg_bytes` IS duped like `alloc`.
pub fn allocException(rt: *Runtime, msg_bytes: []const u8, class: []const u8) !Value {
    const owned_msg = try rt.gc.infra.dupe(u8, msg_bytes);
    errdefer rt.gc.infra.free(owned_msg);
    const ex = try rt.gc.alloc(ExInfo);
    ex.* = .{
        .header = HeapHeader.init(.ex_info),
        .message_ptr = owned_msg.ptr,
        .message_len = owned_msg.len,
        .data = .nil_val,
        .cause = .nil_val,
        .class_name_ptr = class.ptr,
        .class_name_len = class.len,
    };
    return Value.encodeHeapPtr(.ex_info, ex);
}

/// Per-tag finaliser called by sweep / GcHeap.deinit before unlink +
/// rawFree. Frees the owned message slice back to `gc.infra`.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ex: *ExInfo = @ptrCast(@alignCast(header));
    gc.infra.free(ex.message());
}

/// Per-tag trace fn called by mark phase. Walks `data` + `cause`
/// (Values that may reference heap-managed children).
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ex: *ExInfo = @ptrCast(@alignCast(header));
    if (ex.data.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (ex.cause.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register ExInfo's finaliser + trace into tag_ops tables.
/// Idempotent at the same fn pointers; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerFinaliser(.ex_info, &finaliseGc);
    tag_ops.registerTrace(.ex_info, &traceGc);
}

/// Decode an ExInfo Value into the heap struct pointer. Caller must
/// already know `val.tag() == .ex_info`.
pub fn asExInfo(val: Value) *const ExInfo {
    std.debug.assert(val.tag() == .ex_info);
    return val.decodePtr(*const ExInfo);
}

/// Convenience: pull the message slice without exposing the struct.
pub fn message(val: Value) []const u8 {
    return asExInfo(val).message();
}

/// Convenience: pull the data Value.
pub fn data(val: Value) Value {
    return asExInfo(val).data;
}

/// Convenience: pull the cause Value (`.nil_val` when no cause).
pub fn cause(val: Value) Value {
    return asExInfo(val).cause;
}

/// Convenience: the synthesized exception class, or `null` for a real
/// `(ex-info …)` Value (ADR-0060). A non-null result means this Value is
/// a runtime-synthesized internal error, NOT a user ExceptionInfo.
pub fn className(val: Value) ?[]const u8 {
    return asExInfo(val).className();
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

fn allocFailingHarness(alloc_inner: std.mem.Allocator) !void {
    var th = std.Io.Threaded.init(alloc_inner, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), alloc_inner);
    defer rt.deinit();
    _ = try alloc(&rt, "boom", .nil_val, .nil_val);
}

test "alloc returns OOM without leaking under each allocation failure (uniform errdefer)" {
    try testing.checkAllAllocationFailures(testing.allocator, allocFailingHarness, .{});
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
