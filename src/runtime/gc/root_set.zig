// SPDX-License-Identifier: EPL-2.0
//! Root-set enumeration for cw v1 mark-sweep GC per ADR-0028 §5.
//!
//! **Phase 5 row 5.3.b.3** wires the 4 entry-point walkers that the
//! `phase5-5.3.b.3-survey.md` audit found to actually exist in cw v1:
//!
//!   1. **ns_vars**     — Namespace `Var.root` + `Var.meta` across
//!                        every registered Env (`WalkContext.envs`).
//!   2. **current_frame** — dynamic-binding stack threadlocal in
//!                        `env.zig`. Walks the parent chain + each
//!                        frame's BindingMap.
//!   7. **macro_root_slot** — analyser-scoped root slot (threadlocal,
//!                        declared in this file so Layer 0 owns it
//!                        and Layer 1 reads/writes via downward
//!                        import). Refuses cw v0's `suppressCollection`
//!                        escape hatch per F-002 + F-006.
//!  10. **permanent_roots** — embedder-pinned Values on the GcHeap.
//!
//! Sources 3 / 4 / 8 are per-tag trace entries (registered into
//! `tag_ops.tag_trace_table` from the owning module — `tree_walk.zig`
//! / `lazy_seq.zig` / `type_descriptor.zig`) and reach via the
//! transitive trace, not via root enumeration. Sources 5 / 9 yield
//! nothing in cw v1 by construction (ProtocolFn caches don't exist;
//! CallSite holds namespace-owned pointers, not GC edges). Source 6
//! (`refer` borrows) is closed-at-construction at `env.zig:229`'s
//! `referAll` (the dupe lifts the borrowed name onto `infra_alloc`),
//! so no GC walker is needed. The RootIterator's enum slot for each
//! deferred source stays declared per the ADR for symmetry; the
//! walker body is an early return with a one-line explanation.
//!
//! The walker takes its inputs **explicitly** via `WalkContext`
//! rather than discovering Envs through a `Runtime.envs` registry.
//! Per the survey, that registry would require changing `Env.init`'s
//! return shape (currently by-value; the registry needs a stable
//! `*Env` address). Deferring the registry to 5.3.d keeps 5.3.b.3
//! scoped to the GC-side wiring; 5.3.d folds the Env.init signature
//! change into the alloc-site migration commit when that surface is
//! already being touched.

const std = @import("std");
const testing = std.testing;

const value_mod = @import("../value/value.zig");
const heap_header = @import("../value/heap_header.zig");
const env_mod = @import("../env.zig");
const runtime_mod = @import("../runtime.zig");
const gc_heap_mod = @import("gc_heap.zig");

const Value = value_mod.Value;
const HeapHeader = heap_header.HeapHeader;
const Env = env_mod.Env;
const Runtime = runtime_mod.Runtime;
const GcHeap = gc_heap_mod.GcHeap;

/// Identifier for one of the 10 root sources enumerated by the mark
/// phase. Per ADR-0028 §5 + the 5.3.b.3 survey's amendment candidates,
/// only sources 1 / 2 / 7 / 10 yield roots at Phase 5; the others
/// are either tag-trace entries (3 / 4 / 8) or no-op-by-construction
/// (5 / 6 / 9). Survey note ID: phase5-5.3.b.3-survey.md §"Summary
/// punch list".
pub const RootSource = enum {
    ns_vars,
    current_frame,
    fn_closures, // tag-trace entry — see tag_ops.tag_trace_table[.fn_val]
    lazy_seqs, // tag-trace entry — see 5.7 registration
    protocol_caches, // no live structs in cw v1; Phase 7 entry territory
    refer_borrows, // closed at construction in env.zig:229 referAll
    macro_root_slot, // threadlocal owned by this module
    typed_instances, // tag-trace entry — see 5.11 registration
    callsite_methods, // cache holds namespace-owned pointers; no GC edge
    permanent_roots,
};

/// Analyser-scoped root slot for macro-expansion intermediate Values.
/// Per ADR-0028 §5 row 7 + the `phase5-5.1-survey.md` DIVERGENCE: cw
/// v0 used `suppressCollection()` to bracket macro expansion; cw v1
/// refuses the escape hatch and instead pins the in-flight Value
/// here. Set on entry to `expandIfMacro`, cleared on exit. Read by
/// the root walker.
///
/// Threadlocal because Phase 15 STM activation may run macro
/// expansion concurrently per the `current_frame` precedent in
/// env.zig:142. Phase 5 is single-threaded so a single thread reads
/// + writes the slot; the threadlocal qualifier costs nothing today
/// and avoids a Phase-15 surface change.
pub threadlocal var macro_root_slot: ?Value = null;

/// Explicit context passed to `enumerate()`. Per the survey, the
/// walker discovers Envs through a caller-supplied slice rather than
/// a `Runtime.envs` auto-registry — defers the registry to 5.3.d
/// alongside the `Env.init` signature change. `gc` carries the
/// `permanent_roots` source + the eventual mark queue (5.3.b.5
/// wiring).
pub const WalkContext = struct {
    envs: []const *Env,
    gc: *GcHeap,
};

