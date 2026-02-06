// GcStrategy — vtable-based GC abstraction (SS5).
//
// Provides a trait interface for garbage collection strategies.
// Initial implementation: ArenaGc (arena allocator, no-op collect).

const std = @import("std");
const Alignment = std.mem.Alignment;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const chunk_mod = @import("bytecode/chunk.zig");
const env_mod = @import("env.zig");
const ns_mod = @import("namespace.zig");
const var_mod = @import("var.zig");
const collections = @import("collections.zig");
const HAMTNode = collections.HAMTNode;

/// GC root set — references to all live value sources.
///
/// Callers (VM, TreeWalk) populate this before GC collection.
/// traceRoots() walks these sources and marks all reachable Values.
pub const RootSet = struct {
    /// Active evaluation stack slices (VM stack[0..sp], TW locals, etc.)
    value_slices: []const []const Value = &.{},
    /// Individual root Values (e.g. exception, current return value)
    values: []const Value = &.{},
    /// Environment (namespaces → vars → root values). May be null.
    env: ?*const env_mod.Env = null,
};

/// GC allocation statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

/// Vtable-based GC strategy trait.
///
/// Follows the Zig fat-pointer idiom (same pattern as std.mem.Allocator):
/// a type-erased pointer + vtable of function pointers.
pub const GcStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8,
        collect: *const fn (ptr: *anyopaque, roots: RootSet) void,
        shouldCollect: *const fn (ptr: *anyopaque) bool,
        stats: *const fn (ptr: *anyopaque) Stats,
    };

    pub fn alloc(self: GcStrategy, size: usize, alignment: Alignment) ?[*]u8 {
        return self.vtable.alloc(self.ptr, size, alignment);
    }

    pub fn collect(self: GcStrategy, roots: RootSet) void {
        self.vtable.collect(self.ptr, roots);
    }

    pub fn shouldCollect(self: GcStrategy) bool {
        return self.vtable.shouldCollect(self.ptr);
    }

    pub fn stats(self: GcStrategy) Stats {
        return self.vtable.stats(self.ptr);
    }
};

/// Arena-based GC stub — wraps ArenaAllocator with no-op collect.
///
/// This is the initial GC strategy: all allocations go through an arena,
/// and collection is deferred (no-op). The arena frees everything on deinit.
pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,

    const vtable: GcStrategy.VTable = .{
        .alloc = &arenaAlloc,
        .collect = &arenaCollect,
        .shouldCollect = &arenaShouldCollect,
        .stats = &arenaStats,
    };

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *ArenaGc) void {
        self.arena.deinit();
    }

    /// Returns GcStrategy fat pointer for this instance.
    pub fn strategy(self: *ArenaGc) GcStrategy {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Returns a std.mem.Allocator backed by this ArenaGc.
    /// Useful for Zig stdlib compatibility (ArrayList, HashMap, etc.).
    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn arenaAlloc(ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ptr));
        const result = self.arena.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return null;
        self.bytes_allocated += size;
        self.alloc_count += 1;
        return result;
    }

    fn arenaCollect(_: *anyopaque, _: RootSet) void {
        // No-op: arena frees everything on deinit.
    }

    fn arenaShouldCollect(_: *anyopaque) bool {
        return false;
    }

    fn arenaStats(ptr: *anyopaque) Stats {
        const self: *ArenaGc = @ptrCast(@alignCast(ptr));
        return .{
            .bytes_allocated = self.bytes_allocated,
            .alloc_count = self.alloc_count,
        };
    }
};

