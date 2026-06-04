// SPDX-License-Identifier: EPL-2.0
//! Agent — Tier A asynchronous, serially-executed state (Phase B #6, first slice).
//!
//! `(agent init)` holds a state Value updated only by ACTIONS dispatched with
//! `(send a f & args)` / `(send-off a f & args)`. Actions on one agent run
//! ONE-AT-A-TIME, in send order, on a worker thread; different agents run
//! concurrently. `@agent` is a non-blocking atomic read of the current state.
//! `(await a)` blocks until the actions sent so far have run (implemented in
//! core.clj as a sentinel action that delivers a promise — no new primitive).
//!
//! ## Serial execution — the single-drainer handoff
//! The thread that transitions the action queue empty→non-empty spawns the sole
//! drainer; the drainer processes actions until the queue empties, then exits.
//! `draining` is checked/set under `cell.mutex`, so the empty→non-empty handoff
//! is race-free: a `send` either sees `draining==true` (the live drainer will
//! pick its action up) or `draining==false` (it spawns a fresh drainer). The
//! drainer's "queue-empty test → clear draining → release mutex → return" is one
//! critical section, so an action can never be stranded with no live drainer.
//!
//! ## `cell.mutex` is a LEAF lock (the load-bearing GC invariant)
//! Under the stop-the-world collector (F-006), a thread BLOCKED on `cell.mutex`
//! is not at a safepoint, so if a collect armed while it blocked, `stopWorld`
//! would wait for a park that never comes. Therefore `cell.mutex` is held ONLY
//! across the gpa queue push/pop (which never allocates on the GC heap and never
//! parks) — NEVER across `callFn`, a GC allocation, or a park. The action vector
//! is built before the lock; the action runs after the unlock. (ADR-0093.)
//!
//! ## GC
//! The pending-action queue is an off-heap `gpa` list of action Values (a Value
//! PersistentQueue would `conj`-allocate on the GC heap under the mutex, breaking
//! the leaf-lock invariant). `traceGc` marks the state + every queued action, so
//! the queue is a root source the collector walks (mutators are parked during a
//! collect, so the list is quiescent while traced). The in-flight action mid-
//! `callFn` is rooted by the drainer's operand stack like a future thunk; the
//! fabrication window (a fresh action vector held only as a Zig local in `send`
//! before it is queued) rides the #4a' `gc_self_guard` hardening — dormant while
//! auto-collect is OFF, as today.
//!
//! Per F-009 the implementation is namespace-neutral.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const env_mod = @import("env.zig");
const root_set = @import("gc/root_set.zig");
const io_default = @import("concurrency/io_default.zig");
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");
const vector = @import("collection/vector.zig");
const dispatch = @import("dispatch.zig");
const error_mod = @import("error/info.zig");
const ex_info = @import("collection/ex_info.zig");

/// Off-heap control block: the queue mutex, the single-drainer flag, and the
/// pending actions. Held on `rt.gpa` (stable address), freed by the finaliser.
/// `actions[head..]` are the live pending actions (FIFO); `head` advances on pop
/// and resets to 0 once drained, so the list does not grow unboundedly.
const AgentCell = struct {
    mutex: std.Io.Mutex = .init,
    draining: bool = false,
    actions: std.ArrayList(Value) = .empty,
    head: usize = 0,
    /// Error mode: true = `:fail` (a thrown action halts the agent until
    /// `restart-agent`), false = `:continue` (a thrown action is dropped + the
    /// agent keeps draining). clj's default with no error-handler is `:fail`.
    fail_mode: bool = true,
};

pub const Agent = extern struct {
    header: HeapHeader,
    /// Current state. Read (`deref`) / written (drainer) atomically — the drainer
    /// is the sole writer (one per agent at a time), `@agent` the reader.
    state: Value = .nil_val,
    /// The error that failed the agent (`:fail` mode), or nil. Non-nil = FAILED:
    /// further `send`s throw until `restart-agent` clears it. Written by the
    /// drainer / `restart` under `cell.mutex`; read by `agent-error` under it.
    error_val: Value = .nil_val,
    rt: *Runtime,
    env: *Env,
    cell: *AgentCell,

    comptime {
        std.debug.assert(@alignOf(Agent) >= 8);
        std.debug.assert(@offsetOf(Agent, "header") == 0);
    }
};

/// `(agent init)` — construct an agent seeded with `init`, empty action queue.
pub fn alloc(rt: *Runtime, env: *Env, init: Value) !Value {
    const cell = try rt.gpa.create(AgentCell);
    cell.* = .{};
    const a = rt.gc.alloc(Agent) catch |e| {
        rt.gpa.destroy(cell);
        return e;
    };
    a.* = .{ .header = HeapHeader.init(.agent), .state = init, .rt = rt, .env = env, .cell = cell };
    return Value.encodeHeapPtr(.agent, a);
}