/// Root-set iterator. Walks the 4 live sources in source order; the
/// other 6 enum slots advance immediately to the next source per
/// their early-return contract (see RootSource enum docstring for
/// the per-source disposition).
pub const RootIterator = struct {
    ctx: WalkContext,
    source: RootSource = .ns_vars,
    /// Per-source cursor state. Union of state-machine variants;
    /// only the variant matching `source` is active.
    cursor: Cursor = .{ .ns_vars = .{} },

    pub const Cursor = union(enum) {
        ns_vars: NsVarsCursor,
        current_frame: CurrentFrameCursor,
        empty: void, // every deferred source uses this
        macro_root_slot: MacroRootCursor,
        permanent_roots: PermanentRootsCursor,
    };

    pub const NsVarsCursor = struct {
        env_idx: usize = 0,
        ns_it: ?env_mod.NamespaceMap.ValueIterator = null,
        var_it: ?env_mod.VarMap.ValueIterator = null,
        /// Most-recently yielded Var so the iterator can yield its
        /// `meta` slot on the next `next()` call before advancing.
        pending_meta: ?*const env_mod.Var = null,
    };

    pub const CurrentFrameCursor = struct {
        frame: ?*env_mod.BindingFrame = null,
        bindings_it: ?env_mod.BindingMap.ValueIterator = null,
        initialised: bool = false,
    };

    pub const MacroRootCursor = struct {
        consumed: bool = false,
    };

    pub const PermanentRootsCursor = struct {
        idx: usize = 0,
    };

    pub fn next(self: *RootIterator) ?*HeapHeader {
        while (true) {
            switch (self.source) {
                .ns_vars => if (self.nextNsVar()) |hdr| return hdr else self.advance(),
                .current_frame => if (self.nextCurrentFrame()) |hdr| return hdr else self.advance(),
                .fn_closures, .lazy_seqs, .protocol_caches, .refer_borrows, .typed_instances, .callsite_methods => self.advance(),
                .macro_root_slot => if (self.nextMacroRoot()) |hdr| return hdr else self.advance(),
                .permanent_roots => if (self.nextPermanentRoot()) |hdr| return hdr else return null,
            }
        }
    }

    fn advance(self: *RootIterator) void {
        const next_source: RootSource = switch (self.source) {
            .ns_vars => .current_frame,
            .current_frame => .fn_closures,
            .fn_closures => .lazy_seqs,
            .lazy_seqs => .protocol_caches,
            .protocol_caches => .refer_borrows,
            .refer_borrows => .macro_root_slot,
            .macro_root_slot => .typed_instances,
            .typed_instances => .callsite_methods,
            .callsite_methods => .permanent_roots,
            .permanent_roots => unreachable, // next() returns null instead
        };
        self.source = next_source;
        self.cursor = switch (next_source) {
            .ns_vars => .{ .ns_vars = .{} },
            .current_frame => .{ .current_frame = .{} },
            .macro_root_slot => .{ .macro_root_slot = .{} },
            .permanent_roots => .{ .permanent_roots = .{} },
            else => .{ .empty = {} },
        };
    }

    fn nextNsVar(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.ns_vars;
        while (true) {
            // Flush pending Var.meta yield from the previous iteration.
            if (c.pending_meta) |v_ptr| {
                c.pending_meta = null;
                if (v_ptr.meta) |m| if (m.heapHeader()) |hdr| return hdr;
            }
            // Advance Var iterator within current Namespace.
            if (c.var_it) |*var_it| {
                if (var_it.next()) |v_pp| {
                    const v = v_pp.*;
                    c.pending_meta = v;
                    if (v.root.heapHeader()) |hdr| return hdr;
                    // .root was an immediate; loop to yield .meta or next Var.
                    continue;
                }
                c.var_it = null;
            }
            // Advance Namespace iterator within current Env.
            if (c.ns_it) |*ns_it| {
                if (ns_it.next()) |ns_pp| {
                    c.var_it = ns_pp.*.mappings.valueIterator();
                    continue;
                }
                c.ns_it = null;
                c.env_idx += 1;
            }
            // Advance to next Env.
            if (c.env_idx >= self.ctx.envs.len) return null;
            const env_ptr = self.ctx.envs[c.env_idx];
            c.ns_it = env_ptr.namespaces.valueIterator();
        }
    }

    fn nextCurrentFrame(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.current_frame;
        if (!c.initialised) {
            c.frame = env_mod.current_frame;
            c.initialised = true;
        }
        while (true) {
            if (c.bindings_it) |*it| {
                while (it.next()) |val_ptr| {
                    if (val_ptr.heapHeader()) |hdr| return hdr;
                }
                c.bindings_it = null;
            }
            const f = c.frame orelse return null;
            c.bindings_it = f.bindings.valueIterator();
            c.frame = f.parent;
        }
    }

    fn nextMacroRoot(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.macro_root_slot;
        if (c.consumed) return null;
        c.consumed = true;
        if (macro_root_slot) |v| return v.heapHeader();
        return null;
    }

    fn nextPermanentRoot(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.permanent_roots;
        while (c.idx < self.ctx.gc.permanent_roots.items.len) {
            const v = self.ctx.gc.permanent_roots.items[c.idx];
            c.idx += 1;
            if (v.heapHeader()) |hdr| return hdr;
        }
        return null;
    }
};

