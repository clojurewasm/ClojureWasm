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
const iref = @import("iref.zig");
const dispatch = @import("dispatch.zig");
const error_mod = @import("error/info.zig");
const lock_tx = @import("concurrency/lock_tx.zig");
const worker_error = @import("concurrency/worker_error.zig");
const promise_mod = @import("promise.zig");
const ex_info = @import("collection/ex_info.zig");

/// A queued unit of agent work: an action body + an optional completion promise.
/// `body` is the `[f & args]` action vector, or nil for a pure barrier (no state
/// change, used by `await`). `completion`, when non-nil, is a Promise the drainer
/// delivers AFTER the action stores its new state AND fires its watches — this is
/// what makes `(await a)` return only once the barrier action's own `notifyWatches`
/// has run (the `[s s]` no-op fire, clj-faithful), closing the deliver-in-body
/// race where the awaiter could wake before that watch fired (D-368, ADR-0093 am1).
const Action = struct {
    body: Value,
    completion: Value = .nil_val,
};

/// Off-heap control block: the queue mutex, the single-drainer flag, and the
/// pending actions. Held on `rt.gpa` (stable address), freed by the finaliser.
/// `actions[head..]` are the live pending actions (FIFO); `head` advances on pop
/// and resets to 0 once drained, so the list does not grow unboundedly.
const AgentCell = struct {
    mutex: std.Io.Mutex = .init,
    draining: bool = false,
    actions: std.ArrayList(Action) = .empty,
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
    /// Watch map `{key -> fn}` (`add-watch` / `remove-watch`), or nil. An IRef
    /// watch fires `(fn key agent old new)` after each action stores a new state.
    watches: Value = .nil_val,
    /// Validator fn (`nil` or a fn), `(agent init :validator f)` / `set-validator!`.
    /// Run by the drainer against each action's new state BEFORE the store; a
    /// falsey return (or a throw) fails the agent like any action error (D-441).
    validator: Value = .nil_val,
    /// Error handler `(fn [agent exception])`, or nil (`:error-handler` ctor /
    /// `set-error-handler!`). The drainer calls it on an action error (in BOTH
    /// modes), before the `:fail`/`:continue` decision — clj `Agent` (D-441).
    error_handler: Value = .nil_val,
    /// `^meta` / `reset-meta!` / `alter-meta!` metadata (nil or a map). Set at
    /// construction (`(agent init :meta m)`) or via `reset-meta!` (D-441 / D-239).
    meta: Value = .nil_val,
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

/// The agent's watch map (`nil` or a persistent `{key -> fn}`). IRef surface.
pub fn watchesOf(v: Value) Value {
    return v.decodePtr(*const Agent).watches;
}

/// Replace the agent's watch map (`add-watch` / `remove-watch`). The drainer is
/// the only state writer; the map pointer is swapped under no lock (a racing
/// add-watch and a drain just see slightly stale watch sets, as on the JVM).
pub fn setWatches(v: Value, m: Value) void {
    v.decodePtr(*Agent).watches = m;
}

/// The agent's validator fn (`nil` or a fn). IRef surface (D-441).
pub fn validatorOf(v: Value) Value {
    return v.decodePtr(*const Agent).validator;
}

/// Replace the agent's validator (`set-validator!` / ctor). The drainer is the
/// sole state writer; the fn pointer is swapped under no lock (a racing
/// set-validator! and a drain just see a slightly stale validator, as on the JVM).
pub fn setValidator(v: Value, f: Value) void {
    v.decodePtr(*Agent).validator = f;
}

/// The agent's metadata (`nil` or a map). `meta` / `reset-meta!` (D-441).
pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const Agent).meta;
}

/// Replace the agent's metadata (`reset-meta!` / `alter-meta!` / ctor).
pub fn setMeta(v: Value, m: Value) void {
    v.decodePtr(*Agent).meta = m;
}

/// The agent's error handler `(fn [agent ex])`, or nil. `(get-error-handler a)`.
pub fn errorHandlerOf(v: Value) Value {
    return v.decodePtr(*const Agent).error_handler;
}

/// Replace the agent's error handler (`set-error-handler!` / ctor).
pub fn setErrorHandler(v: Value, f: Value) void {
    v.decodePtr(*Agent).error_handler = f;
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
    try enqueueAction(rt, agent_val, .{ .body = action });
}

