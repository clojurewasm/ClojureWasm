// SPDX-License-Identifier: EPL-2.0
//! nREPL session registry (ADR-0170). Sessions are what CIDER routes
//! by: `clone` mints a fresh unique id (CIDER clones TWO — main +
//! tooling — over one socket and relies on them being distinct);
//! each session owns its REPL history (`*1` `*2` `*3` `*e`, via the
//! shared `eval_session.StarState`) and its current namespace, so
//! tooling-session evals cannot rotate the user's `*1` or leak an
//! `in-ns` into the REPL session (JVM nREPL sessions are per-session
//! binding maps — the F-011 oracle; babashka's shared-global
//! simplification is NOT copied here).
//!
//! GC rooting of the held star Values lives in `StarState` (pin /
//! unpin discipline — see `.dev/gc_rooting.md` § REPL star history).

const std = @import("std");
const GcHeap = @import("../../runtime/gc/gc_heap.zig").GcHeap;
const StarState = @import("../eval_session.zig").StarState;
const uuid = @import("../../runtime/uuid.zig");

pub const Session = struct {
    /// UUID v4 id (via runtime/uuid.zig), owned by this struct.
    id: [36]u8,
    /// Current-namespace NAME (Env-owned slice — Namespace names live
    /// as long as the Env). Stored by name, not pointer, so a session
    /// survives an ns being re-created.
    ns_name: []const u8 = "user",
    /// `*1` / `*2` / `*3` / `*e` held between evals (pinned).
    stars: StarState,

    pub fn idSlice(self: *const Session) []const u8 {
        return &self.id;
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    gc: *GcHeap,
    io: std.Io,
    map: std.StringHashMapUnmanaged(*Session) = .empty,
    default_session: ?*Session = null,

    pub fn init(gpa: std.mem.Allocator, gc: *GcHeap, io: std.Io) Registry {
        return .{ .gpa = gpa, .gc = gc, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.stars.release();
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.map.deinit(self.gpa);
    }

    /// Mint a fresh session (the `clone` op). The returned id slice is
    /// owned by the session and stays valid until `close`.
    pub fn clone(self: *Registry) !*Session {
        const sess = try self.gpa.create(Session);
        errdefer self.gpa.destroy(sess);
        sess.* = .{ .id = uuid.format(uuid.generateV4(self.io)), .stars = StarState.init(self.gc) };
        try self.map.put(self.gpa, sess.idSlice(), sess);
        return sess;
    }

    pub fn get(self: *Registry, id: []const u8) ?*Session {
        return self.map.get(id);
    }

    /// Fetch the session named by `id`, or lazily mint a stable default
    /// session for session-less requests (a bare `eval` without a prior
    /// `clone` — lein/manual drivers do this).
    pub fn getOrDefault(self: *Registry, id: ?[]const u8) !*Session {
        if (id) |i| {
            if (self.map.get(i)) |s| return s;
        }
        if (self.default_session) |s| return s;
        const s = try self.clone();
        self.default_session = s;
        return s;
    }

    /// Close (the `close` op). Returns false for an unknown id.
    pub fn close(self: *Registry, id: []const u8) bool {
        const kv = self.map.fetchRemove(id) orelse return false;
        if (self.default_session == kv.value) self.default_session = null;
        kv.value.stars.release();
        self.gpa.destroy(kv.value);
        return true;
    }

    pub fn count(self: *const Registry) usize {
        return self.map.count();
    }
};

// --- tests ---

const testing = std.testing;
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;

test "Registry: clone mints distinct sessions; close removes; default is stable" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    var reg = Registry.init(testing.allocator, &rt.gc, threaded.io());
    defer reg.deinit();

    const s1 = try reg.clone();
    const s2 = try reg.clone();
    try testing.expect(!std.mem.eql(u8, s1.idSlice(), s2.idSlice()));
    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expectEqual(s1, reg.get(s1.idSlice()).?);

    const d1 = try reg.getOrDefault(null);
    const d2 = try reg.getOrDefault("no-such-id");
    try testing.expectEqual(d1, d2);

    try testing.expect(reg.close(s1.idSlice()));
    try testing.expect(!reg.close(s1.idSlice()));
}

test "Registry: per-session star rotation pins/unpins in pairs" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    var reg = Registry.init(testing.allocator, &rt.gc, threaded.io());
    defer reg.deinit();
    const s = try reg.clone();

    const pins_before = rt.gc.permanent_roots.items.len;
    try s.stars.rotate(Value.initInteger(1));
    try s.stars.rotate(Value.initInteger(2));
    try s.stars.rotate(Value.initInteger(3));
    try s.stars.rotate(Value.initInteger(4)); // 1 falls off the chain
    try testing.expectEqual(Value.initInteger(4), s.stars.values[StarState.idx_1]);
    try testing.expectEqual(Value.initInteger(3), s.stars.values[StarState.idx_2]);
    try testing.expectEqual(Value.initInteger(2), s.stars.values[StarState.idx_3]);
    // net pins = the 3 live star slots (nil placeholders unpin as no-ops)
    try testing.expectEqual(pins_before + 3, rt.gc.permanent_roots.items.len);
    try s.stars.setE(Value.initInteger(9));
    try testing.expectEqual(pins_before + 4, rt.gc.permanent_roots.items.len);
    // a second session's stars are independent
    const s2 = try reg.clone();
    try s2.stars.rotate(Value.initInteger(7));
    try testing.expectEqual(Value.initInteger(4), s.stars.values[StarState.idx_1]);
    try testing.expectEqual(Value.initInteger(7), s2.stars.values[StarState.idx_1]);
}
