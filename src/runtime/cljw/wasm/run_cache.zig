// SPDX-License-Identifier: EPL-2.0
//! Process-wide cache of prepared WASI commands for `wasm/run` (D-350).
//! Maps a module file, identified by its jail-resolved path plus the inode,
//! size and mtime `stat` reports, to a zwasm `PreparedWasi` (validated +
//! JIT-compiled once), so a repeated `(wasm/run path …)` pays instantiate +
//! run only. Bounded LRU of `capacity` modules. Compiled ONLY under `-Dwasm`.
//!
//! Lifetime: a run holds a `Lease`; an entry evicted or cleared while leased
//! is unlinked at once and freed by its last `release`, so no run ever sees
//! its module freed. The mutex guards only list edits, never a compile or a
//! run, and nothing under it allocates on the cljw GC heap or parks at a
//! safepoint.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/run, wasm/clear-cache!
const std = @import("std");
const engine = @import("engine.zig");
const io_default = @import("../../concurrency/io_default.zig");

/// Modules kept compiled at once. A Go wasip1 guest's JIT code is tens of MB,
/// so the bound is small.
pub const capacity: usize = 8;

/// What identifies one version of a module file.
const Key = struct {
    path: []const u8,
    inode: std.Io.File.INode,
    size: u64,
    mtime: std.Io.Timestamp,

    fn of(path: []const u8, st: std.Io.File.Stat) Key {
        return .{ .path = path, .inode = st.inode, .size = st.size, .mtime = st.mtime };
    }

    fn eql(a: Key, b: Key) bool {
        return a.inode == b.inode and a.size == b.size and
            a.mtime.nanoseconds == b.mtime.nanoseconds and std.mem.eql(u8, a.path, b.path);
    }
};

const Entry = struct {
    alloc: std.mem.Allocator,
    key: Key,
    prepared: engine.Prepared,
    /// Runs holding this entry; guarded by `mutex`.
    leases: u32 = 0,
    /// Unlinked from `entries`; the last `release` frees it.
    unlinked: bool = false,
    last_use: u64 = 0,

    fn destroy(self: *Entry) void {
        self.prepared.deinit();
        self.alloc.free(self.key.path);
        self.alloc.destroy(self);
    }
};

var mutex: std.Io.Mutex = .init;
var entries: std.ArrayList(*Entry) = .empty;
/// The allocator `entries` grows on (the first caller's; F-006 layer-1).
var list_alloc: ?std.mem.Allocator = null;
var tick: u64 = 0;

/// A run's hold on one cached module. `release` exactly once.
pub const Lease = struct {
    entry: *Entry,

    pub fn prepared(self: Lease) *const engine.Prepared {
        return &self.entry.prepared;
    }

    pub fn release(self: Lease) void {
        const free_it = blk: {
            io_default.lockMutex(&mutex);
            defer io_default.unlockMutex(&mutex);
            self.entry.leases -= 1;
            break :blk self.entry.unlinked and self.entry.leases == 0;
        };
        if (free_it) self.entry.destroy();
    }
};

fn findLocked(key: Key) ?*Entry {
    for (entries.items) |e| if (e.key.eql(key)) return e;
    return null;
}

fn leaseLocked(e: *Entry) Lease {
    tick += 1;
    e.last_use = tick;
    e.leases += 1;
    return .{ .entry = e };
}

/// Unlink `entries[i]`; returns it when nothing holds it (caller frees it
/// outside the lock), null when a run still does.
fn unlinkLocked(i: usize) ?*Entry {
    const e = entries.swapRemove(i);
    e.unlinked = true;
    return if (e.leases == 0) e else null;
}

/// The result of `lookup`: a lease on a hit, else the `stat` a later
/// `insert` keys the module by.
pub const Probe = struct {
    stat: std.Io.File.Stat,
    hit: ?Lease,
};

/// Look `path` (jail-resolved, as the caller would read it) up by its current
/// `stat`. Fails only when the file cannot be stat'd.
pub fn lookup(io: std.Io, path: []const u8) !Probe {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    io_default.lockMutex(&mutex);
    defer io_default.unlockMutex(&mutex);
    return .{ .stat = st, .hit = if (findLocked(Key.of(path, st))) |e| leaseLocked(e) else null };
}