/// `(await a)`'s engine half: enqueue a pure barrier (no state change) whose
/// `completion` promise the drainer delivers AFTER the barrier's `notifyWatches`.
/// `await` blocks on that promise, so it returns only once the barrier action's
/// own watch fire (`[s s]`, clj-faithful) has run — closing the race where the
/// awaiter woke before the fire (the in-body `(deliver p s)` did, D-368).
pub fn sendAwait(rt: *Runtime, agent_val: Value, completion: Value) !void {
    try enqueueAction(rt, agent_val, .{ .body = .nil_val, .completion = completion });
}

/// A nested send held during an action's run: its target agent + the action.
const PendingSend = struct { agent: Value, action: Action };

/// clj's `nested` ThreadLocal (Agent.java): non-null while THIS thread is running
/// an agent action, collecting sends made DURING the action so they are dispatched
/// AFTER it completes (`releasePendingSends`), not immediately. Without this, a
/// nested `(send a …)` races a concurrently-enqueued `(await a)` barrier: the
/// barrier is queued before the nested send (clj-faithful → state-at-await) only
/// if the nested send is deferred. cljw enqueued nested sends immediately, so the
/// await ordering was timing-dependent (Mac vs ubuntunote) — D-388. Held Values
/// are `gc.pin`'d: the list is off-heap (gpa), invisible to the mark phase.
threadlocal var nested_pending: ?std.ArrayList(PendingSend) = null;

fn pinAction(rt: *Runtime, action: Action) !void {
    if (!action.body.isNil()) try rt.gc.pin(action.body);
    errdefer if (!action.body.isNil()) {
        _ = rt.gc.unpin(action.body);
    };
    if (!action.completion.isNil()) try rt.gc.pin(action.completion);
}

fn unpinAction(rt: *Runtime, action: Action) void {
    if (!action.body.isNil()) _ = rt.gc.unpin(action.body);
    if (!action.completion.isNil()) _ = rt.gc.unpin(action.completion);
}

/// Dispatch entry. If THIS thread is mid-action (`nested_pending != null`), HOLD
/// the send (clj `dispatchAction` nested branch); else enqueue it for real.
fn enqueueAction(rt: *Runtime, agent_val: Value, action: Action) !void {
    if (nested_pending) |*list| {
        try rt.gc.pin(agent_val);
        errdefer _ = rt.gc.unpin(agent_val);
        try pinAction(rt, action);
        errdefer unpinAction(rt, action);
        try list.append(rt.gpa, .{ .agent = agent_val, .action = action });
        return;
    }
    return enqueueDirect(rt, agent_val, action);
}

/// Dispatch the sends collected during the just-run action (clj
/// `releasePendingSends`), then clear the capture. Clears `nested_pending` FIRST
/// so the released sends enqueue for real (not re-held). Best-effort: an
/// enqueue that OOMs / fails to spawn a drainer drops that nested send (the held
/// Values are unpinned regardless, so no leak).
fn releasePendingSends(rt: *Runtime) void {
    var list = nested_pending orelse return;
    nested_pending = null;
    for (list.items) |ps| {
        enqueueDirect(rt, ps.agent, ps.action) catch {};
        unpinAction(rt, ps.action);
        _ = rt.gc.unpin(ps.agent);
    }
    list.deinit(rt.gpa);
}

/// `(release-pending-sends)` — flush the sends held during the CURRENT action
/// NOW (clj `Agent.releasePendingSends`), returning the count dispatched. The
/// capture is re-armed to empty so subsequent in-action sends stay held (clj
/// resets `nested` to an empty vector — NOT null, which would end the action's
/// hold). Returns 0 when not inside an action (`nested_pending == null`). Runs on
/// the drainer thread (the only thread where `nested_pending` is non-null).
pub fn releasePending(rt: *Runtime) usize {
    var list = nested_pending orelse return 0;
    const n = list.items.len;
    for (list.items) |ps| {
        enqueueDirect(rt, ps.agent, ps.action) catch {};
        unpinAction(rt, ps.action);
        _ = rt.gc.unpin(ps.agent);
    }
    list.deinit(rt.gpa);
    nested_pending = .empty; // re-arm: still inside the action, keep holding.
    return n;
}

/// Process-global agent-system shutdown flag (clj `Agent.shutdown` shuts the
/// static executor pools). Once set, `enqueueDirect` DROPS new dispatches.
/// Irreversible + process-wide, matching clj. Detached drainers already don't
/// block process exit, so the "running actions complete, no new ones accepted"
/// semantic holds without touching the in-flight drainers (ADR-0155 / D-442).
var agents_shut_down = std.atomic.Value(bool).init(false);