/// Mark-sweep GC — tracks allocations, marks live objects, sweeps dead ones.
///
/// Wraps a backing allocator: every allocation is tracked in a HashMap.
/// Mark phase: callers mark live pointers via markPtr().
/// Sweep phase: all unmarked allocations are freed through the backing allocator.
pub const MarkSweepGc = struct {
    backing: std.mem.Allocator,
    allocations: std.AutoArrayHashMapUnmanaged(usize, AllocInfo) = .empty,
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
    collect_count: u64 = 0,
    threshold: usize = 1024 * 1024, // 1MB default
    free_pools: [MAX_FREE_POOLS]FreePool = [_]FreePool{.{}} ** MAX_FREE_POOLS,
    free_pool_count: u8 = 0,

    /// Free-list node — overlaid on freed allocation memory.
    const FreeNode = struct {
        next: ?*FreeNode,
    };

    /// Per-(size, alignment) free pool for recycling dead allocations.
    const FreePool = struct {
        size: usize = 0,
        alignment: Alignment = .@"1",
        head: ?*FreeNode = null,
        count: u32 = 0,
    };

    const MAX_FREE_POOLS = 16;
    const MAX_FREE_PER_POOL = 4096;

    pub const AllocInfo = struct {
        len: usize,
        alignment: Alignment,
        marked: bool,
    };

    const allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = &msAlloc,
        .resize = &msResize,
        .remap = &msRemap,
        .free = &msFree,
    };

    const gc_vtable: GcStrategy.VTable = .{
        .alloc = &gcAlloc,
        .collect = &gcCollect,
        .shouldCollect = &gcShouldCollect,
        .stats = &gcStats,
    };

    pub fn init(backing: std.mem.Allocator) MarkSweepGc {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *MarkSweepGc) void {
        // Free all tracked allocations through backing
        const keys = self.allocations.keys();
        const vals = self.allocations.values();
        for (keys, vals) |addr, info| {
            const p: [*]u8 = @ptrFromInt(addr);
            self.backing.rawFree(p[0..info.len], info.alignment, 0);
        }
        self.allocations.deinit(self.backing);
        // Free all cached free-pool entries through backing
        for (self.free_pools[0..self.free_pool_count]) |pool| {
            var node = pool.head;
            while (node) |n| {
                const next = n.next;
                const p: [*]u8 = @ptrCast(n);
                self.backing.rawFree(p[0..pool.size], pool.alignment, 0);
                node = next;
            }
        }
    }

    /// Returns a std.mem.Allocator that tracks all allocations through this GC.
    pub fn allocator(self: *MarkSweepGc) std.mem.Allocator {
        return .{ .ptr = @ptrCast(self), .vtable = &allocator_vtable };
    }

    /// Returns GcStrategy fat pointer for this instance.
    pub fn strategy(self: *MarkSweepGc) GcStrategy {
        return .{ .ptr = @ptrCast(self), .vtable = &gc_vtable };
    }

    /// Mark a pointer as live. The pointer must have been allocated through this GC.
    /// No-op if the pointer is not tracked (e.g. interned/static data).
    pub fn markPtr(self: *MarkSweepGc, ptr: anytype) void {
        const addr = @intFromPtr(ptr);
        if (self.allocations.getPtr(addr)) |info| {
            info.marked = true;
        }
    }

    /// Mark a pointer and return true if it was newly marked.
    /// Returns false if already marked (cycle detection) or not tracked.
    pub fn markAndCheck(self: *MarkSweepGc, ptr: anytype) bool {
        const addr = @intFromPtr(ptr);
        if (self.allocations.getPtr(addr)) |info| {
            if (info.marked) return false;
            info.marked = true;
            return true;
        }
        return false;
    }

    /// Mark a slice's backing memory (the raw allocation behind the pointer).
    pub fn markSlice(self: *MarkSweepGc, slice: anytype) void {
        if (slice.len > 0) {
            self.markPtr(slice.ptr);
        }
    }

    /// Sweep all unmarked allocations, recycling to free pools or freeing.
    /// Marked allocations have their mark bit reset for the next cycle.
    pub fn sweep(self: *MarkSweepGc) void {
        var freed_bytes: usize = 0;
        var freed_count: u64 = 0;
        var i: usize = 0;
        while (i < self.allocations.count()) {
            const vals = self.allocations.values();
            if (!vals[i].marked) {
                const keys = self.allocations.keys();
                const addr = keys[i];
                const info = vals[i];
                freed_bytes += info.len;
                freed_count += 1;
                // Remove from HashMap first
                self.allocations.swapRemoveAt(i);
                // Try to recycle into free pool (avoids rawFree + future rawAlloc)
                if (!self.addToFreePool(addr, info.len, info.alignment)) {
                    // Can't recycle — actually free through backing
                    const p: [*]u8 = @ptrFromInt(addr);
                    self.backing.rawFree(p[0..info.len], info.alignment, 0);
                }
                // Don't increment — swapRemove moved last element to i
            } else {
                vals[i].marked = false;
                i += 1;
            }
        }
        self.bytes_allocated -|= freed_bytes;
        self.alloc_count -|= freed_count;
        self.collect_count += 1;
    }

    /// Return the number of currently tracked (live) allocations.
    pub fn liveCount(self: *const MarkSweepGc) usize {
        return self.allocations.count();
    }

    // --- Free pool helpers ---

    /// Find a free pool matching (size, alignment), or create one if space available.
    fn findOrCreatePool(self: *MarkSweepGc, size: usize, alignment: Alignment) ?*FreePool {
        for (self.free_pools[0..self.free_pool_count]) |*pool| {
            if (pool.size == size and pool.alignment == alignment) return pool;
        }
        if (self.free_pool_count < MAX_FREE_POOLS) {
            const pool = &self.free_pools[self.free_pool_count];
            pool.* = .{ .size = size, .alignment = alignment };
            self.free_pool_count += 1;
            return pool;
        }
        return null;
    }

    /// Try to add a dead allocation to a free pool for recycling.
    fn addToFreePool(self: *MarkSweepGc, addr: usize, size: usize, alignment: Alignment) bool {
        if (size < @sizeOf(FreeNode)) return false;
        const pool = self.findOrCreatePool(size, alignment) orelse return false;
        if (pool.count >= MAX_FREE_PER_POOL) return false;
        const node: *FreeNode = @ptrFromInt(addr);
        node.next = pool.head;
        pool.head = node;
        pool.count += 1;
        return true;
    }

    // --- std.mem.Allocator VTable implementations ---

    fn msAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        // Try free pool first — exact (size, alignment) match, O(1) pop
        for (self.free_pools[0..self.free_pool_count]) |*pool| {
            if (pool.size == len and pool.alignment == alignment) {
                if (pool.head) |node| {
                    pool.head = node.next;
                    pool.count -= 1;
                    const result: [*]u8 = @ptrCast(node);
                    // Re-add to HashMap (was removed during sweep)
                    self.allocations.put(self.backing, @intFromPtr(result), .{
                        .len = len,
                        .alignment = alignment,
                        .marked = false,
                    }) catch return null;
                    self.bytes_allocated += len;
                    self.alloc_count += 1;
                    return result;
                }
                break; // Pool exists but empty — fall through to backing
            }
        }
        // Slow path: allocate from backing
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations.put(self.backing, @intFromPtr(result), .{
            .len = len,
            .alignment = alignment,
            .marked = false,
        }) catch {
            // Failed to track — free the allocation and return null
            self.backing.rawFree(result[0..len], alignment, 0);
            return null;
        };
        self.bytes_allocated += len;
        self.alloc_count += 1;
        return result;
    }

    fn msResize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        if (self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            const addr = @intFromPtr(memory.ptr);
            if (self.allocations.getPtr(addr)) |info| {
                self.bytes_allocated = self.bytes_allocated - info.len + new_len;
                info.len = new_len;
            }
            return true;
        }
        return false;
    }

    fn msRemap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        const old_addr = @intFromPtr(memory.ptr);
        const new_addr = @intFromPtr(result);
        if (old_addr == new_addr) {
            if (self.allocations.getPtr(old_addr)) |info| {
                self.bytes_allocated = self.bytes_allocated - info.len + new_len;
                info.len = new_len;
            }
        } else {
            // Address changed — remove old entry, add new
            if (self.allocations.get(old_addr)) |old_info| {
                self.bytes_allocated -|= old_info.len;
                self.alloc_count -|= 1;
                _ = self.allocations.swapRemove(old_addr);
            }
            self.allocations.put(self.backing, new_addr, .{
                .len = new_len,
                .alignment = alignment,
                .marked = false,
            }) catch return null;
            self.bytes_allocated += new_len;
            self.alloc_count += 1;
        }
        return result;
    }

    fn msFree(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        const addr = @intFromPtr(memory.ptr);
        if (self.allocations.get(addr)) |info| {
            self.bytes_allocated -|= info.len;
            self.alloc_count -|= 1;
            _ = self.allocations.swapRemove(addr);
            // Try to recycle into free pool (avoids rawFree)
            if (self.addToFreePool(addr, info.len, info.alignment)) return;
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    // --- GcStrategy VTable implementations ---

    fn gcAlloc(ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8 {
        return msAlloc(ptr, size, alignment, 0);
    }

    fn gcCollect(ptr: *anyopaque, roots: RootSet) void {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        traceRoots(self, roots);
        self.sweep();
    }

    fn gcShouldCollect(ptr: *anyopaque) bool {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        return self.bytes_allocated >= self.threshold;
    }

    fn gcStats(ptr: *anyopaque) Stats {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        return .{
            .bytes_allocated = self.bytes_allocated,
            .alloc_count = self.alloc_count,
        };
    }

    /// Run a GC cycle if the allocation threshold has been reached.
    /// Traces roots, sweeps dead allocations, and grows threshold if needed.
    pub fn collectIfNeeded(self: *MarkSweepGc, roots: RootSet) void {
        if (self.bytes_allocated < self.threshold) return;
        traceRoots(self, roots);
        self.sweep();
        // Grow threshold if live set is still above it (avoid re-triggering every cycle)
        if (self.bytes_allocated >= self.threshold) {
            self.threshold = self.bytes_allocated * 2;
        }
    }
};

/// Recursively trace a HAMT node and all its descendants, marking
/// key-value pairs and child node pointers as live.
fn traceHAMTNode(gc: *MarkSweepGc, node: *const HAMTNode) void {
    if (!gc.markAndCheck(node)) return; // already traced
    gc.markSlice(node.kvs);
    for (node.kvs) |kv| {
        traceValue(gc, kv.key);
        traceValue(gc, kv.val);
    }
    gc.markSlice(node.nodes);
    for (node.nodes) |child| {
        traceHAMTNode(gc, child);
    }
}

/// Trace a Fn's proto pointer and its internal allocations.
/// For bytecode Fns, proto is a *FnProto — trace code, constants, lines, columns.
/// For treewalk Fns, proto is a *Closure — its captured_locals are traced via
/// closure_bindings on the Fn struct (set during makeClosure).
fn traceFnProto(gc: *MarkSweepGc, proto: *const anyopaque, kind: value_mod.FnKind) void {
    switch (kind) {
        .bytecode => {
            const fp: *const chunk_mod.FnProto = @ptrCast(@alignCast(proto));
            if (gc.markAndCheck(fp)) {
                gc.markSlice(fp.code);
                gc.markSlice(fp.constants);
                // Trace Values in the constant pool
                for (fp.constants) |c| traceValue(gc, c);
                if (fp.lines.len > 0) gc.markSlice(fp.lines);
                if (fp.columns.len > 0) gc.markSlice(fp.columns);
                if (fp.capture_slots.len > 0) gc.markSlice(fp.capture_slots);
                if (fp.name) |n| gc.markSlice(n);
            }
        },
        .treewalk => {
            // Closure struct — mark it. Captured locals are traced via Fn.closure_bindings.
            gc.markPtr(proto);
        },
    }
}

/// Trace all heap allocations reachable from a Value, marking them as live.
/// Uses mark bits for cycle detection (already-marked pointers are skipped).
/// Exhaustive switch ensures compile error if a new Value variant is added.
pub fn traceValue(gc: *MarkSweepGc, val: Value) void {
    switch (val) {
        // Primitives — no heap allocations
        .nil, .boolean, .integer, .float, .char => {},

        // String slice — mark backing array
        .string => |s| gc.markSlice(s),

        // Symbol — ns/name slices + optional meta
        .symbol => |sym| {
            if (sym.ns) |ns| gc.markSlice(ns);
            gc.markSlice(sym.name);
            if (sym.meta) |m| {
                if (gc.markAndCheck(m)) traceValue(gc, m.*);
            }
        },

        // Keyword — ns/name slices
        .keyword => |kw| {
            if (kw.ns) |ns| gc.markSlice(ns);
            gc.markSlice(kw.name);
        },

        // Persistent list
        .list => |l| {
            if (gc.markAndCheck(l)) {
                gc.markSlice(l.items);
                for (l.items) |item| traceValue(gc, item);
                if (l.meta) |m| {
                    if (gc.markAndCheck(m)) traceValue(gc, m.*);
                }
                if (l.child_lines) |cl| gc.markSlice(cl);
                if (l.child_columns) |cc| gc.markSlice(cc);
            }
        },

        // Persistent vector
        .vector => |v| {
            if (gc.markAndCheck(v)) {
                gc.markSlice(v.items);
                for (v.items) |item| traceValue(gc, item);
                if (v.meta) |m| {
                    if (gc.markAndCheck(m)) traceValue(gc, m.*);
                }
                if (v.child_lines) |cl| gc.markSlice(cl);
                if (v.child_columns) |cc| gc.markSlice(cc);
            }
        },

        // Persistent array map
        .map => |m| {
            if (gc.markAndCheck(m)) {
                gc.markSlice(m.entries);
                for (m.entries) |entry| traceValue(gc, entry);
                if (m.meta) |meta| {
                    if (gc.markAndCheck(meta)) traceValue(gc, meta.*);
                }
                if (m.comparator) |c| traceValue(gc, c);
            }
        },

        // Persistent hash map (HAMT)
        .hash_map => |hm| {
            if (gc.markAndCheck(hm)) {
                // Trace null-key entry if present
                if (hm.has_null) traceValue(gc, hm.null_val);
                // Traverse HAMT tree
                if (hm.root) |root| traceHAMTNode(gc, root);
                if (hm.meta) |meta| {
                    if (gc.markAndCheck(meta)) traceValue(gc, meta.*);
                }
            }
        },

        // Persistent hash set
        .set => |s| {
            if (gc.markAndCheck(s)) {
                gc.markSlice(s.items);
                for (s.items) |item| traceValue(gc, item);
                if (s.meta) |meta| {
                    if (gc.markAndCheck(meta)) traceValue(gc, meta.*);
                }
                if (s.comparator) |c| traceValue(gc, c);
            }
        },

        // Function — proto internals, closure bindings, extra arities, meta
        .fn_val => |f| {
            if (gc.markAndCheck(f)) {
                // Trace proto internals (bytecode arrays, constant pools, etc.)
                traceFnProto(gc, f.proto, f.kind);
                if (f.closure_bindings) |bindings| {
                    gc.markSlice(bindings);
                    for (bindings) |b| traceValue(gc, b);
                }
                if (f.extra_arities) |arities| {
                    gc.markSlice(arities);
                    for (arities) |a| traceFnProto(gc, a, .bytecode);
                }
                if (f.meta) |m| {
                    if (gc.markAndCheck(m)) traceValue(gc, m.*);
                }
                if (f.defining_ns) |ns| gc.markSlice(ns);
            }
        },

        // Builtin function — code pointer, nothing heap-allocated
        .builtin_fn => {},

        // Atom — value, meta, validator, watchers
        .atom => |a| {
            if (gc.markAndCheck(a)) {
                traceValue(gc, a.value);
                if (a.meta) |m| {
                    if (gc.markAndCheck(m)) traceValue(gc, m.*);
                }
                if (a.validator) |v| traceValue(gc, v);
                if (a.watch_keys) |wk| {
                    gc.markSlice(wk);
                    for (wk) |k| traceValue(gc, k);
                }
                if (a.watch_fns) |wf| {
                    gc.markSlice(wf);
                    for (wf) |f| traceValue(gc, f);
                }
            }
        },

        // Volatile ref
        .volatile_ref => |v| {
            if (gc.markAndCheck(v)) {
                traceValue(gc, v.value);
            }
        },

        // Regex pattern — source string + opaque compiled
        .regex => |r| {
            if (gc.markAndCheck(r)) {
                gc.markSlice(r.source);
                gc.markPtr(r.compiled);
            }
        },

        // Protocol
        .protocol => |p| {
            if (gc.markAndCheck(p)) {
                gc.markSlice(p.name);
                gc.markSlice(p.method_sigs);
                for (p.method_sigs) |sig| gc.markSlice(sig.name);
                traceValue(gc, Value{ .map = p.impls });
            }
        },

        // Protocol function
        .protocol_fn => |pf| {
            if (gc.markAndCheck(pf)) {
                traceValue(gc, Value{ .protocol = pf.protocol });
                gc.markSlice(pf.method_name);
            }
        },

        // MultiFn — dispatch_fn, methods, prefer_table, hierarchy_var
        .multi_fn => |mf| {
            if (gc.markAndCheck(mf)) {
                gc.markSlice(mf.name);
                traceValue(gc, mf.dispatch_fn);
                traceValue(gc, Value{ .map = mf.methods });
                if (mf.prefer_table) |pt| {
                    traceValue(gc, Value{ .map = pt });
                }
                if (mf.hierarchy_var) |hv| {
                    traceValue(gc, Value{ .var_ref = hv });
                }
            }
        },

        // Lazy sequence — thunk + realized value + structural metadata
        .lazy_seq => |ls| {
            if (gc.markAndCheck(ls)) {
                if (ls.thunk) |t| traceValue(gc, t);
                if (ls.realized) |r| traceValue(gc, r);
                if (ls.meta) |m| {
                    gc.markPtr(m);
                    switch (m.*) {
                        .lazy_map => |lm| {
                            traceValue(gc, lm.f);
                            traceValue(gc, lm.source);
                        },
                        .lazy_filter => |lf| {
                            traceValue(gc, lf.pred);
                            traceValue(gc, lf.source);
                        },
                        .lazy_take => |lt| {
                            traceValue(gc, lt.source);
                        },
                        .iterate => |it| {
                            traceValue(gc, it.f);
                            traceValue(gc, it.current);
                        },
                        .range => {},
                    }
                }
            }
        },

        // Cons cell — first + rest
        .cons => |c| {
            if (gc.markAndCheck(c)) {
                traceValue(gc, c.first);
                traceValue(gc, c.rest);
            }
        },

        // Var reference — symbol, root value, metadata
        .var_ref => |v| {
            if (gc.markAndCheck(v)) {
                if (v.sym.ns) |ns| gc.markSlice(ns);
                gc.markSlice(v.sym.name);
                if (v.sym.meta) |m| {
                    if (gc.markAndCheck(m)) traceValue(gc, m.*);
                }
                gc.markSlice(v.ns_name);
                traceValue(gc, v.root);
                if (v.doc) |d| gc.markSlice(d);
                if (v.arglists) |a| gc.markSlice(a);
                if (v.added) |a| gc.markSlice(a);
                if (v.since_cw) |s| gc.markSlice(s);
                if (v.meta) |m| {
                    traceValue(gc, Value{ .map = m });
                }
            }
        },

        // Delay — fn_val, cached, error_cached
        .delay => |d| {
            if (gc.markAndCheck(d)) {
                if (d.fn_val) |f| traceValue(gc, f);
                if (d.cached) |c| traceValue(gc, c);
                if (d.error_cached) |e| traceValue(gc, e);
            }
        },

        // Reduced — wrapped value
        .reduced => |r| {
            if (gc.markAndCheck(r)) {
                traceValue(gc, r.value);
            }
        },

        // Transient vector — mutable items buffer
        .transient_vector => |tv| {
            if (gc.markAndCheck(tv)) {
                gc.markSlice(tv.items.items);
                for (tv.items.items) |item| traceValue(gc, item);
            }
        },

        // Transient map — mutable entries buffer
        .transient_map => |tm| {
            if (gc.markAndCheck(tm)) {
                gc.markSlice(tm.entries.items);
                for (tm.entries.items) |entry| traceValue(gc, entry);
            }
        },

        // Transient set — mutable items buffer
        .transient_set => |ts| {
            if (gc.markAndCheck(ts)) {
                gc.markSlice(ts.items.items);
                for (ts.items.items) |item| traceValue(gc, item);
            }
        },

        // Chunked cons — chunk + rest
        .chunked_cons => |cc| {
            if (gc.markAndCheck(cc)) {
                traceValue(gc, Value{ .array_chunk = cc.chunk });
                traceValue(gc, cc.more);
            }
        },

        // Chunk buffer — mutable items
        .chunk_buffer => |cb| {
            if (gc.markAndCheck(cb)) {
                gc.markSlice(cb.items.items);
                for (cb.items.items) |item| traceValue(gc, item);
            }
        },

        // Array chunk — immutable slice view
        .array_chunk => |ac| {
            if (gc.markAndCheck(ac)) {
                gc.markSlice(ac.array);
                for (ac.array[ac.off..ac.end]) |item| traceValue(gc, item);
            }
        },
    }
}

/// Trace all root references, marking reachable Values as live.
/// Walks value slices, individual values, Env namespaces, and dynamic binding stack.
pub fn traceRoots(gc: *MarkSweepGc, roots: RootSet) void {
    // 1. Trace value slices (VM stack, TW locals, constant pools, etc.)
    //    Also mark the backing arrays themselves (they may be GC-tracked).
    for (roots.value_slices) |slice| {
        gc.markSlice(slice);
        for (slice) |val| traceValue(gc, val);
    }
    // 2. Trace individual values
    for (roots.values) |val| traceValue(gc, val);
    // 3. Trace environment (all namespaces → vars → root values)
    if (roots.env) |env| traceEnv(gc, env);
    // 4. Trace dynamic binding stack (global, single-thread)
    traceBindingStack(gc);
}

/// Walk all namespaces in the environment.
fn traceEnv(gc: *MarkSweepGc, env: *const env_mod.Env) void {
    var ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        traceNamespace(gc, ns_entry.value_ptr.*);
    }
}

/// Trace all Vars in a namespace (mappings + refers).
/// Does NOT markAndCheck the Namespace itself — it may not be GC-tracked.
fn traceNamespace(gc: *MarkSweepGc, ns: *const ns_mod.Namespace) void {
    var map_iter = ns.mappings.iterator();
    while (map_iter.next()) |entry| {
        traceVarRoots(gc, entry.value_ptr.*);
    }
    var ref_iter = ns.refers.iterator();
    while (ref_iter.next()) |entry| {
        traceVarRoots(gc, entry.value_ptr.*);
    }
}

/// Trace the root value and metadata of a Var.
/// Does NOT markAndCheck the Var itself — it may not be GC-tracked.
fn traceVarRoots(gc: *MarkSweepGc, v: *const var_mod.Var) void {
    traceValue(gc, v.root);
    if (v.meta) |m| {
        traceValue(gc, Value{ .map = m });
    }
}

/// Walk the dynamic binding frame stack and trace all bound Values.
fn traceBindingStack(gc: *MarkSweepGc) void {
    var frame = var_mod.getCurrentBindingFrame();
    while (frame) |f| {
        for (f.entries) |entry| {
            traceValue(gc, entry.val);
        }
        frame = f.prev;
    }
}

// === Tests ===

test "ArenaGc init creates valid instance" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const s = gc.strategy().stats();
    try std.testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), s.alloc_count);
}

