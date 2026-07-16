// SPDX-License-Identifier: EPL-2.0
//! Thread — the minimal user-thread lifecycle behind `(Thread. f)` /
//! `.start` / `.join` / `.isAlive` / names / daemon (ADR-0174 D6; the
//! user-authorized F-014 exception, 2026-07-16).
//!
//! A Thread value is a `.host_instance` carrying a `*ThreadState`
//! (state[0]) and the ONE canonical `rt.types["java.lang.Thread"]`
//! descriptor (ADR-0174 merge — statics like `Thread/sleep` and these
//! instance methods share it, and `(class t)` / `instance?` agree).
//! `.start` mirrors future.zig's worker discipline exactly: a REAL
//! detached `std.Thread` that registers a `ThreadGcContext` (its roots
//! are walked by a concurrent collect), runs the thunk on the VM via
//! `vtable.callFn`, and holds a `gc.pin` on the Thread value for the
//! worker's lifetime.
//!
//! **Non-daemon default is JVM-faithful** (the DA-flagged divergence a
//! silently-detached thread would ship): every started non-daemon
//! Thread lands in the per-Runtime join-at-exit registry, and the app
//! entry (`cli.zig`) calls `joinAllNonDaemon` after the program body —
//! main waits, exactly like the JVM. `setDaemon(true)` before `.start`
//! opts out (the thread dies with the process). The interrupt family is
//! deliberately NOT here: a flag-only interrupt that cannot wake a
//! sleeping thread would be a semantic lie (permanent-no-op rule) — the
//! D3 member diagnostic renders the honest error instead.
//!
//! Per F-009 the implementation is namespace-neutral; the Java surface
//! (`runtime/java/lang/Thread.zig`) wires it from above.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const env_mod = @import("env.zig");
const root_set = @import("gc/root_set.zig");
const io_default = @import("concurrency/io_default.zig");
const lock_tx = @import("concurrency/lock_tx.zig");
const host_instance = @import("host_instance.zig");
const worker_error = @import("concurrency/worker_error.zig");
const error_catalog = @import("error/catalog.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;

pub const FQCN = "java.lang.Thread";

pub const RunState = enum(u8) { unstarted = 0, running = 1, done = 2 };

/// The blocking join cell (mutex + condition), `rt.gpa`-allocated at
/// construction, freed by the host_instance finaliser. Same shape as
/// future.zig's FutureCell.
const ThreadCell = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
};

/// Per-Thread state, `gc.infra`-allocated, freed by the finaliser. The
/// thunk is a live GC edge while the thread has not finished — traced via
/// the descriptor's `host_trace` hook (`traceState`).
pub const ThreadState = struct {
    /// The 0-arg fn `.start` runs. Cleared to nil when done (drops the edge).
    thunk: Value,
    /// Thread name — `gc.infra`-duped ("Thread-N" auto or ctor/setName).
    name: []u8,
    /// Lifecycle; read/written under `cell.mutex`.
    run_state: RunState = .unstarted,
    daemon: bool = false,
    cell: *ThreadCell,
    /// Back-pointer for the worker (unpin + rt access).
    rt: *Runtime,
    env: *Env,
};

/// The Thread object the CURRENT OS thread is running as: set by `worker`
/// for started Threads; nil on main and non-Thread workers (future/agent
/// workers and the main thread fall back to the "main" singleton).
pub threadlocal var current_thread_val: Value = .nil_val;

/// Auto-name counter ("Thread-0", "Thread-1", …) — process-global like
/// the JVM's, atomic (Threads can be minted from worker threads).
var auto_name_counter: std.atomic.Value(u32) = .init(0);

fn stateOf(v: Value) *ThreadState {
    return @ptrFromInt(host_instance.asHostInstance(v).state[0]);
}

