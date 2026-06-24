// SPDX-License-Identifier: EPL-2.0
//! STM LockingTransaction engine (Phase B #5, ADR-0090 §3 — MVCC retry-only).
//!
//! `(dosync body...)` → `(__run-in-transaction (fn* [] body...))` runs the
//! body thunk inside a transaction on the CALLING thread (not a spawned
//! worker — unlike `future`). Inside the transaction, `ref-set` / `alter`
//! write to a per-transaction value cache (`vals`); `deref` of a Ref reads
//! through the cache (a transaction sees its own writes); at commit the
//! written Refs' locks are taken, a commit-point is stamped, and a new TVal is
//! spliced/recycled into each Ref's MVCC history ring.
//!
//! **This increment (#5-i) is the single-ref, single-thread slice**: no retry
//! loop (a single thread never conflicts), no multi-ref lock ordering (one
//! ref → no deadlock surface), no commute/ensure, no snapshot read-point walk
//! (no concurrent commit can change a Ref mid-transaction). Those land in
//! later increments (#5-ii multi-ref lock ordering via a `Ref.id`, #5-iii
//! retry + the read-point walk + the concurrent serializability test + AD-013,
//! #5-iv commute, #5-v ensure). The retry/conflict machinery + the GC rooting
//! of the in-txn maps (a peer collect racing a live `dosync` — dormant until
//! auto-collect `#4a'`) are the remaining hardening.
//!
//! `current_tx` is a threadlocal (mirroring `env.current_frame`): the
//! transaction context for the running thread. Nested `(dosync (dosync ...))`
//! reuses the outer transaction (clj semantics).

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const ref_mod = @import("../stm/ref.zig");
const Ref = ref_mod.Ref;
const tval_mod = @import("../stm/tval.zig");
const TVal = tval_mod.TVal;
const heap_header = @import("../value/heap_header.zig");
const HeapHeader = heap_header.HeapHeader;
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const safepoint = @import("safepoint.zig");
const iref = @import("../iref.zig");
const root_set = @import("../gc/root_set.zig");

/// Bounded retry count for a conflicting transaction (clj `RETRY_LIMIT`).
const RETRY_LIMIT: u32 = 10000;

/// Monotonic point counter — `getReadPoint`/`getCommitPoint` both
/// increment-and-get (clj `lastPoint.incrementAndGet()`), so a read-point and
/// a commit-point are distinct ordered ids.
var last_point: std.atomic.Value(i64) = .init(0);

fn nextPoint() i64 {
    return last_point.fetchAdd(1, .monotonic) + 1;
}

/// Inline arg cap for a single `commute` call (`(commute r f & args)`); commute
/// args are nearly always 0-2. A wider call raises (rare, refinement-able).
const MAX_COMMUTE_ARGS = 7;

/// One recorded `commute` for replay at commit time. Args are held inline (no
/// arena), so the whole transaction's scratch is gpa-clearable per retry.
const CommuteEntry = struct {
    ref: *Ref,
    func: Value,
    args: [MAX_COMMUTE_ARGS]Value = undefined,
    args_len: u8 = 0,
};

pub const LockingTransaction = struct {
    read_point: i64,
    /// In-transaction value cache: a Ref's value AS SEEN by this transaction
    /// (its own writes included). Keyed by the GC-heap `*Ref`.
    vals: std.AutoHashMapUnmanaged(*Ref, Value) = .empty,
    /// Refs explicitly written (`ref-set`/`alter`) — the commit write set.
    sets: std.AutoHashMapUnmanaged(*Ref, void) = .empty,
    /// Recorded `commute`s, replayed against the committed value at commit
    /// (order-independent) so a commuted ref never conflicts/retries.
    commutes: std.ArrayList(CommuteEntry) = .empty,
    /// `ensure`d refs — read-locked at commit + read-point-conflict-checked
    /// (like `sets`) but NOT written, so a peer cannot write them under us
    /// (write-skew prevention). clj `doEnsure`.
    ensures: std.AutoHashMapUnmanaged(*Ref, void) = .empty,
    /// Flat `[ref, old, new, ...]` triples for watched refs, filled at the commit
    /// write loop and fired AFTER the locks release (JVM notifies post-commit).
    /// `old` may be recycled out of the ring by the splice, so the firing loop
    /// roots this whole list on an EvalFrame.
    notifies: std.ArrayList(Value) = .empty,
    gpa: std.mem.Allocator,
};