test "ArenaGc alloc returns non-null pointer" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const ptr = gc.strategy().alloc(64, .@"1");
    try std.testing.expect(ptr != null);
}

test "ArenaGc shouldCollect returns false" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    try std.testing.expect(!gc.strategy().shouldCollect());
}

test "ArenaGc collect is no-op" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    // Should not crash
    gc.strategy().collect(.{});
}

test "ArenaGc stats tracks allocation count" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();
    _ = strat.alloc(32, .@"1");
    _ = strat.alloc(64, .@"1");

    const s = strat.stats();
    try std.testing.expectEqual(@as(u64, 2), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 96), s.bytes_allocated);
}

test "ArenaGc allocator returns usable std.mem.Allocator" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    // Should be able to allocate and use memory through std.mem.Allocator
    const slice = try alloc.alloc(u8, 128);
    @memset(slice, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[127]);
}

test "Multiple allocations tracked correctly" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();

    // Allocate various sizes
    _ = strat.alloc(8, .@"1");
    _ = strat.alloc(16, .@"1");
    _ = strat.alloc(32, .@"1");
    _ = strat.alloc(64, .@"1");

    const s = strat.stats();
    try std.testing.expectEqual(@as(u64, 4), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 120), s.bytes_allocated);
}

// === MarkSweepGc Tests ===