/// Build a root-set iterator. Caller provides the explicit envs slice
/// + gc pointer per the survey's "no auto-registry at 5.3.b.3"
/// design decision.
pub fn enumerate(ctx: WalkContext) RootIterator {
    return .{ .ctx = ctx };
}

// --- tests ---

const Cell = extern struct { header: HeapHeader = HeapHeader.init(.string), payload: u64 = 0 };

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

test "RootSource enum lists 10 sources per ADR-0028 §5" {
    try testing.expectEqual(@as(comptime_int, 10), @typeInfo(RootSource).@"enum".fields.len);
}

test "enumerate on empty context yields no roots" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    try testing.expect(it.next() == null);
}

test "permanent_roots walker yields each pinned heap Value (skipping immediates)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_a = try gc.alloc(Cell);
    cell_a.* = .{ .header = HeapHeader.init(.string) };
    const cell_b = try gc.alloc(Cell);
    cell_b.* = .{ .header = HeapHeader.init(.vector) };

    const v_a = Value.encodeHeapPtr(.string, cell_a);
    const v_b = Value.encodeHeapPtr(.vector, cell_b);
    try gc.pin(v_a);
    try gc.pin(Value.initInteger(42)); // immediate — walker skips
    try gc.pin(v_b);

    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    var found_a: bool = false;
    var found_b: bool = false;
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_a))) found_a = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_b))) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "macro_root_slot walker yields the slot when set; nothing when null" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell = try gc.alloc(Cell);
    cell.* = .{ .header = HeapHeader.init(.list) };

    // Initially null → walker yields nothing.
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        try testing.expect(it.next() == null);
    }
    // Set → walker yields the cell's header.
    macro_root_slot = Value.encodeHeapPtr(.list, cell);
    defer macro_root_slot = null;
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        const hdr = it.next() orelse return error.MacroRootMissed;
        try testing.expectEqual(@as(*HeapHeader, @ptrCast(cell)), hdr);
        try testing.expect(it.next() == null);
    }
}

test "ns_vars walker yields Var.root across two Envs sharing a Runtime" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var env1 = try Env.init(&fix.rt);
    defer env1.deinit();
    var env2 = try Env.init(&fix.rt);
    defer env2.deinit();

    // Each Env has bootstrap "rt" + "user" namespaces. Define one Var
    // with a heap-Value root in each.
    const cell1 = try gc.alloc(Cell);
    cell1.* = .{ .header = HeapHeader.init(.string) };
    const cell2 = try gc.alloc(Cell);
    cell2.* = .{ .header = HeapHeader.init(.vector) };

    const ns1 = env1.findNs("user").?;
    _ = try env1.intern(ns1, "x", Value.encodeHeapPtr(.string, cell1));
    const ns2 = env2.findNs("user").?;
    _ = try env2.intern(ns2, "y", Value.encodeHeapPtr(.vector, cell2));

    var found1: bool = false;
    var found2: bool = false;
    var it = enumerate(.{ .envs = &.{ &env1, &env2 }, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell1))) found1 = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell2))) found2 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
}

test "current_frame walker yields heap Values across nested binding frames" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();
    const ns = env.findNs("user").?;
    const var_x = try env.intern(ns, "x", Value.nil_val);
    const var_y = try env.intern(ns, "y", Value.nil_val);

    const cell_x = try gc.alloc(Cell);
    cell_x.* = .{ .header = HeapHeader.init(.string) };
    const cell_y = try gc.alloc(Cell);
    cell_y.* = .{ .header = HeapHeader.init(.vector) };

    var bindings_outer: env_mod.BindingMap = .empty;
    defer bindings_outer.deinit(env.alloc);
    try bindings_outer.put(env.alloc, var_x, Value.encodeHeapPtr(.string, cell_x));
    var frame_outer: env_mod.BindingFrame = .{ .bindings = bindings_outer };

    var bindings_inner: env_mod.BindingMap = .empty;
    defer bindings_inner.deinit(env.alloc);
    try bindings_inner.put(env.alloc, var_y, Value.encodeHeapPtr(.vector, cell_y));
    var frame_inner: env_mod.BindingFrame = .{ .bindings = bindings_inner };

    // pushFrame overwrites frame.parent with current_frame, so the
    // chain is built by pushing in order (outer first, then inner).
    env_mod.pushFrame(&frame_outer);
    defer env_mod.popFrame();
    env_mod.pushFrame(&frame_inner);
    defer env_mod.popFrame();

    var found_x: bool = false;
    var found_y: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_x))) found_x = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_y))) found_y = true;
    }
    try testing.expect(found_x);
    try testing.expect(found_y);
}