/// The running transaction for THIS thread, or null outside any `dosync`.
/// Threadlocal — mirrors `env.current_frame`. (The GC rooting of a live
/// transaction's `vals` map is the #4a' hardening; dormant while auto-collect
/// is off — no collect fires during a `dosync` today.)
pub threadlocal var current_tx: ?*LockingTransaction = null;

/// True when a transaction is running on this thread.
pub fn inTransaction() bool {
    return current_tx != null;
}

/// `(__run-in-transaction thunk)` — run the 0-arg `thunk` in a transaction and
/// return its value. Nested `dosync` reuses the outer transaction. #5-i is
/// single-thread: the body runs once and commits (no conflict → no retry).
pub fn runInTransaction(rt: *Runtime, env: *Env, thunk: Value, loc: SourceLocation) !Value {
    if (current_tx != null) {
        // Nested — accumulate into the outer transaction, no new commit here.
        return callThunk(rt, env, thunk, loc);
    }
    var tx: LockingTransaction = .{ .read_point = 0, .gpa = rt.gpa };
    defer tx.vals.deinit(rt.gpa);
    defer tx.sets.deinit(rt.gpa);
    defer tx.commutes.deinit(rt.gpa);
    defer tx.ensures.deinit(rt.gpa);
    defer tx.notifies.deinit(rt.gpa);
    current_tx = &tx;
    defer current_tx = null;

    // Bounded retry loop (clj `run`): each try takes a fresh read-point + clean
    // maps; a commit-time conflict (a peer committed a newer version after our
    // snapshot) re-runs the body. Retry-only — no barge (AD-013). A single
    // thread never conflicts, so this is a one-pass loop there.
    var attempt: u32 = 0;
    while (attempt < RETRY_LIMIT) : (attempt += 1) {
        tx.read_point = nextPoint();
        tx.vals.clearRetainingCapacity();
        tx.sets.clearRetainingCapacity();
        tx.commutes.clearRetainingCapacity();
        tx.ensures.clearRetainingCapacity();
        tx.notifies.clearRetainingCapacity();
        const ret = callThunk(rt, env, thunk, loc) catch |e| {
            if (e == error.StmRetry) continue;
            return e; // a real user error propagates out of the transaction
        };
        commit(rt, env, &tx, loc) catch |e| {
            if (e == error.StmRetry) continue;
            return e;
        };
        // Watches fire AFTER the commit released its locks (JVM order): a watch
        // fn may start its own transaction on the same refs, so notifying under
        // the commit lock would deadlock.
        try fireWatches(rt, env, &tx);
        return ret;
    }
    return error_catalog.raise(.stm_retry_limit, loc, .{});
}

fn callThunk(rt: *Runtime, env: *Env, thunk: Value, loc: SourceLocation) !Value {
    const vtable = rt.vtable orelse return error.InternalError;
    return vtable.callFn(rt, env, thunk, &.{}, loc);
}

/// In-transaction read of a Ref: the transaction's own cached write if any,
/// else the Ref's current committed value. (#5-i: no snapshot read-point ring
/// walk — a single thread sees no concurrent commit; #5-iii adds the walk +
/// the fault-driven retry.)
/// Mark every GC-heap Value held in this transaction's `vals` + `commutes` via
/// `markFn` (#4a' in-txn-map rooting). The collector calls this for the
/// collecting thread's `current_tx`, so a collect firing during a `dosync` body
/// does NOT sweep a value held only in the gpa maps (not on any operand stack).
/// The callback keeps `CommuteEntry` private + avoids a `mark_sweep` import cycle.
pub fn markRoots(tx: *LockingTransaction, context: *anyopaque, markFn: *const fn (*anyopaque, *heap_header.HeapHeader) void) void {
    var vit = tx.vals.valueIterator();
    while (vit.next()) |vp| {
        if (vp.heapHeader()) |h| markFn(context, h);
    }
    for (tx.commutes.items) |c| {
        if (c.func.heapHeader()) |h| markFn(context, h);
        for (c.args[0..c.args_len]) |a| {
            if (a.heapHeader()) |h| markFn(context, h);
        }
    }
}