/// `(shutdown-agents)` — flip the process-global shutdown flag so subsequent
/// dispatches are dropped (clj `Agent.shutdown`). See `enqueueDirect`'s drop.
pub fn shutdownAgents() void {
    agents_shut_down.store(true, .release);
}

/// Enqueue an action under `cell.mutex` (leaf lock — gpa push only) and, if no
/// drainer is live, spawn one. The mutex is never held across `callFn` / a park.
fn enqueueDirect(rt: *Runtime, agent_val: Value, action: Action) !void {
    // After `shutdown-agents`, a new dispatch is DROPPED — `send` still returns
    // the agent, no throw, state unchanged (clj-faithful: clj's executor rejects
    // the submit and `Action.execute` swallows the RejectedExecutionException).
    // This is the documented terminal no-op ("no new actions accepted"), NOT a
    // forbidden silent semantic drop — an audited exception to
    // permanent_no_op_forbidden (ADR-0155 / AD-046). The narrow divergence: clj
    // routes the swallowed rejection to an agent's :error-handler; cljw has no
    // RejectedExecutionException to synthesize, so it just drops (AD-046).
    if (agents_shut_down.load(.acquire)) return;
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
        // Publish this drainer's STM transaction (an action may run a `dosync`)
        // so it is GC-rooted during a collect (#4a' in-txn-map rooting).
        .tx_slot = @ptrCast(&lock_tx.current_tx),
    };
    // Must NOT drain while unregistered: an unregistered worker's operand stack
    // is invisible to the mark phase, so a concurrent collect (when auto-collect
    // turns ON) would sweep objects live only on this thread → use-after-free. On
    // registration failure (worker table full), release the drainer slot + unpin;
    // the queued actions stay for the next send-triggered drainer.
    root_set.registerThread(&ctx) catch {
        io_default.lockMutex(&a.cell.mutex);
        a.cell.draining = false;
        io_default.unlockMutex(&a.cell.mutex);
        _ = a.rt.gc.unpin(agent_val);
        return;
    };
    defer root_set.unregisterThread(&ctx);

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
            // clj: the error handler (if set) runs on an action error in BOTH
            // modes, before the fail/continue decision; its own throw is dropped.
            runErrorHandler(a, agent_val, thrown);
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
            // :continue — state unchanged, keep draining.
        };
    }
}

/// Capture the action's error as a Value on the drainer's own thread. The
/// threadlocal error state was cleared before the action ran, so a non-null
/// `last_thrown_exception` is THIS action's explicit `(throw v)` / ex-info value;
/// otherwise synthesize an exception from the catalog Info the raise just set.
/// (Precise cross-thread error identity beyond this is the future-shared D-115.)
/// Run the agent's error handler `(fn [agent ex])` after an action error, if set
/// (clj `Agent` dispatch loop). Best-effort: it runs user code on the drainer
/// thread (vt.callFn), and a throw from the handler itself is swallowed (clj
/// wraps the handler call in `try/catch(Throwable){}`). `agent_val` + `thrown`
/// are published on an EvalFrame so the handler's VM re-entry cannot sweep them.
fn runErrorHandler(a: *Agent, agent_val: Value, thrown: Value) void {
    const h = a.error_handler;
    if (h.isNil()) return;
    const vt = a.rt.vtable orelse return;
    var gc_roots: [3]Value = .{ agent_val, thrown, h };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    _ = vt.callFn(a.rt, a.env, h, &[_]Value{ agent_val, thrown }, .{}) catch {};
}

fn captureThrown(a: *Agent) Value {
    // ADR-0120: the uniform worker-error marshal — a catalog error now carries
    // its KIND-DERIVED class (was hardcoded "ExceptionInfo", so `(agent-error a)`
    // around `(/ 1 0)` mis-reported the class) + its source location.
    return worker_error.capture(a.rt);
}

/// Validate an action's proposed new state against the agent's validator BEFORE
/// the store (clj `Agent.setState` → `validate`). A falsey return throws
/// IllegalStateException "Invalid reference state"; a validator that itself
/// throws propagates as-is. Either way the drainer's catch fails the agent
/// (`:fail` mode) — matching clj's validator-failure → agent-error path (D-441).
/// Runs on the drainer thread, so it uses the Runtime vtable `callFn` (the
/// Layer-2 `invokeCallable` is unreachable here), like `iref.notifyWatches`.
fn validateState(a: *Agent, newstate: Value) !void {
    if (a.validator.isNil()) return;
    const vt = a.rt.vtable orelse return error.InternalError;
    // GC-ROOT: `newstate` lives only as a Zig local across the validator's VM
    // re-entry; publish it on an EvalFrame so a collect mid-validate cannot
    // sweep it [ref: .dev/gc_rooting.md §C].
    var gc_roots: [1]Value = .{newstate};
    var gc_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const ok = try vt.callFn(a.rt, a.env, a.validator, &[_]Value{newstate}, .{});
    if (!ok.isTruthy()) {
        dispatch.last_thrown_exception = try ex_info.allocException(a.rt, "Invalid reference state", "IllegalStateException");
        return error.ThrownValue;
    }
}