test "MarkSweepGc init creates valid instance" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const s = gc.strategy().stats();
    try std.testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
}

test "MarkSweepGc allocator returns usable std.mem.Allocator" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const slice = try a.alloc(u8, 128);
    @memset(slice, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[127]);
}

test "MarkSweepGc tracks allocations" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);

    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
    try std.testing.expect(gc.bytes_allocated > 0);
    try std.testing.expectEqual(@as(u64, 2), gc.alloc_count);
}

test "MarkSweepGc sweep frees unmarked allocations" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const p1 = try a.create(u64);
    _ = try a.create(u64); // p2 — not marked

    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());

    gc.markPtr(p1);
    gc.sweep();

    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 1), gc.collect_count);
}

test "MarkSweepGc sweep frees all when nothing marked" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);
    _ = try a.create(u64);

    gc.sweep();

    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), gc.bytes_allocated);
}

test "MarkSweepGc free removes from tracking" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const p1 = try a.create(u64);
    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());

    a.destroy(p1);
    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
}

test "MarkSweepGc multiple collect cycles" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Cycle 1: allocate 3, keep 1
    const p1 = try a.create(u64);
    _ = try a.create(u64);
    _ = try a.create(u64);
    gc.markPtr(p1);
    gc.sweep();
    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());

    // Cycle 2: allocate 2 more, keep p1 + p4
    const p4 = try a.create(u64);
    _ = try a.create(u64);
    gc.markPtr(p1);
    gc.markPtr(p4);
    gc.sweep();
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 2), gc.collect_count);
}

