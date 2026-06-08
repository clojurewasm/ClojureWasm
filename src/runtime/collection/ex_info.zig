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
//! ADR-0059 / ADR-0060 settle the multi-class catch question via
//! string-compared synthesized class names (see `className`).

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const string_mod = @import("string.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const StackFrame = @import("../error/info.zig").StackFrame;

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
    // ADR-0120 Stage A: the source location of the error this exception
    // represents, for faithful rendering — especially across a thread boundary,
    // where the worker's threadlocal `Info` dies but this GC-owned copy
    // survives. `origin_file` is GC-owned (duped like `message`, freed in
    // `finaliseGc`); `null`/0 ≡ unknown (the renderer falls back as before).
    origin_file_ptr: ?[*]const u8 = null,
    origin_file_len: usize = 0,
    origin_line: u32 = 0,
    origin_column: u16 = 0,
    // ADR-0120 §1 / D-336: the error's call-stack snapshot, so a thrown
    // exception renders its `Trace:` even after crossing a thread boundary
    // (the worker's threadlocal `trace_snapshot` dies with the thread). The
    // array AND each frame's strings are GC-owned (deep-copied into `gc.infra`,
    // freed in `finaliseGc`) — the same ownership story as `message` /
    // `origin_file`, so the ExInfo owns all its trace data outright rather than
    // borrowing arena-lifetime frame strings. `null`/0 ≡ no trace.
    trace_ptr: ?[*]const StackFrame = null,
    trace_len: usize = 0,

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
    return allocExceptionLoc(rt, msg_bytes, class, .{}, null);
}

/// `allocException` carrying the error's source location + call-stack trace
/// (ADR-0120 Stage A location + §1/D-336 trace). `loc.file` and every `trace`
/// frame's strings are GC-owned (deep-copied into `gc.infra`), so the whole
/// origin survives a thread boundary (the worker's threadlocal Info +
/// `trace_snapshot` die with the thread). An empty loc (`line == 0`) leaves
/// `origin_*` null; a null/empty `trace` leaves `trace_ptr` null — the renderer
/// falls back as before in each case.
pub fn allocExceptionLoc(rt: *Runtime, msg_bytes: []const u8, class: []const u8, loc: SourceLocation, trace: ?[]const StackFrame) !Value {
    const owned_msg = try rt.gc.infra.dupe(u8, msg_bytes);
    errdefer rt.gc.infra.free(owned_msg);
    const owned_file: ?[]const u8 = if (loc.line != 0 and loc.file.len > 0)
        try rt.gc.infra.dupe(u8, loc.file)
    else
        null;
    errdefer if (owned_file) |of| rt.gc.infra.free(of);
    const owned_trace: ?[]StackFrame = if (trace) |t| (if (t.len > 0) try dupeTrace(rt.gc.infra, t) else null) else null;
    errdefer if (owned_trace) |ot| freeTrace(rt.gc.infra, ot);
    const ex = try rt.gc.alloc(ExInfo);
    ex.* = .{
        .header = HeapHeader.init(.ex_info),
        .message_ptr = owned_msg.ptr,
        .message_len = owned_msg.len,
        .data = .nil_val,
        .cause = .nil_val,
        .class_name_ptr = class.ptr,
        .class_name_len = class.len,
        .origin_file_ptr = if (owned_file) |of| of.ptr else null,
        .origin_file_len = if (owned_file) |of| of.len else 0,
        .origin_line = loc.line,
        .origin_column = loc.column,
        .trace_ptr = if (owned_trace) |ot| ot.ptr else null,
        .trace_len = if (owned_trace) |ot| ot.len else 0,
    };
    return Value.encodeHeapPtr(.ex_info, ex);
}

/// Deep-copy a call-stack snapshot into GC-infra storage: the frame array plus
/// each frame's `fn_name`/`ns`/`file` bytes, so the ExInfo owns all its trace
/// data and the source (a threadlocal `trace_snapshot` that dies with the
/// worker, or an arena slice) may go away. Mirrors the `message` dup ownership.
fn dupeTrace(gc_infra: std.mem.Allocator, trace: []const StackFrame) ![]StackFrame {
    const arr = try gc_infra.alloc(StackFrame, trace.len);
    var done: usize = 0;
    errdefer {
        for (arr[0..done]) |fr| freeFrameStrings(gc_infra, fr);
        gc_infra.free(arr);
    }
    for (trace, 0..) |src, i| {
        const fn_name: ?[]const u8 = if (src.fn_name) |s| try gc_infra.dupe(u8, s) else null;
        errdefer if (fn_name) |s| gc_infra.free(s);
        const ns: ?[]const u8 = if (src.ns) |s| try gc_infra.dupe(u8, s) else null;
        errdefer if (ns) |s| gc_infra.free(s);
        const file: ?[]const u8 = if (src.file) |s| try gc_infra.dupe(u8, s) else null;
        arr[i] = .{ .fn_name = fn_name, .ns = ns, .file = file, .line = src.line, .column = src.column };
        done = i + 1;
    }
    return arr;
}

fn freeFrameStrings(gc_infra: std.mem.Allocator, fr: StackFrame) void {
    if (fr.fn_name) |s| gc_infra.free(s);
    if (fr.ns) |s| gc_infra.free(s);
    if (fr.file) |s| gc_infra.free(s);
}