pub fn doGet(tx: *LockingTransaction, ref: *Ref) Value {
    if (tx.vals.get(ref)) |v| return v;
    // Read the committed value UNDER the Ref's lock. An unsynchronized read of
    // `ref.tvals` can, under relaxed memory ordering, miss a commit that is
    // already in this transaction's snapshot (its `point` <= our read_point) —
    // the commit-time conflict check then sees no conflict, so we write back a
    // value derived from a stale read = a lost update (a serializability break
    // observed as 399/400 under contention in ReleaseSafe). The lock acquire
    // synchronizes-with the last committer's release, so we read the value the
    // conflict check validates against. (A write-set ref is already in `vals`
    // above, so commit-time replay never re-locks a held ref here.)
    while (!ref.lock.tryLock()) {
        // Yield to a pending stop-the-world collect (the object_monitor spin
        // discipline): a thread spinning on a contended Ref lock must still reach
        // a safepoint, or `stopWorld` waits for a park that never comes.
        if (safepoint.gc_requested.load(.acquire)) safepoint.park();
        std.atomic.spinLoopHint();
    }
    defer ref.lock.unlock();
    return ref.tvals.val;
}

/// In-transaction write of a Ref (`ref-set`). Records the Ref in the write set
/// + caches the value. Returns the written value.
pub fn doSet(tx: *LockingTransaction, ref: *Ref, val: Value) !Value {
    try tx.vals.put(tx.gpa, ref, val);
    try tx.sets.put(tx.gpa, ref, {});
    return val;
}

/// `(commute r f & args)` — record the commute for replay at commit, then apply
/// `f` optimistically against the in-txn value and return that. The recorded
/// `f` is re-applied against the COMMITTED value at commit time, so a commuted
/// ref never conflicts (no retry under contention — `f` must be commutative,
/// the user's contract). Returns the optimistic value (clj `Ref.commute`).
pub fn doCommute(rt: *Runtime, env: *Env, tx: *LockingTransaction, ref: *Ref, func: Value, args: []const Value, loc: SourceLocation) !Value {
    if (args.len > MAX_COMMUTE_ARGS)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "commute with more than 7 extra args" });
    var entry: CommuteEntry = .{ .ref = ref, .func = func, .args_len = @intCast(args.len) };
    @memcpy(entry.args[0..args.len], args);
    try tx.commutes.append(tx.gpa, entry);
    const newval = try invokeCommute(rt, env, func, doGet(tx, ref), args, loc);
    try tx.vals.put(tx.gpa, ref, newval);
    return newval;
}

/// `(ensure r)` — read-lock r for this transaction: at commit it is locked +
/// read-point-conflict-checked (so no peer writes it under us — write-skew
/// prevention) but NOT written. Returns r's in-transaction value (clj `doEnsure`).
pub fn doEnsure(tx: *LockingTransaction, ref: *Ref) !Value {
    try tx.ensures.put(tx.gpa, ref, {});
    return doGet(tx, ref);
}

/// Call `(func cur & args)`.
fn invokeCommute(rt: *Runtime, env: *Env, func: Value, cur: Value, args: []const Value, loc: SourceLocation) !Value {
    const vtable = rt.vtable orelse return error.InternalError;
    var buf: [MAX_COMMUTE_ARGS + 1]Value = undefined;
    buf[0] = cur;
    @memcpy(buf[1 .. 1 + args.len], args);
    return vtable.callFn(rt, env, func, buf[0 .. 1 + args.len], loc);
}