pub fn isAgent(v: Value) bool {
    return v.tag() == .agent;
}

/// `@agent` / `(deref a)` — non-blocking atomic read of the current state.
pub fn current(v: Value) Value {
    const a = v.decodePtr(*const Agent);
    return @atomicLoad(Value, &a.state, .acquire);
}

/// Dispatch an action (a `[f & args]` vector, already built on the GC heap) to
/// the agent. Enqueues under `cell.mutex` and, if no drainer is live, spawns one.
/// The mutex is held only across the gpa push (leaf-lock invariant).
pub fn send(rt: *Runtime, agent_val: Value, action: Value) !void {
    const a = agent_val.decodePtr(*Agent);
    io_default.lockMutex(&a.cell.mutex);
    if (!a.error_val.isNil()) {
        // Agent is in the failed state (`:fail` mode) — reject until restarted.
        io_default.unlockMutex(&a.cell.mutex);
        return error.AgentFailed;
    }
    a.cell.actions.append(rt.gpa, action) catch |e| {
        io_default.unlockMutex(&a.cell.mutex);
        return e;
    };
    const need_spawn = !a.cell.draining;
    if (need_spawn) a.cell.draining = true;
    io_default.unlockMutex(&a.cell.mutex);

    if (need_spawn) {
        // Keep the agent alive for the drainer even if the caller drops it.
        try rt.gc.pin(agent_val);
        var t = std.Thread.spawn(.{}, drainer, .{a}) catch |e| {
            io_default.lockMutex(&a.cell.mutex);
            a.cell.draining = false;
            io_default.unlockMutex(&a.cell.mutex);
            _ = rt.gc.unpin(agent_val);
            return e;
        };
        t.detach();
    }
}

/// Worker body: drain the action queue serially, then exit. Registers a
/// `ThreadGcContext` so a concurrent collect parks it at a safepoint and walks
/// its operand-stack roots (the in-flight action), like `future.worker`.
fn drainer(a: *Agent) void {
    const agent_val = Value.encodeHeapPtr(.agent, a);
    var ctx: root_set.ThreadGcContext = .{
        .frame_slot = &env_mod.current_frame,
        .macro_slot = &root_set.macro_root_slot,
        .eval_frame_slot = &root_set.eval_frame_head,
        .self_guard_slot = &root_set.gc_self_guard,
    };
    const registered = if (root_set.registerThread(&ctx)) |_| true else |_| false;
    defer if (registered) root_set.unregisterThread(&ctx);

    while (true) {
        // Pop the next action (or finish) under the leaf lock — no alloc, no park.
        io_default.lockMutex(&a.cell.mutex);
        if (a.cell.head >= a.cell.actions.items.len) {
            // Queue drained: clear the draining flag + reset the list in ONE
            // critical section so a concurrent `send` either spawns a fresh
            // drainer or was already seen above. Never split this section.
            a.cell.draining = false;
            a.cell.actions.clearRetainingCapacity();
            a.cell.head = 0;
            io_default.unlockMutex(&a.cell.mutex);
            _ = a.rt.gc.unpin(agent_val);
            return;
        }
        const action = a.cell.actions.items[a.cell.head];
        a.cell.head += 1;
        io_default.unlockMutex(&a.cell.mutex);

        // Clear the threadlocal error state so a stale throw from a prior action
        // is not misread as this action's error (op_throw sets
        // `last_thrown_exception`; a catalog raise sets `last_error`).
        dispatch.last_thrown_exception = null;
        dispatch.last_thrown_context = null;
        error_mod.clearLastError();

        // Run the action OUTSIDE the lock: (apply f state args...).
        runAction(a, action) catch {
            const thrown = captureThrown(a);
            io_default.lockMutex(&a.cell.mutex);
            const fail = a.cell.fail_mode;
            if (fail) {
                // :fail — record the error + HALT draining (the queue stays for
                // restart-agent). Cleared in ONE critical section so a peer send
                // sees the failed state under the same mutex.
                a.error_val = thrown;
                a.cell.draining = false;
            }
            io_default.unlockMutex(&a.cell.mutex);
            if (fail) {
                _ = a.rt.gc.unpin(agent_val);
                return;
            }
            // :continue — state unchanged, keep draining (handler is a follow-up).
        };
    }
}