/// Prepare `bytes` (read from `path` after `lookup` stat'd it) and cache them,
/// evicting the least recently used module past `capacity`. The compile runs
/// outside the lock; two threads that miss on the same key at once both
/// compile and the loser's copy is dropped. Fails as `engine.prepare` does.
pub fn insert(alloc: std.mem.Allocator, path: []const u8, st: std.Io.File.Stat, bytes: []const u8) !Lease {
    const probe = Key.of(path, st);
    const fresh = try alloc.create(Entry);
    errdefer alloc.destroy(fresh);
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    fresh.* = .{
        .alloc = alloc,
        .key = Key.of(owned_path, st),
        .prepared = try engine.prepare(alloc, bytes),
    };
    errdefer fresh.prepared.deinit();

    var drop: [2]?*Entry = .{ null, null };
    defer for (drop) |d| if (d) |e| e.destroy();
    io_default.lockMutex(&mutex);
    defer io_default.unlockMutex(&mutex);
    if (findLocked(probe)) |e| {
        drop[0] = fresh;
        return leaseLocked(e);
    }
    if (list_alloc == null) list_alloc = alloc;
    try entries.append(list_alloc.?, fresh);
    const lease = leaseLocked(fresh);
    if (entries.items.len > capacity) {
        var lru: usize = 0;
        for (entries.items, 0..) |e, i| {
            if (e.last_use < entries.items[lru].last_use) lru = i;
        }
        drop[1] = unlinkLocked(lru);
    }
    return lease;
}

/// Drop every cached module; one still running is freed when its run ends.
/// Returns how many were cached.
pub fn clear() usize {
    // `entries` never holds more than `capacity` once `insert` returns.
    var idle: [capacity]?*Entry = @splat(null);
    defer for (idle) |d| if (d) |e| e.destroy();
    io_default.lockMutex(&mutex);
    defer io_default.unlockMutex(&mutex);
    const n = entries.items.len;
    var i: usize = 0;
    while (entries.items.len > 0) : (i += 1) idle[i] = unlinkLocked(entries.items.len - 1);
    if (list_alloc) |a| entries.clearAndFree(a);
    list_alloc = null;
    return n;
}

/// Modules currently cached (for tests and diagnostics).
pub fn count() usize {
    io_default.lockMutex(&mutex);
    defer io_default.unlockMutex(&mutex);
    return entries.items.len;
}

// (module (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))
//         (func (export "_start") i32.const 42 call 0))
const exit42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f,
    0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2a, 0x10, 0x00, 0x0b,
};

test "run_cache: a miss compiles once, a hit reuses it, a changed file misses, clear frees" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.wasm", .data = &exit42_wasm });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/m.wasm", .{tmp.sub_path});
    defer alloc.free(path);
    _ = clear();

    const miss = try lookup(io, path);
    try std.testing.expect(miss.hit == null);
    const lease = try insert(alloc, path, miss.stat, &exit42_wasm);
    const first = try engine.runPrepared(alloc, io, lease.prepared(), .{});
    defer alloc.free(first.out);
    defer alloc.free(first.err);
    try std.testing.expectEqual(@as(u8, 42), first.exit);
    lease.release();

    const again = try lookup(io, path);
    try std.testing.expect(again.hit != null);
    try std.testing.expectEqual(lease.entry, again.hit.?.entry);
    // Cleared while leased: unlinked now, freed by the release below.
    try std.testing.expectEqual(@as(usize, 1), clear());
    try std.testing.expectEqual(@as(usize, 0), count());
    const second = try engine.runPrepared(alloc, io, again.hit.?.prepared(), .{});
    defer alloc.free(second.out);
    defer alloc.free(second.err);
    try std.testing.expectEqual(@as(u8, 42), second.exit);
    again.hit.?.release();

    // A rewritten file is a different key, whatever its path.
    const before = try lookup(io, path);
    (try insert(alloc, path, before.stat, &exit42_wasm)).release();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.wasm", .data = &(exit42_wasm ++ [_]u8{ 0x00, 0x01, 0x00 }) });
    const changed = try lookup(io, path);
    try std.testing.expect(changed.hit == null);
    try std.testing.expectEqual(@as(usize, 1), clear());
}

test "run_cache: past capacity the least recently used idle module is freed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = clear();
    var paths: [capacity + 1][]u8 = undefined;
    for (&paths, 0..) |*p, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "m{d}.wasm", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = &exit42_wasm });
        p.* = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        const probe = try lookup(io, p.*);
        (try insert(alloc, p.*, probe.stat, &exit42_wasm)).release();
    }
    defer for (paths) |p| alloc.free(p);
    try std.testing.expectEqual(capacity, count());
    try std.testing.expect((try lookup(io, paths[0])).hit == null);
    const newest = try lookup(io, paths[capacity]);
    try std.testing.expect(newest.hit != null);
    newest.hit.?.release();
    try std.testing.expectEqual(capacity, clear());
}