test "MarkSweepGc shouldCollect respects threshold" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    gc.threshold = 64;

    try std.testing.expect(!gc.strategy().shouldCollect());

    const a = gc.allocator();
    _ = try a.alloc(u8, 128);

    try std.testing.expect(gc.strategy().shouldCollect());
}

test "MarkSweepGc strategy vtable alloc works" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();
    const p = strat.alloc(64, .@"1");
    try std.testing.expect(p != null);

    const s = strat.stats();
    try std.testing.expect(s.bytes_allocated >= 64);
    try std.testing.expectEqual(@as(u64, 1), s.alloc_count);
}

test "MarkSweepGc strategy collect triggers sweep" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);

    gc.strategy().collect(.{});

    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 1), gc.collect_count);
}

// === traceValue Tests ===

test "traceValue primitives are no-op" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    // Primitives don't allocate — tracing should be safe
    traceValue(&gc, .nil);
    traceValue(&gc, Value{ .boolean = true });
    traceValue(&gc, Value{ .integer = 42 });
    traceValue(&gc, Value{ .float = 3.14 });
    traceValue(&gc, Value{ .char = 'A' });
    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
}

test "traceValue keeps vector and items alive" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Create a vector [42 99]
    const items = try a.alloc(Value, 2);
    items[0] = Value{ .integer = 42 };
    items[1] = Value{ .integer = 99 };

    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    // Allocate an orphan that should be collected
    _ = try a.create(value_mod.PersistentVector);

    try std.testing.expectEqual(@as(usize, 3), gc.liveCount());

    // Trace the vector — keeps vec + items alive
    traceValue(&gc, Value{ .vector = vec });
    gc.sweep();

    // vec struct + items array survive, orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
}