/// Capture the action's error as a Value on the drainer's own thread. The
/// threadlocal error state was cleared before the action ran, so a non-null
/// `last_thrown_exception` is THIS action's explicit `(throw v)` / ex-info value;
/// otherwise synthesize an exception from the catalog Info the raise just set.
/// (Precise cross-thread error identity beyond this is the future-shared D-115.)
fn captureThrown(a: *Agent) Value {
    if (dispatch.last_thrown_exception) |tv| return tv;
    if (error_mod.peekLastError()) |info| {
        return ex_info.allocException(a.rt, info.message, "clojure.lang.ExceptionInfo") catch Value.nil_val;
    }
    return Value.nil_val;
}

/// `(apply f state args...)` and store the new state. `action` is `[f & args]`.
fn runAction(a: *Agent, action: Value) !void {
    const vt = a.rt.vtable orelse return error.InternalError;
    const n = vector.count(action);
    if (n == 0) return; // defensive — send always builds [f & args], n >= 1
    const f = vector.nth(action, 0);

    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(a.rt.gpa);
    try call_args.append(a.rt.gpa, @atomicLoad(Value, &a.state, .acquire));
    var i: u32 = 1;
    while (i < n) : (i += 1) try call_args.append(a.rt.gpa, vector.nth(action, i));

    const newstate = try vt.callFn(a.rt, a.env, f, call_args.items, .{});
    @atomicStore(Value, &a.state, newstate, .release);
}

/// `(agent-error a)` — the error that failed the agent (`:fail` mode), or nil.
pub fn agentError(v: Value) Value {
    const a = v.decodePtr(*const Agent);
    io_default.lockMutex(&a.cell.mutex);
    defer io_default.unlockMutex(&a.cell.mutex);
    return a.error_val;
}

/// `(restart-agent a new-state)` — clear the failure, set the state, and resume
/// draining any pending actions (`clear_actions` drops them instead, clj's
/// `:clear-actions true`).
pub fn restart(rt: *Runtime, agent_val: Value, new_state: Value, clear_actions: bool) !void {
    const a = agent_val.decodePtr(*Agent);
    io_default.lockMutex(&a.cell.mutex);
    a.error_val = .nil_val;
    @atomicStore(Value, &a.state, new_state, .release);
    if (clear_actions) {
        a.cell.actions.clearRetainingCapacity();
        a.cell.head = 0;
    }
    const need_spawn = (a.cell.head < a.cell.actions.items.len) and !a.cell.draining;
    if (need_spawn) a.cell.draining = true;
    io_default.unlockMutex(&a.cell.mutex);

    if (need_spawn) {
        try rt.gc.pin(agent_val);
        var t = std.Thread.spawn(.{}, drainer, .{a}) catch |e| {
            io_default.lockMutex(&a.cell.mutex);
            a.cell.draining = false;
            io_default.unlockMutex(&a.cell.mutex);
            _ = rt.gc.unpin(agent_val);
            return e;
        };
        t.detach();
    }
}

/// `(set-error-mode! a mode)` — true = `:fail`, false = `:continue`.
pub fn setFailMode(v: Value, fail: bool) void {
    const a = v.decodePtr(*Agent);
    io_default.lockMutex(&a.cell.mutex);
    defer io_default.unlockMutex(&a.cell.mutex);
    a.cell.fail_mode = fail;
}

/// `(error-mode a)` — true = `:fail`, false = `:continue`.
pub fn failMode(v: Value) bool {
    const a = v.decodePtr(*const Agent);
    io_default.lockMutex(&a.cell.mutex);
    defer io_default.unlockMutex(&a.cell.mutex);
    return a.cell.fail_mode;
}

pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const a: *Agent = @ptrCast(@alignCast(header));
    // Mutators are parked during a collect, so the state + error + the off-heap
    // action list are quiescent here (no concurrent send/drain).
    if (a.state.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (a.error_val.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    for (a.cell.actions.items[a.cell.head..]) |action| {
        if (action.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Free the off-heap cell when the Agent is swept. Reachable only when the Agent
/// is unreachable, so no drainer is live (the drainer unpins before exit). Frees
/// via `a.rt.gpa` — the same allocator `send` appended the action list with.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    _ = gc_ptr;
    const a: *Agent = @ptrCast(@alignCast(header));
    a.cell.actions.deinit(a.rt.gpa);
    a.rt.gpa.destroy(a.cell);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.agent, &traceGc);
    tag_ops.registerFinaliser(.agent, &finaliseGc);
}

const testing = std.testing;

test "Agent isAgent predicate" {
    try testing.expect(!isAgent(Value.initInteger(7)));
    try testing.expect(!isAgent(.nil_val));
}