fn freeTrace(gc_infra: std.mem.Allocator, trace: []StackFrame) void {
    for (trace) |fr| freeFrameStrings(gc_infra, fr);
    gc_infra.free(trace);
}

/// Build a Throwable-family value from Java constructor args (D-198 /
/// clj-parity C5): `()` → no message, `(msg)` / `(msg cause)` → message
/// (+ optional cause). cljw has no JVM class hierarchy (ADR-0059), so
/// `(Exception. …)` mints an `.ex_info` tagged with the comptime-static
/// `class` name — `(catch Exception …)` / `(class …)` / `.getMessage`
/// then work through the existing ex_info bridge. Shared by the
/// Throwable / Exception / RuntimeException `<init>` surfaces.
pub fn allocExceptionFromArgs(rt: *Runtime, args: []const Value, class: []const u8) !Value {
    const msg: []const u8 = if (args.len >= 1 and args[0].tag() == .string) string_mod.asString(args[0]) else "";
    const cause_val: Value = if (args.len >= 2) args[1] else .nil_val;
    const owned_msg = try rt.gc.infra.dupe(u8, msg);
    errdefer rt.gc.infra.free(owned_msg);
    const ex = try rt.gc.alloc(ExInfo);
    ex.* = .{
        .header = HeapHeader.init(.ex_info),
        .message_ptr = owned_msg.ptr,
        .message_len = owned_msg.len,
        .data = .nil_val,
        .cause = cause_val,
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
    // ADR-0120 Stage A: free the GC-owned origin file copy (if any).
    if (ex.origin_file_ptr) |p| gc.infra.free(p[0..ex.origin_file_len]);
    // ADR-0120 §1 / D-336: free the deep-copied trace (array + frame strings).
    if (ex.trace_ptr) |p| freeTrace(gc.infra, @constCast(p[0..ex.trace_len]));
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

/// The error's source location (ADR-0120 Stage A), or an unknown loc
/// (`line == 0`) when none was captured. The renderer (`buildThrownInfo`)
/// reads this so a thrown exception shows where it came from.
pub fn originLoc(val: Value) SourceLocation {
    const ex = asExInfo(val);
    const file: []const u8 = if (ex.origin_file_ptr) |p| p[0..ex.origin_file_len] else "unknown";
    return .{ .file = file, .line = ex.origin_line, .column = ex.origin_column };
}

/// The error's captured call-stack trace (ADR-0120 §1 / D-336), or `null` when
/// none was carried. The renderer (`buildThrownInfo`) reads this so a thrown
/// exception shows its `Trace:` even after crossing a worker-thread boundary.
pub fn originTrace(val: Value) ?[]const StackFrame {
    const ex = asExInfo(val);
    return if (ex.trace_ptr) |p| p[0..ex.trace_len] else null;
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

test "allocExceptionLoc round-trips the origin location; allocException leaves it unknown (ADR-0120 Stage A)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit(); // leak detector also covers the GC-owned origin_file free

    const with_loc = try allocExceptionLoc(&rt, "boom", "ArithmeticException", .{ .file = "f.clj", .line = 7, .column = 3 }, null);
    const ol = originLoc(with_loc);
    try testing.expectEqualStrings("f.clj", ol.file);
    try testing.expectEqual(@as(u32, 7), ol.line);
    try testing.expectEqual(@as(u16, 3), ol.column);

    // No loc (line 0) → origin stays unknown (the renderer falls back).
    const no_loc = try allocException(&rt, "boom", "ExceptionInfo");
    try testing.expectEqual(@as(u32, 0), originLoc(no_loc).line);
}

test "allocExceptionLoc deep-copies the trace; it round-trips and survives source mutation (D-336)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit(); // leak detector covers the GC-owned trace array + frame strings

    var fn_name: [4]u8 = "boom".*;
    var frames = [_]StackFrame{
        .{ .fn_name = fn_name[0..], .ns = "user", .file = "f.clj", .line = 2, .column = 5 },
    };
    const v = try allocExceptionLoc(&rt, "boom", "ArithmeticException", .{ .file = "f.clj", .line = 2, .column = 5 }, frames[0..]);

    // Mutate the source after alloc — the ExInfo must hold its own deep copy.
    fn_name[0] = 'Z';
    frames[0].line = 999;

    const tr = originTrace(v).?;
    try testing.expectEqual(@as(usize, 1), tr.len);
    try testing.expectEqualStrings("boom", tr[0].fn_name.?);
    try testing.expectEqualStrings("user", tr[0].ns.?);
    try testing.expectEqual(@as(u32, 2), tr[0].line);

    // No trace passed → originTrace is null (the renderer falls back).
    const no_tr = try allocExceptionLoc(&rt, "boom", "ExceptionInfo", .{}, null);
    try testing.expect(originTrace(no_tr) == null);
}

test "Runtime.deinit frees ExInfo without leaking message bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    _ = try alloc(&rt, "leaked-without-tracking", .nil_val, .nil_val);
    rt.deinit();
    // No assertion — testing.allocator's leak detector is the gate.
}