/// Run one queued unit: `(apply f state args...)` and store the new state, then
/// fire watches, then deliver any completion promise. `action.body` is the
/// `[f & args]` vector, or nil for a pure `await` barrier (state unchanged — the
/// barrier exists only to fire its no-op `[s s]` watch + deliver `completion`).
fn runAction(a: *Agent, action: Action) !void {
    const oldstate = @atomicLoad(Value, &a.state, .acquire);
    var newstate = oldstate;
    // Bind `*agent*` to this agent for the whole action (body fn + its watches),
    // mirroring clj's `binding [*agent* a]` conveyed to the worker (ADR-0155 /
    // D-442). The frame's bound value is GC-rooted via the drainer's
    // `current_frame` slot in its ThreadGcContext, so a collect mid-action cannot
    // sweep it. No-op before bootstrap interns the Var (`agent_var == null`).
    var agent_frame: env_mod.BindingFrame = .{};
    defer agent_frame.bindings.deinit(a.rt.gpa);
    var agent_pushed = false;
    // popFrame keys on `agent_pushed`, not on `agent_var != null`: if the `put`
    // below OOMs BEFORE `pushFrame`, the frame was never pushed, so we must not
    // pop (that would corrupt the chain). deinit (declared first → runs last)
    // safely frees a partial/empty map.
    defer if (agent_pushed) env_mod.popFrame();
    if (a.rt.agent_var) |p| {
        const agent_val = Value.encodeHeapPtr(.agent, a);
        try agent_frame.bindings.put(a.rt.gpa, @as(*const env_mod.Var, @ptrCast(@alignCast(p))), agent_val);
        env_mod.pushFrame(&agent_frame);
        agent_pushed = true;
    }
    // clj-style nested-send capture (Agent.java `nested` + `releasePendingSends`):
    // sends made DURING this action (incl. from watch fns) are held + dispatched
    // AFTER it completes, so a concurrently-enqueued `(await)` barrier orders
    // before them — makes the await state clj-faithful + deterministic (D-388).
    nested_pending = .empty;
    defer releasePendingSends(a.rt);
    if (!action.body.isNil()) {
        const vt = a.rt.vtable orelse return error.InternalError;
        const n = vector.count(action.body);
        if (n != 0) { // send always builds [f & args], n >= 1
            const f = vector.nth(action.body, 0);
            var call_args: std.ArrayList(Value) = .empty;
            defer call_args.deinit(a.rt.gpa);
            try call_args.append(a.rt.gpa, oldstate);
            var i: u32 = 1;
            while (i < n) : (i += 1) try call_args.append(a.rt.gpa, vector.nth(action.body, i));
            newstate = try vt.callFn(a.rt, a.env, f, call_args.items, .{});
            // clj validates the new state before committing; a rejection fails
            // the agent (the drainer's catch records it in :fail mode). D-441.
            try validateState(a, newstate);
        }
    }
    @atomicStore(Value, &a.state, newstate, .release);
    try notifyWatches(a, oldstate, newstate);
    // Deliver an await barrier's completion promise AFTER the watch fire above,
    // so `(await a)` is released only once this action's `notifyWatches` ran
    // (the deliver-in-body race fix, D-368).
    if (!action.completion.isNil()) _ = promise_mod.deliver(action.completion, newstate);
}

/// Fire each registered watch `(fn key agent old new)` after an action stores a
/// new state (JVM `ARef.notifyWatches`), via the shared Layer-0 `iref` helper.
fn notifyWatches(a: *Agent, old: Value, new: Value) !void {
    const agent_val = Value.encodeHeapPtr(.agent, a);
    try iref.notifyWatches(a.rt, a.env, agent_val, a.watches, old, new);
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
    if (a.watches.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (a.validator.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (a.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (a.error_handler.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    for (a.cell.actions.items[a.cell.head..]) |action| {
        if (action.body.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
        if (action.completion.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
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