test "traceValue keeps nested vector alive" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Inner vector [1 2]
    const inner_items = try a.alloc(Value, 2);
    inner_items[0] = Value{ .integer = 1 };
    inner_items[1] = Value{ .integer = 2 };
    const inner = try a.create(value_mod.PersistentVector);
    inner.* = .{ .items = inner_items };

    // Outer vector [inner_vec]
    const outer_items = try a.alloc(Value, 1);
    outer_items[0] = Value{ .vector = inner };
    const outer = try a.create(value_mod.PersistentVector);
    outer.* = .{ .items = outer_items };

    // Orphan
    _ = try a.create(value_mod.PersistentVector);

    try std.testing.expectEqual(@as(usize, 5), gc.liveCount());

    traceValue(&gc, Value{ .vector = outer });
    gc.sweep();

    // outer + outer_items + inner + inner_items = 4, orphan freed
    try std.testing.expectEqual(@as(usize, 4), gc.liveCount());
}

test "traceValue keeps cons chain alive" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // (cons 1 (cons 2 nil)) → two Cons cells
    const c2 = try a.create(value_mod.Cons);
    c2.* = .{ .first = Value{ .integer = 2 }, .rest = .nil };
    const c1 = try a.create(value_mod.Cons);
    c1.* = .{ .first = Value{ .integer = 1 }, .rest = Value{ .cons = c2 } };

    // Orphan
    _ = try a.create(value_mod.Cons);

    try std.testing.expectEqual(@as(usize, 3), gc.liveCount());

    traceValue(&gc, Value{ .cons = c1 });
    gc.sweep();

    // c1 + c2 survive, orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
}

