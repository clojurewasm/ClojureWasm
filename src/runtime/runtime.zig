//! Runtime — the process-wide handle every layer threads through.
//!
//! Three-tier architecture (see ROADMAP §4.3):
//!
//!   - **Runtime** (this file): one per process. `io`, `gpa`,
//!     interners, vtable. Lifetime = whole process.
//!   - **Env** (`env.zig`): one per CLI invocation / nREPL session;
//!     holds the namespace graph. Multiple Envs can share a Runtime
//!     (this fixes v1's nREPL session-sharing race condition).
//!   - **threadlocal** (`error.zig`, `dispatch.zig`, `env.zig`): only
//!     the per-thread state Clojure's dynamic-var semantics require.
//!
//! ### How `io` is threaded
//!
//! Runtime stores `std.Io` **by value** (it's a userdata + vtable
//! pair, ~16 bytes). The backing implementation (`std.Io.Threaded`,
//! `Io.Evented`, ...) is **not owned** by Runtime. Production code
//! threads `init.io` from `std.process.Init`; tests construct it via
//! `std.Io.Threaded.init(alloc, .{})`. We don't store the backing
//! type because `Threaded` is move-unsafe — `io()` returns a
//! `*Threaded`, and embedding `Threaded` in another struct would
//! leave the userdata pointer dangling after a copy.

const std = @import("std");
const KeywordInterner = @import("keyword.zig").KeywordInterner;
const dispatch = @import("dispatch.zig");
const VTable = dispatch.VTable;

/// Process-wide execution context.
///
/// **Phase 2.1** carries `io` / `gpa` / `keywords` / `vtable` /
/// `heap_objects`. Phase 5+ adds `gc: ?*MarkSweepGc`; Phase 3+ adds a
/// `symbols: SymbolInterner`. Adding a field is OK; renaming or
/// removing one is an ADR-level change.
pub const Runtime = struct {
    /// IO hub. Every lock / unlock / file / net / sleep flows through
    /// this — Zig 0.16's mandatory IO DI.
    io: std.Io,

    /// Process-lifetime general allocator backing Var / Namespace /
    /// interner tables. Phase 5+ adds a separate GC allocator.
    gpa: std.mem.Allocator,

    /// Keyword interner. Tied to this Runtime, not a global, so
    /// independent Runtimes (parallel tests / future multi-tenant
    /// nREPL) coexist without sharing a table.
    keywords: KeywordInterner,

    /// Layer-0 → Layer-1+ dispatch table. Populated by the TreeWalk
    /// backend in Phase 2.6. While `null`, callers that would invoke
    /// `callFn` simply don't exist yet — those sites are gated behind
    /// primitives that get registered alongside the vtable. Macro
    /// expansion is **not** on this table; see ADR 0001.
    vtable: ?VTable = null,

    /// Monotonic counter for `gensym` / auto-gensym (`foo#`). Lives on
    /// the Runtime so multiple macros within one analyse pass share a
    /// single sequence; per-Runtime so parallel tests don't collide.
    /// Phase 3.7 wires the first user (bootstrap macro `and` / `or`).
    gensym_counter: u64 = 0,

    /// Phase-2 heap-object pool. Until the Phase-5 mark-sweep GC, each
    /// Layer-1+ heap allocation registers a `(ptr, free_fn)` pair here
    /// so `Runtime.deinit` can release them. The list keeps Layer 0
    /// from needing to know concrete Layer-1 types like `tree_walk
    /// .Function`.
    heap_objects: std.ArrayList(HeapEntry) = .empty,

    pub const HeapEntry = struct {
        ptr: *anyopaque,
        free: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
    };

    /// Track a heap-allocated object so `Runtime.deinit` will free it.
    pub fn trackHeap(self: *Runtime, entry: HeapEntry) !void {
        try self.heap_objects.append(self.gpa, entry);
    }

    /// Allocate a fresh symbol name `<prefix>__<n>__auto__` in `arena`.
    /// Mirrors Clojure's `gensym` shape (the trailing `__auto__` is
    /// what syntax-quote's `foo#` uses; we keep it uniform). The
    /// counter is per-Runtime so parallel tests stay independent.
    pub fn gensym(self: *Runtime, arena: std.mem.Allocator, prefix: []const u8) ![]const u8 {
        const n = self.gensym_counter;
        self.gensym_counter += 1;
        return std.fmt.allocPrint(arena, "{s}__{d}__auto__", .{ prefix, n });
    }

    /// Production initializer. `io` typically comes from
    /// `std.process.Init.io`; in tests use `std.Io.Threaded`.
    pub fn init(io: std.Io, gpa: std.mem.Allocator) Runtime {
        return .{
            .io = io,
            .gpa = gpa,
            .keywords = KeywordInterner.init(gpa),
        };
    }

    pub fn deinit(self: *Runtime) void {
        for (self.heap_objects.items) |entry| {
            entry.free(self.gpa, entry.ptr);
        }
        self.heap_objects.deinit(self.gpa);
        self.keywords.deinit();
    }
};

// --- tests ---

const testing = std.testing;

test "Runtime.init/deinit roundtrips with std.Io.Threaded" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.gpa.ptr == testing.allocator.ptr);
    // io.userdata points at our Threaded — sanity check on wiring.
    try testing.expect(rt.io.userdata == @as(*anyopaque, @ptrCast(&th)));
}

test "Runtime owns an empty KeywordInterner at init" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expectEqual(@as(usize, 0), rt.keywords.table.count());
}

test "Runtime.trackHeap frees registered objects on deinit" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);

    const Box = struct {
        var freed: bool = false;
        fn free(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const p: *u32 = @ptrCast(@alignCast(ptr));
            gpa.destroy(p);
            freed = true;
        }
    };

    const p = try testing.allocator.create(u32);
    p.* = 42;
    try rt.trackHeap(.{ .ptr = p, .free = Box.free });

    Box.freed = false;
    rt.deinit();
    try testing.expect(Box.freed);
}

test "Runtime.vtable defaults to null and accepts assignment" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.vtable == null);
}
