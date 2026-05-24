// SPDX-License-Identifier: EPL-2.0
//! Regex heap-Value carrier — namespace-neutral per F-009.
//!
//! Wraps the compiled `Program` IR from `compile.zig` into a
//! `HeapTag.regex` Value (slot B7 per ADR-0027). Two surfaces
//! consume it: `lang/primitive/regex.zig` (clojure.core
//! `re-pattern` / `re-find` / `re-matches`) and
//! `runtime/java/util/regex/Pattern.zig` (Java-surface dispatch
//! at Phase 7+).
//!
//! ## Lifetime
//!
//! The wrapper struct lives on `rt.gc.alloc` (mark-sweep heap).
//! The `Program` it points to + its `insts` slice + the source-
//! string copy live on `rt.gc.infra` (process-lifetime GPA per
//! F-006). The per-tag finaliser chains
//! `program.deinit(infra) + infra.destroy(program) +
//! infra.free(source)` on sweep.
//!
//! ## Caching deferred (D-052)
//!
//! ADR-0031 Alt-3 (reader-time intern + content-addressed
//! `Program` cache) is the natural follow-up — every
//! `(re-pattern "abc")` with the same source body would dedupe
//! to one `Program`. Cycle 1c keeps each compile distinct; the
//! Alt-3 promotion is non-breaking (extend the wrapper to point
//! into a cache arena) and is tracked at Phase 10+ planning per
//! D-052.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const compile = @import("compile.zig");

/// Heap-managed regex Value. `header` lives at offset 0 (gc.alloc
/// invariant); `program` + `source` payload live on `gc.infra`.
/// `meta` carries optional user metadata (Clojure idiomatic
/// `(with-meta r {:source "..."})`).
pub const Regex = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// Pattern source (e.g., `"\\d+"`) — duplicated onto gc.infra.
    /// Owned by this Regex; finaliser frees it.
    source_ptr: [*]const u8,
    source_len: usize,
    /// Compiled IR. Boxed on gc.infra so the wrapper struct stays
    /// pointer-aligned. Finaliser chains program.deinit +
    /// infra.destroy.
    program: *compile.Program,
    /// Optional metadata map.
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(Regex) >= 8);
        std.debug.assert(@offsetOf(Regex, "header") == 0);
    }

    pub fn source(self: *const Regex) []const u8 {
        return self.source_ptr[0..self.source_len];
    }
};

pub const AllocError = compile.CompileError;

/// Compile `pattern_source` and wrap the result in a fresh Regex
/// Value. Returns the encoded HeapPtr Value (tag = .regex).
pub fn alloc(rt: *Runtime, pattern_source: []const u8, flags: compile.Flags) AllocError!Value {
    // Source copy first (so the errdefer chain unwinds cleanly).
    const src_copy = try rt.gc.infra.dupe(u8, pattern_source);
    errdefer rt.gc.infra.free(src_copy);

    // Compile (insts on gc.infra so they survive past arena tear-down
    // and align with the Program pointer that's also on infra).
    var prog = try compile.compile(rt.gc.infra, pattern_source, flags);
    errdefer prog.deinit(rt.gc.infra);

    // Box the Program so the Regex carries a pointer (extern-safe).
    const prog_ptr = try rt.gc.infra.create(compile.Program);
    errdefer rt.gc.infra.destroy(prog_ptr);
    prog_ptr.* = prog;

    const r = try rt.gc.alloc(Regex);
    r.* = .{
        .header = HeapHeader.init(.regex),
        .source_ptr = src_copy.ptr,
        .source_len = src_copy.len,
        .program = prog_ptr,
        .meta = Value.nil_val,
    };
    return Value.encodeHeapPtr(.regex, r);
}

/// Decode a regex Value back to its `*const Regex`. Caller must
/// have verified `v.tag() == .regex`.
pub fn asRegex(v: Value) *const Regex {
    std.debug.assert(v.tag() == .regex);
    return v.decodePtr(*const Regex);
}

/// Per-tag finaliser (sweep). Releases Program insts + Program
/// box + source string.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Regex = @ptrCast(@alignCast(header));
    r.program.deinit(gc.infra);
    gc.infra.destroy(r.program);
    gc.infra.free(r.source_ptr[0..r.source_len]);
}

/// Per-tag trace fn — walks only `meta` (source / program live on
/// gc.infra and are reclaimed by the finaliser, not the trace).
pub fn traceRegex(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Regex = @ptrCast(@alignCast(header));
    if (r.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.regex, &traceRegex);
    tag_ops.registerFinaliser(.regex, &finaliseGc);
}

// --- tests ---

const testing = std.testing;

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

test "Regex layout: HeapHeader at offset 0, extern + align >= 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(Regex, "header"));
    try testing.expect(@alignOf(Regex) >= 8);
}

test "alloc returns a .regex-tagged Value carrying the source" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try alloc(&fix.rt, "\\d+", .{});
    try testing.expect(v.tag() == .regex);
    const r = asRegex(v);
    try testing.expectEqualStrings("\\d+", r.source());
    // Program inst layout: class[0-9], split{0,after}, jmp 0, match
    // for `\d+` -> char|class then '+'.
    // Spot-check that compile actually populated the IR.
    try testing.expect(r.program.insts.len > 0);
}

test "GC sweep finaliser releases Program + source (no leak)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    _ = try alloc(&fix.rt, "a|b", .{});
    // Sweep with empty root set — the Regex is unreachable, so the
    // finaliser fires. testing.allocator's leak detector verifies
    // both the IR slice and the source copy were freed.
    mark_sweep.sweep(&fix.rt.gc);
}