/// `host_trace` hook: the thunk is a live edge until the worker clears it.
pub fn traceState(gc_ptr: *anyopaque, state: *[4]u64) void {
    const st: *ThreadState = @ptrFromInt(state[0]);
    const gc: *@import("gc/gc_heap.zig").GcHeap = @ptrCast(@alignCast(gc_ptr));
    const mark_sweep = @import("gc/mark_sweep.zig");
    if (st.thunk.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// `host_finalise` hook: free the state + name + cell. A running thread's
/// value is pinned, so finalisation only reaches unstarted/done Threads.
pub fn finaliseState(infra: std.mem.Allocator, state: *[4]u64) void {
    const st: *ThreadState = @ptrFromInt(state[0]);
    infra.free(st.name);
    // The cell is gpa-allocated; infra == gpa backing per F-006 (the same
    // equivalence runtime.zig's deinit relies on for rt.types tables).
    infra.destroy(st.cell);
    infra.destroy(st);
}

/// `(Thread. f)` / `(Thread. f name)` — mint an unstarted Thread over the
/// 0-arg fn `f`. `descriptor` is the canonical rt.types Thread descriptor
/// (passed by the surface so this impl needs no registry lookup).
pub fn make(rt: *Runtime, env: *Env, thunk: Value, name: ?[]const u8, descriptor: *const @import("type_descriptor.zig").TypeDescriptor) !Value {
    const cell = try rt.gpa.create(ThreadCell);
    cell.* = .{};
    errdefer rt.gpa.destroy(cell);
    const owned_name = if (name) |n|
        try rt.gc.infra.dupe(u8, n)
    else blk: {
        const id = auto_name_counter.fetchAdd(1, .monotonic);
        break :blk try std.fmt.allocPrint(rt.gc.infra, "Thread-{d}", .{id});
    };
    errdefer rt.gc.infra.free(owned_name);
    const st = try rt.gc.infra.create(ThreadState);
    st.* = .{ .thunk = thunk, .name = owned_name, .cell = cell, .rt = rt, .env = env };
    return host_instance.alloc(rt, descriptor, .{ @intFromPtr(st), 0, 0, 0 });
}

pub fn isThread(v: Value) bool {
    if (v.tag() != .host_instance) return false;
    const fq = host_instance.asHostInstance(v).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// `.start` — spawn the detached worker. Second start (or start of a
/// finished thread) raises the IllegalThreadState-shaped error, JVM-exact.
pub fn start(rt: *Runtime, thread_val: Value, loc: SourceLocation) !Value {
    const st = stateOf(thread_val);
    io_default.lockMutex(&st.cell.mutex);
    if (st.run_state != .unstarted) {
        io_default.unlockMutex(&st.cell.mutex);
        return error_catalog.raise(.thread_already_started, loc, .{ .op = "start" });
    }
    st.run_state = .running;
    io_default.unlockMutex(&st.cell.mutex);

    // Pin: the worker writes to the Thread value after main may have
    // dropped every reference (fire-and-forget start) — future.zig's rule.
    try rt.gc.pin(thread_val);
    if (!st.daemon) try registerNonDaemon(rt, thread_val);
    var t = std.Thread.spawn(.{}, worker, .{thread_val}) catch |e| {
        io_default.lockMutex(&st.cell.mutex);
        st.run_state = .done;
        io_default.unlockMutex(&st.cell.mutex);
        _ = rt.gc.unpin(thread_val);
        return e;
    };
    t.detach();
    return Value.nil_val;
}

/// Worker body — future.zig's discipline: publish GC roots, run the thunk
/// on the VM, mark done + wake joiners, drop the thunk edge, unpin.
fn worker(thread_val: Value) void {
    const st = stateOf(thread_val);
    var ctx: root_set.ThreadGcContext = .{
        .frame_slot = &env_mod.current_frame,
        .analysis_frame_slot = &root_set.analysis_frame_head,
        .eval_frame_slot = &root_set.eval_frame_head,
        .self_guard_slot = &root_set.gc_self_guard,
        .tx_slot = @ptrCast(&lock_tx.current_tx),
    };
    const registered = if (root_set.registerThread(&ctx)) |_| true else |_| false;
    defer if (registered) root_set.unregisterThread(&ctx);

    current_thread_val = thread_val;
    defer current_thread_val = .nil_val;

    if (st.rt.vtable) |vt| {
        if (vt.callFn(st.rt, st.env, st.thunk, &.{}, .{})) |_| {
            // A thread's return value is discarded (JVM Runnable.run is void).
        } else |_| {
            // JVM: an exception escaping run() goes to the uncaught-exception
            // handler (default: a stderr trace) and the thread dies. Render
            // the captured error to stderr — never silently swallow.
            reportUncaught(st);
        }
    }

    io_default.lockMutex(&st.cell.mutex);
    st.run_state = .done;
    st.thunk = .nil_val; // drop the GC edge; traceState sees nil from now on
    io_default.condBroadcast(&st.cell.cond);
    io_default.unlockMutex(&st.cell.mutex);
    _ = st.rt.gc.unpin(thread_val);
}

/// Default uncaught-exception behaviour (JVM parity): one stderr line
/// naming the thread + the error's display text.
fn reportUncaught(st: *ThreadState) void {
    const msg = worker_error.capture(st.rt);
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(st.rt.io, &buf);
    const w = &fw.interface;
    w.print("Exception in thread \"{s}\" ", .{st.name}) catch return;
    const print_mod = @import("print.zig");
    print_mod.printValue(w, msg) catch {};
    w.writeByte('\n') catch {};
    w.flush() catch {};
}

/// `.join` — block until done. `timeout_ms` null = indefinite (condition
/// wait); a timeout polls in slices (no timed condwait in io_default) and
/// returns when the deadline passes with the thread still alive (JVM
/// join(ms) semantics: returns, caller re-checks isAlive).
pub fn join(thread_val: Value, timeout_ms: ?i64) void {
    const st = stateOf(thread_val);
    if (timeout_ms) |ms| {
        if (ms <= 0) return;
        const slice_ns: u64 = 5 * std.time.ns_per_ms;
        var remaining: u64 = @as(u64, @intCast(ms)) * std.time.ns_per_ms;
        while (remaining > 0) {
            if (runState(thread_val) == .done) return;
            const this_slice = @min(remaining, slice_ns);
            io_default.sleep(this_slice);
            remaining -= this_slice;
        }
        return;
    }
    io_default.lockMutex(&st.cell.mutex);
    defer io_default.unlockMutex(&st.cell.mutex);
    while (st.run_state != .done) {
        io_default.condWait(&st.cell.cond, &st.cell.mutex);
    }
}

pub fn runState(thread_val: Value) RunState {
    const st = stateOf(thread_val);
    io_default.lockMutex(&st.cell.mutex);
    defer io_default.unlockMutex(&st.cell.mutex);
    return st.run_state;
}

pub fn nameOf(thread_val: Value) []const u8 {
    return stateOf(thread_val).name;
}

/// `.setName` — replace the (infra-owned) name.
pub fn setName(rt: *Runtime, thread_val: Value, name: []const u8) !void {
    const st = stateOf(thread_val);
    const owned = try rt.gc.infra.dupe(u8, name);
    rt.gc.infra.free(st.name);
    st.name = owned;
}

pub fn isDaemon(thread_val: Value) bool {
    return stateOf(thread_val).daemon;
}

/// `.setDaemon` — only before `.start` (JVM IllegalThreadStateException
/// after), so the join-at-exit registry membership is settled at start.
pub fn setDaemon(thread_val: Value, daemon: bool, loc: SourceLocation) !Value {
    const st = stateOf(thread_val);
    io_default.lockMutex(&st.cell.mutex);
    defer io_default.unlockMutex(&st.cell.mutex);
    if (st.run_state != .unstarted)
        return error_catalog.raise(.thread_already_started, loc, .{ .op = "setDaemon" });
    st.daemon = daemon;
    return Value.nil_val;
}

// --- join-at-exit registry (non-daemon threads; JVM-faithful main wait) ---

fn registerNonDaemon(rt: *Runtime, thread_val: Value) !void {
    io_default.lockMutex(&rt.user_threads_mutex);
    defer io_default.unlockMutex(&rt.user_threads_mutex);
    try rt.user_threads.append(rt.gpa, thread_val);
}

/// Called by the app entry after the program body: wait for every live
/// non-daemon Thread (the JVM's main-exit rule). Entries are join'd in
/// registration order; a done thread's join returns immediately. Threads
/// STARTED BY the joined threads land in the registry too — loop until a
/// pass sees no new entries.
pub fn joinAllNonDaemon(rt: *Runtime) void {
    var i: usize = 0;
    while (true) {
        io_default.lockMutex(&rt.user_threads_mutex);
        const n = rt.user_threads.items.len;
        if (i >= n) {
            io_default.unlockMutex(&rt.user_threads_mutex);
            return;
        }
        const tv = rt.user_threads.items[i];
        io_default.unlockMutex(&rt.user_threads_mutex);
        join(tv, null);
        i += 1;
    }
}

// --- tests ---

const testing = std.testing;

test "auto-name counter yields distinct Thread-N names" {
    const a = auto_name_counter.fetchAdd(1, .monotonic);
    const b = auto_name_counter.fetchAdd(1, .monotonic);
    try testing.expect(a != b);
}