/// Commit (#5-ii — multi-ref atomic): acquire EVERY written Ref's lock in
/// ascending-id order (a total order → concurrent multi-ref transactions can
/// never deadlock), check each ref's read-point conflict under its lock, then —
/// only once all are locked + validated — stamp one commit-point and write
/// every TVal, releasing all locks (LIFO) on exit. A conflict (a peer committed
/// a newer version after our snapshot) returns `error.StmRetry` to re-run the
/// whole transaction (retry-only, no barge — AD-013).
fn commit(rt: *Runtime, env: *Env, tx: *LockingTransaction, loc: SourceLocation) !void {
    // Lock set = written (`sets`) ∪ commuted ∪ ensured refs, DISTINCT.
    var locked: std.ArrayList(*Ref) = .empty;
    defer locked.deinit(tx.gpa);
    var sit = tx.sets.keyIterator();
    while (sit.next()) |rp| try locked.append(tx.gpa, rp.*);
    for (tx.commutes.items) |c| {
        if (!containsRef(locked.items, c.ref)) try locked.append(tx.gpa, c.ref);
    }
    var eit = tx.ensures.keyIterator();
    while (eit.next()) |rp| {
        if (!containsRef(locked.items, rp.*)) try locked.append(tx.gpa, rp.*);
    }
    std.mem.sort(*Ref, locked.items, {}, refIdLess);

    // Acquire all locks in id order (deadlock-free). Conflict-check the WRITTEN
    // and ENSURED refs (a peer commit after our snapshot is a conflict); a
    // commuted ref re-applies against the committed value below, so it never
    // conflicts (and never forces a retry under contention).
    var held: usize = 0;
    defer {
        while (held > 0) {
            held -= 1;
            locked.items[held].lock.unlock();
        }
    }
    for (locked.items) |ref| {
        while (!ref.lock.tryLock()) {
            // Same safepoint-yield as doGet: the commit-time lock acquisition must
            // not starve a pending collect.
            if (safepoint.gc_requested.load(.acquire)) safepoint.park();
            std.atomic.spinLoopHint();
        }
        held += 1;
        if ((tx.sets.contains(ref) or tx.ensures.contains(ref)) and ref.tvals.point > tx.read_point)
            return error.StmRetry;
    }

    // Replay commutes against the now-locked COMMITTED values (order-independent):
    // re-seed each commuted ref to its committed value, then chain its fns.
    for (tx.commutes.items) |c| try tx.vals.put(tx.gpa, c.ref, c.ref.tvals.val);
    for (tx.commutes.items) |c| {
        const newval = try invokeCommute(rt, env, c.func, tx.vals.get(c.ref).?, c.args[0..c.args_len], loc);
        try tx.vals.put(tx.gpa, c.ref, newval);
    }

    // All locked + validated + replayed → write every WRITTEN ref under one
    // commit-point. An ensure-only ref is locked + checked but not in `vals`, so
    // it is skipped here (read-locked, not written).
    // Validate every WRITTEN ref's proposed value against its validator BEFORE
    // any splice (clj `Ref.validate` in the commit loop). A falsey/throwing
    // validator returns `error.ThrownValue` here, which the `defer` above
    // releases all held locks for and aborts the transaction with NO ring
    // written — so the rejected `dosync` leaves every ref unchanged. Done in a
    // separate pre-pass so a later ref's rejection never half-writes an earlier
    // ref's ring (all-or-nothing commit).
    for (locked.items) |ref| {
        if (tx.vals.get(ref)) |v| {
            if (!ref.validator.isNil()) try iref.validateOrThrow(rt, env, ref.validator, v);
        }
    }

    const commit_point = nextPoint();
    for (locked.items) |ref| {
        if (tx.vals.get(ref)) |v| {
            // Capture (ref, old, new) for a watched ref BEFORE the splice (which
            // can recycle the prior `tvals.val` out of the ring). Fired post-commit.
            if (!ref.watches.isNil()) {
                try tx.notifies.append(tx.gpa, Value.encodeHeapPtr(.ref, ref));
                try tx.notifies.append(tx.gpa, ref.tvals.val);
                try tx.notifies.append(tx.gpa, v);
            }
            try spliceCommit(rt, ref, v, commit_point);
        }
    }
}