test "traceValue keeps map entries alive" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Map {:a 1} — entries = [keyword, integer]
    const entries = try a.alloc(Value, 2);
    entries[0] = Value{ .keyword = .{ .ns = null, .name = "a" } };
    entries[1] = Value{ .integer = 1 };
    const m = try a.create(value_mod.PersistentArrayMap);
    m.* = .{ .entries = entries };

    // Orphan
    _ = try a.alloc(u8, 64);

    try std.testing.expectEqual(@as(usize, 3), gc.liveCount());

    traceValue(&gc, Value{ .map = m });
    gc.sweep();

    // map + entries survive, orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
}

test "traceValue string marks backing array" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    const str = try a.alloc(u8, 5);
    @memcpy(str, "hello");

    // Orphan
    _ = try a.alloc(u8, 32);

    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());

    traceValue(&gc, Value{ .string = str });
    gc.sweep();

    // String backing array survives, orphan freed
    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());
}

test "traceValue cycle detection via mark bit" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Create a vector and trace it twice — second trace should be a no-op
    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 42 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    traceValue(&gc, Value{ .vector = vec });
    // Trace again — markAndCheck should return false, preventing re-traversal
    traceValue(&gc, Value{ .vector = vec });

    gc.sweep();
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
}

test "traceValue handles lazy_seq" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Create a realized lazy-seq pointing to a list
    const list_items = try a.alloc(Value, 2);
    list_items[0] = Value{ .integer = 1 };
    list_items[1] = Value{ .integer = 2 };
    const list = try a.create(value_mod.PersistentList);
    list.* = .{ .items = list_items };

    const ls = try a.create(value_mod.LazySeq);
    ls.* = .{ .thunk = null, .realized = Value{ .list = list } };

    // Orphan
    _ = try a.create(value_mod.LazySeq);

    try std.testing.expectEqual(@as(usize, 4), gc.liveCount());

    traceValue(&gc, Value{ .lazy_seq = ls });
    gc.sweep();

    // ls + list + list_items survive, orphan freed
    try std.testing.expectEqual(@as(usize, 3), gc.liveCount());
}

test "traceValue handles lazy_seq with meta (lazy_filter)" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Create a source list that lazy_filter references
    const list_items = try a.alloc(Value, 3);
    list_items[0] = Value{ .integer = 2 };
    list_items[1] = Value{ .integer = 3 };
    list_items[2] = Value{ .integer = 4 };
    const source_list = try a.create(value_mod.PersistentList);
    source_list.* = .{ .items = list_items };

    // Create a lazy_seq with lazy_filter meta (pred is nil placeholder, source is list)
    const meta = try a.create(value_mod.LazySeq.Meta);
    meta.* = .{ .lazy_filter = .{ .pred = .nil, .source = Value{ .list = source_list } } };
    const ls = try a.create(value_mod.LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };

    // Orphan allocation that should be freed
    _ = try a.create(value_mod.PersistentList);

    // ls + meta + source_list + list_items + orphan = 5
    try std.testing.expectEqual(@as(usize, 5), gc.liveCount());

    traceValue(&gc, Value{ .lazy_seq = ls });
    gc.sweep();

    // ls + meta + source_list + list_items survive, orphan freed
    try std.testing.expectEqual(@as(usize, 4), gc.liveCount());
}

// === traceRoots Tests ===