/// Fire watched-ref notifications collected during the commit write loop, once
/// per ref with the net `[pre-tx, post-tx]` change (JVM `LockingTransaction`).
/// The flat `[ref, old, new, ...]` list is published on an EvalFrame for the
/// whole loop: a watch fn re-enters the VM, and an already-fired `old` (recycled
/// out of the ring) would otherwise be swept before a later notification fires.
fn fireWatches(rt: *Runtime, env: *Env, tx: *LockingTransaction) !void {
    const items = tx.notifies.items;
    if (items.len == 0) return;
    var gc_sp: u16 = @intCast(items.len);
    var gc_frame: root_set.EvalFrame = .{ .stack = items.ptr, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var i: usize = 0;
    while (i < items.len) : (i += 3) {
        const ref_val = items[i];
        try iref.notifyWatches(rt, env, ref_val, ref_mod.watchesOf(ref_val), items[i + 1], items[i + 2]);
    }
}

fn containsRef(items: []const *Ref, ref: *Ref) bool {
    for (items) |r| if (r == ref) return true;
    return false;
}

fn refIdLess(_: void, a: *Ref, b: *Ref) bool {
    return a.id < b.id;
}

/// Write `newval@commit_point` into the ring per the JVM ring-growth rule
/// (`Ref.java`): splice a fresh TVal when history is wanted
/// (`faults>0 && hist<max` — #5-i has no faults yet — OR `hist<min`), else
/// recycle the oldest slot. With cljw's default `min_history==0`, #5-i always
/// recycles (a 1-node ring stays 1-node), so no unbounded ring growth.
fn spliceCommit(rt: *Runtime, ref: *Ref, newval: Value, commit_point: i64) !void {
    const hist_count = ringCount(ref.tvals);
    // faults are #5-iii (retry); treat as 0 here.
    const want_splice = hist_count < ref.min_history;
    if (want_splice) {
        const node = try rt.gc.alloc(TVal);
        node.* = .{
            .header = HeapHeader.init(.tval),
            .val = newval,
            .point = commit_point,
            .prior = ref.tvals,
            .next = ref.tvals.next,
        };
        ref.tvals.next.prior = node;
        ref.tvals.next = node;
        ref.tvals = node;
    } else {
        // Recycle the oldest slot (head.next), advance the head onto it.
        ref.tvals = ref.tvals.next;
        ref.tvals.val = newval;
        ref.tvals.point = commit_point;
    }
}

/// Count the nodes in a Ref's doubly-linked self-loop ring.
fn ringCount(head: *TVal) u32 {
    var n: u32 = 1;
    var t = head.next;
    while (t != head) : (t = t.next) n += 1;
    return n;
}

// --- tests ---

const testing = std.testing;

test "nextPoint is strictly monotonic" {
    const a = nextPoint();
    const b = nextPoint();
    try testing.expect(b > a);
}

test "ringCount on a fresh 1-node ring is 1" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const seed = try tval_mod.allocSelfLoop(&rt, Value.initInteger(0), 0, 0);
    try testing.expectEqual(@as(u32, 1), ringCount(seed));
}

test "doSet caches + doGet reads the in-txn write; commit recycles the ring head" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    const rv = try ref_mod.alloc(&rt, Value.initInteger(0));
    const ref: *Ref = @constCast(rv.decodePtr(*const Ref));

    var tx: LockingTransaction = .{ .read_point = nextPoint(), .gpa = rt.gpa };
    defer tx.vals.deinit(rt.gpa);
    defer tx.sets.deinit(rt.gpa);
    defer tx.commutes.deinit(rt.gpa);

    // Before any write, doGet reads the committed value.
    try testing.expectEqual(@as(i64, 0), doGet(&tx, ref).asInteger());
    _ = try doSet(&tx, ref, Value.initInteger(42));
    // The transaction sees its own write.
    try testing.expectEqual(@as(i64, 42), doGet(&tx, ref).asInteger());
    // Not yet committed — the ring head is unchanged.
    try testing.expectEqual(@as(i64, 0), ref.tvals.val.asInteger());

    try commit(&rt, &env, &tx, .{});
    // min_history==0 → recycled in place; the ring stays 1-node with the new value.
    try testing.expectEqual(@as(i64, 42), ref.tvals.val.asInteger());
    try testing.expectEqual(@as(u32, 1), ringCount(ref.tvals));
}