test "traceRoots traces stack value slices" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    const a = gc_inst.allocator();

    // Create a vector on the "stack"
    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 42 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    // Orphan
    _ = try a.create(value_mod.PersistentVector);

    try std.testing.expectEqual(@as(usize, 3), gc_inst.liveCount());

    // Simulate VM stack
    const stack_vals = [_]Value{Value{ .vector = vec }};
    const slices = [_][]const Value{&stack_vals};
    traceRoots(&gc_inst, .{ .value_slices = &slices });
    gc_inst.sweep();

    // vec + items survive, orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "traceRoots traces individual values" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    const a = gc_inst.allocator();

    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 1 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    _ = try a.alloc(u8, 64); // orphan

    try std.testing.expectEqual(@as(usize, 3), gc_inst.liveCount());

    const extra = [_]Value{Value{ .vector = vec }};
    traceRoots(&gc_inst, .{ .values = &extra });
    gc_inst.sweep();

    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "traceRoots traces env namespaces and vars" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    const a = gc_inst.allocator();

    // Use a separate arena for infrastructure (Env/Namespace/Var)
    var infra_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer infra_arena.deinit();
    const infra = infra_arena.allocator();

    var env = env_mod.Env.init(infra);

    const ns = try env.findOrCreateNamespace("test");

    // Create a GC-allocated vector as var root
    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 99 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    const v = try ns.intern("my-var");
    v.root = Value{ .vector = vec };

    // Orphan
    _ = try a.create(value_mod.PersistentVector);

    try std.testing.expectEqual(@as(usize, 3), gc_inst.liveCount());

    traceRoots(&gc_inst, .{ .env = &env });
    gc_inst.sweep();

    // vec + items survive (via env → ns → var → root), orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "traceRoots traces dynamic binding stack" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    const a = gc_inst.allocator();

    // Use arena for Var infrastructure
    var infra_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer infra_arena.deinit();
    const infra = infra_arena.allocator();

    // Create a dynamic Var
    const v = try infra.create(var_mod.Var);
    v.* = .{
        .sym = .{ .ns = null, .name = "dyn" },
        .ns_name = "test",
        .dynamic = true,
    };

    // Create a GC-allocated value bound to the Var
    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 7 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    // Push a binding frame
    var entries = [_]var_mod.BindingEntry{.{ .var_ptr = v, .val = Value{ .vector = vec } }};
    var frame = var_mod.BindingFrame{ .entries = &entries, .prev = null };
    var_mod.pushBindings(&frame);
    defer var_mod.popBindings();

    // Orphan
    _ = try a.create(value_mod.PersistentVector);

    try std.testing.expectEqual(@as(usize, 3), gc_inst.liveCount());

    traceRoots(&gc_inst, .{});
    gc_inst.sweep();

    // vec + items survive (via binding stack), orphan freed
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "traceRoots combined: stack + env + bindings" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    const a = gc_inst.allocator();

    var infra_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer infra_arena.deinit();
    const infra = infra_arena.allocator();

    // 1. Stack value (vector)
    const stack_items = try a.alloc(Value, 1);
    stack_items[0] = Value{ .integer = 1 };
    const stack_vec = try a.create(value_mod.PersistentVector);
    stack_vec.* = .{ .items = stack_items };

    // 2. Env var root (list)
    var env = env_mod.Env.init(infra);
    const ns = try env.findOrCreateNamespace("test");
    const env_items = try a.alloc(Value, 1);
    env_items[0] = Value{ .integer = 2 };
    const env_list = try a.create(value_mod.PersistentList);
    env_list.* = .{ .items = env_items };
    const v = try ns.intern("x");
    v.root = Value{ .list = env_list };

    // 3. Binding stack value (cons)
    const bound_cons = try a.create(value_mod.Cons);
    bound_cons.* = .{ .first = Value{ .integer = 3 }, .rest = .nil };
    const dyn_var = try infra.create(var_mod.Var);
    dyn_var.* = .{ .sym = .{ .ns = null, .name = "d" }, .ns_name = "test", .dynamic = true };
    var binding_entries = [_]var_mod.BindingEntry{.{ .var_ptr = dyn_var, .val = Value{ .cons = bound_cons } }};
    var binding_frame = var_mod.BindingFrame{ .entries = &binding_entries, .prev = null };
    var_mod.pushBindings(&binding_frame);
    defer var_mod.popBindings();

    // 4. Orphans
    _ = try a.create(value_mod.PersistentVector);
    _ = try a.alloc(u8, 32);

    // Total: stack_items + stack_vec + env_items + env_list + bound_cons + 2 orphans = 7
    try std.testing.expectEqual(@as(usize, 7), gc_inst.liveCount());

    const stack_vals = [_]Value{Value{ .vector = stack_vec }};
    const slices = [_][]const Value{&stack_vals};
    traceRoots(&gc_inst, .{
        .value_slices = &slices,
        .env = &env,
    });
    gc_inst.sweep();

    // 5 survive (stack_items, stack_vec, env_items, env_list, bound_cons), 2 orphans freed
    try std.testing.expectEqual(@as(usize, 5), gc_inst.liveCount());
}

// === collectIfNeeded Tests ===

test "collectIfNeeded runs when threshold exceeded" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    gc_inst.threshold = 32;

    const a = gc_inst.allocator();

    // Allocate a vector (root) and an orphan
    const items = try a.alloc(Value, 1);
    items[0] = Value{ .integer = 42 };
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    _ = try a.alloc(u8, 64); // orphan, pushes over threshold

    try std.testing.expect(gc_inst.bytes_allocated >= 32);
    try std.testing.expectEqual(@as(usize, 3), gc_inst.liveCount());
    try std.testing.expectEqual(@as(u64, 0), gc_inst.collect_count);

    // Build root set with the vector as a stack value
    const stack_vals = [_]Value{Value{ .vector = vec }};
    const slices = [_][]const Value{&stack_vals};
    gc_inst.collectIfNeeded(.{ .value_slices = &slices });

    // Should have collected (orphan freed)
    try std.testing.expectEqual(@as(u64, 1), gc_inst.collect_count);
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "collectIfNeeded no-op below threshold" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    // Default 1MB threshold — won't be exceeded
    const a = gc_inst.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);

    gc_inst.collectIfNeeded(.{});

    try std.testing.expectEqual(@as(u64, 0), gc_inst.collect_count);
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
}

test "collectIfNeeded grows threshold when live set exceeds it" {
    var gc_inst = MarkSweepGc.init(std.testing.allocator);
    defer gc_inst.deinit();

    gc_inst.threshold = 16; // very low

    const a = gc_inst.allocator();

    // Allocate live data exceeding threshold
    const items = try a.alloc(Value, 10);
    for (items, 0..) |*item, i| {
        item.* = Value{ .integer = @intCast(i) };
    }
    const vec = try a.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };

    const old_threshold = gc_inst.threshold;

    // All data is rooted — nothing to collect
    const stack_vals = [_]Value{Value{ .vector = vec }};
    const slices = [_][]const Value{&stack_vals};
    gc_inst.collectIfNeeded(.{ .value_slices = &slices });

    try std.testing.expectEqual(@as(u64, 1), gc_inst.collect_count);
    try std.testing.expectEqual(@as(usize, 2), gc_inst.liveCount());
    // Threshold grew since live set exceeded old threshold
    try std.testing.expect(gc_inst.threshold > old_threshold);
}
