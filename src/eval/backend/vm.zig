// SPDX-License-Identifier: EPL-2.0
//! Bytecode VM dispatch loop — the default backend (F-012, ADR-0005);
//! TreeWalk is the differential oracle the VM is checked against.
//! `eval` consumes a `BytecodeChunk` produced by `vm/compiler.zig` and
//! executes its instructions against the per-thread operand arena
//! (`VmArena`, ADR-0131 2a), borrowing a region at `op_base` per invocation.
//!
//! Per ADR-0022 the VM must produce bit-for-bit identical Values to
//! TreeWalk for the same source. Errors raised here therefore reuse
//! TreeWalk's `error_catalog` Codes; control-flow signals
//! (`error.RecurSignaled`, `error.ThrownValue`) use the same Zig errors
//! so a shared try/loop driver works across backends.
//!
//! Dispatch shape is a single `switch (Opcode)`. Computed-goto is not
//! used; only the hot `op_const` / `op_ret` arms carry
//! `@branchHint(.likely)`.

const std = @import("std");
const node_mod = @import("../node.zig");
const loader = @import("../loader.zig");
const opcode_mod = @import("vm/opcode.zig");
const intrinsic = @import("intrinsic.zig");
const value_mod = @import("../../runtime/value/value.zig");
const env_mod = @import("../../runtime/env.zig");
const runtime_mod = @import("../../runtime/runtime.zig");
const string_mod = @import("../../runtime/collection/string.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const map_mod = @import("../../runtime/collection/map.zig");
const set_mod = @import("../../runtime/collection/set.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const mark_sweep = @import("../../runtime/gc/mark_sweep.zig");
const gc_torture = @import("../../runtime/gc/gc_torture.zig");
const safepoint = @import("../../runtime/concurrency/safepoint.zig");
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const host_class = @import("../../runtime/error/host_class.zig");
const tree_walk = @import("tree_walk.zig");
const ex_info_mod = @import("../../runtime/collection/ex_info.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const object_method = @import("object_method.zig");
const clojure_lang_method = @import("clojure_lang_method.zig");
const special_forms = @import("../analyzer/special_forms.zig");

const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const Value = value_mod.Value;
const Env = env_mod.Env;
const Var = env_mod.Var;
const Runtime = runtime_mod.Runtime;
const SourceLocation = error_mod.SourceLocation;
const Function = tree_walk.Function;

/// Per-frame exception-handler stack ceiling. Deep `try` nesting is
/// rare; oversize raises `internal_error`. Mirrors v1's `HANDLERS_MAX`
/// but per-call rather than VM-global (cw v2 dispatcher is single-frame
/// per `eval()` call).
pub const HANDLER_STACK_MAX: u16 = 32;

/// `.catch_clause` handlers intercept + convert + match (try/catch).
/// `.cleanup` handlers (binding / bare-try / finally-only) unwind like
/// TreeWalk's `defer`: they run cleanup bytecode then re-fire the
/// ORIGINAL error unchanged — no catalog→exception conversion, no
/// context mutation (ADR-0071).
const HandlerKind = enum { catch_clause, cleanup };

const Handler = struct {
    catch_ip: usize,
    saved_sp: u16,
    kind: HandlerKind,
};

/// ADR-0131 increment 2a: per-thread reusable VM operand arena. The operand
/// stack + its parallel loc stack move OFF the per-`eval` host C stack INTO this
/// shared heap arena, so increment 2b's flattened in-VM call frames can share one
/// operand region. Each `eval` borrows from the GLOBAL watermark `op_top` (its
/// operands live at `stack[op_base..op_top]`); a nested reentrant `eval` borrows
/// above it; `op_top` is restored to `op_base` on return. The live prefix
/// `stack[0..op_top]` is GC-rooted via the EvalFrame (A1). Allocated lazily on
/// first use, reused for the thread's life (never freed — matching the other
/// threadlocal call-scoped state in `dispatch.zig`). `ARENA_SLOTS` is sized so
/// `op_top` stays within `u16`, keeping `root_set.EvalFrame.sp` unchanged.
const ARENA_SLOTS: usize = 1 << 14; // 16384; keeps `op_top` within u16
/// ADR-0131 2b: in-VM call-frame stack ceiling. A flattened `op_call` pushes one
/// `VmFrame`; exceeding this → catchable `StackOverflow` (matches v0 + clj). The
/// operand arena (~8 slots/fib-frame) caps comparable depth, so the two align.
const FRAMES_MAX: usize = 2048;
/// The thread's reusable VM arenas: the operand stack + its parallel loc stack +
/// (2b) the flattened-call-frame locals arena + the in-VM frame stack, as inline
/// arrays so the storage is threadlocal STATIC (BSS, demand-paged) — nothing to
/// allocate or free (a never-freed heap arena leaks under the test
/// DebugAllocator). `op_top` is the global operand watermark; `local_top` /
/// `frame_top` are the locals-arena / frame-stack watermarks. Each `eval`
/// invocation borrows from all three watermarks and restores them on return.
const VmArena = struct {
    stack: [ARENA_SLOTS]Value = undefined,
    loc: [ARENA_SLOTS]SourceLocation = undefined,
    op_top: u16 = 0,
    /// Locals for FLATTENED frames (the base frame keeps caller-owned locals).
    local_arena: [ARENA_SLOTS]Value = undefined,
    local_top: u16 = 0,
    frames: [FRAMES_MAX]VmFrame = undefined,
    frame_top: u16 = 0,
};
threadlocal var vm_arena: VmArena = .{};

/// ADR-0131 2b: an in-VM call frame. A flattened `op_call` pushes one + continues
/// the SAME eval loop (no host `eval` re-entry); `op_ret` pops it. Each carries
/// its OWN `gc_frame`, pushed on the `eval_frame_head` chain at flatten + popped
/// at ret, so the collector's existing chain-walk roots every active frame's
/// locals + constants with NO `root_set` change (it cannot hold this vm-local
/// type — zone rule).
const VmFrame = struct {
    ip: usize,
    chunk: *const BytecodeChunk,
    locals: []Value,
    /// `local_arena` index where a flattened frame's locals start (to restore
    /// `local_top` on pop). Unused for the base frame (`flattened == false`).
    local_base: u16,
    flattened: bool,
    /// Whether this frame pushed a trace frame (ADR-0119) to pop on ret.
    trace_pushed: bool,
    gc_frame: root_set.EvalFrame,
};

/// `op_call`'s request to the eval loop to flatten a monomorphic call: the
/// resolved callee + where its result lands. The loop binds + pushes the frame
/// (it owns the `frames` stack); `op_call` only resolves + signals. No
/// consult-env (ADR-0129) save/restore is needed: a flattened callee runs in the
/// SAME `env` as this eval (set by the outer `treeWalkCall` / driver), so
/// `dispatch.current_env` stays invariant across the eval's frames.
const FlattenReq = struct {
    callee: Value,
    f: *Function,
    m: *const tree_walk.FunctionMethod,
    arg_count: u16,
    /// `op_top` slot the callee + args occupy; the result lands here on ret.
    result_slot: u16,
    call_loc: SourceLocation,
};

/// ADR-0131 2b: bind + push a flattened in-VM call frame for `fr`. The eval loop
/// owns the `frames` stack; `op_call` only resolved + signalled. `op_call` did NOT
/// pop the callee/args, so they stay rooted via `op_top` until `bindCallFrame`
/// copies the args into the locals arena here.
fn flattenPush(rt: *Runtime, ar: *VmArena, fr: FlattenReq) !void {
    if (ar.frame_top >= FRAMES_MAX)
        return error_catalog.raise(.stack_overflow, fr.call_loc, .{ .max = FRAMES_MAX });
    if (@as(usize, ar.local_top) + tree_walk.MAX_LOCALS > ARENA_SLOTS)
        return error_catalog.raise(.stack_overflow, fr.call_loc, .{ .max = ARENA_SLOTS });
    const args = ar.stack[@as(usize, fr.result_slot) + 1 ..][0..fr.arg_count];
    const local_base = ar.local_top;
    const locals_win: *[tree_walk.MAX_LOCALS]Value = ar.local_arena[local_base..][0..tree_walk.MAX_LOCALS];
    const fs = try tree_walk.bindCallFrame(rt, fr.f, fr.m, args, locals_win, .wrap, fr.call_loc);
    ar.local_top = local_base + @as(u16, @intCast(fs));
    // Consume callee + args: the callee's operands (and its eventual result) start
    // at the result slot.
    ar.op_top = fr.result_slot;
    // Trace (ADR-0119): advance the caller's frame to the call site, then push the
    // callee's frame for user-ns callables (popped on ret / unwind).
    error_mod.updateTopFrame(fr.call_loc);
    const trace_pushed = if (tree_walk.calleeFrame(fr.callee, fr.call_loc)) |tf| error_mod.pushFrame(tf) else false;
    const chunk: *const BytecodeChunk = fr.m.bytecode.?;
    const slot = &ar.frames[ar.frame_top];
    slot.* = .{
        .ip = 0,
        .chunk = chunk,
        .locals = ar.local_arena[local_base..][0..fs],
        .local_base = local_base,
        .flattened = true,
        .trace_pushed = trace_pushed,
        // GC-ROOT: A1 — each flattened frame roots its own locals window +
        // constants on the eval_frame_head chain (popped on ret / unwind).
        .gc_frame = .{
            .stack = &ar.stack,
            .sp = &ar.op_top,
            .locals = ar.local_arena[local_base..][0..fs],
            .constants = chunk.constants,
            .parent = root_set.eval_frame_head,
        },
    };
    root_set.eval_frame_head = &slot.gc_frame;
    ar.frame_top += 1;
}

/// Evaluate a compiled chunk. `locals` is the caller-owned slot array
/// (typically a fixed 256-entry stack array, matching `tree_walk.eval`).
/// Returns the value produced by `op_ret`. The operand stack lives in the
/// per-thread `VmArena` (ADR-0131 2a), borrowed at `op_base`. A flattened
/// `op_call` (2b) pushes an in-VM `VmFrame` + continues this loop instead of
/// re-entering `eval`; `op_ret` pops it.
pub fn eval(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const BytecodeChunk,
) anyerror!Value {
    // ADR-0131 2a/2b: borrow this invocation's operand + locals + frame regions
    // from the per-thread arena; restore all watermarks + the eval-frame chain
    // head on exit (normal OR a thrown error propagating out — the latter pops
    // every still-live flattened frame's gc_frame at once and frees its windows).
    const ar = &vm_arena;
    const op_base = ar.op_top;
    const local_base_entry = ar.local_top;
    const frame_base = ar.frame_top;
    const head_entry = root_set.eval_frame_head;
    // Publish this eval's env for the alloc-driven GC torture (D-386): a collect
    // forced from inside `gc.alloc` has no `env`, so it reads this threadlocal.
    // Validation-only; restored on exit (nested evals stack/unstack their env).
    const active_env_entry = root_set.active_env;
    root_set.active_env = env;
    defer {
        // Trace frames (ADR-0119) are a separate stack — pop any still-live
        // flattened frames' (LIFO) on an uncaught throw out of this eval.
        while (ar.frame_top > frame_base + 1) {
            ar.frame_top -= 1;
            if (ar.frames[ar.frame_top].trace_pushed) error_mod.popFrame();
        }
        ar.frame_top = frame_base;
        ar.op_top = op_base;
        ar.local_top = local_base_entry;
        root_set.eval_frame_head = head_entry;
        root_set.active_env = active_env_entry;
    }
    if (ar.frame_top >= FRAMES_MAX)
        return error_catalog.raise(.stack_overflow, .{}, .{ .max = FRAMES_MAX });

    var handlers: [HANDLER_STACK_MAX]Handler = undefined;
    var handler_count: u16 = 0;

    // The base frame: caller-owned locals + the base chunk. Its gc_frame is the 2a
    // A1 root (operand prefix `stack[0..op_top]` + caller locals + base constants).
    // GC-ROOT: A1 — the VM activation's operand stack + locals + chunk constants [ref: .dev/gc_rooting.md §A]
    const base = &ar.frames[ar.frame_top];
    base.* = .{
        .ip = 0,
        .chunk = chunk,
        .locals = locals,
        .local_base = 0,
        .flattened = false,
        .trace_pushed = false,
        .gc_frame = .{
            .stack = &ar.stack,
            .sp = &ar.op_top,
            .locals = locals,
            // D-251: root this chunk's literal constant pool for its whole
            // execution — a literal is reachable only here until an `op_const`
            // loads it onto `stack`, so a pre-load collect would otherwise sweep it.
            .constants = chunk.constants,
            .parent = root_set.eval_frame_head,
        },
    };
    root_set.eval_frame_head = &base.gc_frame;
    ar.frame_top += 1;

    // PERF: hoist `ip` to a loop-carried register; sync `cur.ip` only at frame transitions [refs: O-028, D-386]
    // The active in-VM frame (base, or a flattened callee — 2b) + its `ip` are
    // loop-carried so the hot dispatch keeps `ip` in a register (D-386 sub-step
    // 1): `cur.ip` (arena heap) is synced only at frame transitions (flatten /
    // ret / catch), not per-op. `ip` is NOT a GC root (only `op_top` is, via
    // `gc_frame.sp`), so hoisting it carries zero UAF risk — unlike a hoisted
    // `op_top` (sub-step 2). Every op reads/writes `cur`'s `chunk`/`locals`
    // window; the operand stack is the shared arena (`op_top` absolute). The
    // naive form (recompute `cur` + pass `&cur.ip` per op) is the contract.
    var cur = &ar.frames[ar.frame_top - 1];
    var ip: usize = cur.ip;
    while (true) {
        // Liveness-only back-edge safe point (ADR-0090 Alt B / D-244 #3b-step2):
        // a worker spinning in a non-allocating loop never hits the alloc-prologue
        // park, so it must poll here to notice a pending collection and park
        // (its operand-stack frame above is published, so the collector walks it).
        // Relaxed load — correctness of the roots is fenced by `park`'s acquire;
        // this poll only needs to eventually observe the flag. One predicted-not-
        // taken branch; inert until a Phase-B worker arms `gc_requested` (#4).
        if (safepoint.gc_requested.load(.monotonic)) safepoint.park();
        // ADR-0125: in-process eval execution budget (isolation dim (a)). One
        // optional unwrap when unmetered (rt.eval_budget == null) — same cost
        // shape as the GC poll above; charges a step + (throttled) checks the
        // wall-clock deadline, raising an uncatchable error on expiry.
        if (rt.eval_budget) |*budget| try budget.tick(rt.io);
        // GC torture (D-250): when armed via CLJW_GC_TORTURE, force a real
        // stop-the-world collect at this clean safe point every Nth poll, so a
        // missing root surfaces as a deterministic UAF on the next collect. The
        // operand stack + locals are published on `gc_frame` above and `env`
        // holds the program's ns vars, so this is a correct full collect.
        // `period != 0` is the inert-path guard (one global load, predicted not
        // taken); test/validation only — production auto-collect stays gated.
        // Scope the forced collect to the MAIN (unregistered) thread: a worker's
        // own STW collect self-deadlocks + misses the main's roots (D-244 #4, the
        // dormant multi-thread path). On the main thread the collect parks the
        // registered workers and walks the complete root set.
        if (gc_torture.period != 0 and !root_set.is_registered_worker and gc_torture.tick()) {
            mark_sweep.collectStopTheWorld(&rt.gc, .{ .envs = &.{env}, .gc = &rt.gc }, false);
        }
        var flatten_req: ?FlattenReq = null;
        const step_result = stepOnce(rt, env, cur.locals, cur.chunk, &ar.stack, &ar.loc, &ar.op_top, &ip, &handlers, &handler_count, &flatten_req);
        if (flatten_req) |fr| {
            // 2b: op_call resolved a monomorphic bytecode callee — push an in-VM
            // frame + continue this loop (no host eval re-entry). Save the
            // caller's advanced `ip` into its frame, then re-seat `cur`/`ip` on
            // the callee (D-386 sub-step 1).
            cur.ip = ip;
            try flattenPush(rt, ar, fr);
            cur = &ar.frames[ar.frame_top - 1];
            ip = cur.ip;
            continue;
        }
        if (step_result) |maybe_return| {
            if (maybe_return) |v| {
                // op_ret on `cur`. Base frame → the eval returns; a flattened
                // frame → pop it (restore trace / gc head / local_top) and land the
                // result at the caller's operand top (op_ret left op_top at the
                // callee's op_base = the result slot).
                if (ar.frame_top - 1 == frame_base) return v;
                if (cur.trace_pushed) error_mod.popFrame();
                root_set.eval_frame_head = cur.gc_frame.parent;
                ar.local_top = cur.local_base;
                ar.frame_top -= 1;
                if (ar.op_top >= ar.stack.len)
                    return raiseInternal("vm: operand stack overflow on ret");
                ar.stack[ar.op_top] = v;
                ar.loc[ar.op_top] = .{};
                ar.op_top += 1;
                // Re-seat on the caller frame; restore its `ip` saved at flatten.
                cur = &ar.frames[ar.frame_top - 1];
                ip = cur.ip;
                continue;
            }
        } else |err| {
            // Bounded unwind (2b): flattened frames are handler-free, so the live
            // handlers all belong to the base frame. Pop the flattened frames
            // (restore trace / gc head / local_top) down to the base; the catch
            // logic below then targets `bcur` (= the base frame).
            while (ar.frame_top > frame_base + 1) {
                ar.frame_top -= 1;
                const ff = &ar.frames[ar.frame_top];
                if (ff.trace_pushed) error_mod.popFrame();
                root_set.eval_frame_head = ff.gc_frame.parent;
                ar.local_top = ff.local_base;
            }
            const bcur = &ar.frames[frame_base];
            // All handlers belong to the base frame; re-seat `cur` there (the
            // per-continue `ip = …` below restores the catch target).
            cur = bcur;
            var thrown_err = err;
            // ADR-0071: a `.cleanup` handler (binding / bare-try) is a
            // `defer`, not a `catch`. Tested BEFORE the conversion below so
            // the in-flight error is preserved unchanged: no catalog→
            // exception conversion (Kind + `info.context` survive), no
            // `last_thrown_context` clear. Stash the original error, run the
            // cleanup bytecode (e.g. op_pop_binding_frame), and op_reraise
            // re-fires it — matching TreeWalk's `defer popFrame`. Stashing
            // immediately before each jump keeps a re-raised error correct
            // through nested cleanups (the stash is always re-set before the
            // next op_reraise reads it).
            if (handler_count > 0 and handlers[handler_count - 1].kind == .cleanup) {
                handler_count -= 1;
                const h = handlers[handler_count];
                dispatch.vm_pending_reraise = thrown_err;
                bcur.ip = h.catch_ip;
                ip = h.catch_ip;
                ar.op_top = h.saved_sp;
                continue;
            }
            // ADR-0060: convert a catchable internal error (error_catalog)
            // into a thrown exception so the handler stack can catch it —
            // parity with tree_walk evalTry. Only when a handler exists;
            // uncatchable Kinds (null) and a truly-uncaught error (no
            // handler) keep the raw Zig error + `[kind]` CLI header.
            if (err != error.ThrownValue and handler_count > 0) {
                if (error_mod.peekLastError()) |info| {
                    if (host_class.kindToHostClass(info.kind)) |class| {
                        const synth = ex_info_mod.allocExceptionLoc(rt, info.message, class, info.location, info.trace) catch return err;
                        dispatch.last_thrown_exception = synth;
                        error_mod.clearLastError();
                        thrown_err = error.ThrownValue;
                    }
                }
            }
            if (thrown_err == error.ThrownValue and handler_count > 0) {
                handler_count -= 1;
                const h = handlers[handler_count];
                bcur.ip = h.catch_ip;
                ip = h.catch_ip;
                ar.op_top = h.saved_sp;
                const thrown = dispatch.last_thrown_exception orelse
                    return raiseInternal("vm: ThrownValue without payload");
                dispatch.last_thrown_exception = null;
                dispatch.last_thrown_context = null;
                if (ar.op_top >= ar.stack.len)
                    return raiseInternal("vm: handler unwind overflow");
                ar.stack[ar.op_top] = thrown;
                // ADR-0118 cycle 2.5: the caught value has no compiled operand
                // loc; record an unknown loc so a later op_call never reads an
                // uninitialized loc_stack slot (renderer falls back gracefully).
                ar.loc[ar.op_top] = .{};
                ar.op_top += 1;
                continue;
            }
            return err;
        }
    }
}

/// Fetch + execute one instruction. Returns `null` to keep looping,
/// a non-null Value when `op_ret` fires, or propagates the Zig error
/// so the outer loop can route `error.ThrownValue` through the
/// handler stack.
// PERF: force-inline the per-op dispatch into the `eval` loop. ReleaseSafe was
// NOT inlining this 11-arg hot function, so each instruction paid a real call
// boundary (v0 dispatches a 2-arg step; cljw's wide signature made the call
// expensive). Inlining: fib_recursive 40→33 ms, tak 15→13 (D-386 step 1). The
// naive form is a plain `fn`; behaviour is identical (diff oracle). [refs: O-017]
inline fn stepOnce(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const BytecodeChunk,
    stack: []Value,
    loc_stack: []SourceLocation,
    sp_ptr: *u16,
    ip_ptr: *usize,
    handlers: *[HANDLER_STACK_MAX]Handler,
    handler_count_ptr: *u16,
    /// ADR-0131 2b: when `op_call` resolves a monomorphic bytecode callee it sets
    /// this (and returns `null`/cont, WITHOUT popping the callee+args) so the eval
    /// loop flattens it into an in-VM frame instead of a host `vt.callFn` re-entry.
    flatten_out: *?FlattenReq,
) anyerror!?Value {
    var sp = sp_ptr.*;
    var ip = ip_ptr.*;
    var handler_count = handler_count_ptr.*;
    const sp_entry = sp;
    defer {
        sp_ptr.* = sp;
        ip_ptr.* = ip;
        handler_count_ptr.* = handler_count;
    }

    if (ip >= chunk.instructions.len)
        return raiseInternal("vm: ip past end of chunk");
    const instr = chunk.instructions[ip];
    ip += 1;

    // ADR-0118 cycle 2.5: this instruction's compiled source loc. Each operand
    // it pushes inherits this loc (recorded in the post-switch sweep below), so
    // a literal `0` pushed by `op_const` carries the `0`'s column, not the
    // enclosing call form's. `op_call` overrides its own result slot with the
    // call-form loc explicitly (it pops before it pushes, so the sweep misses it).
    const instr_loc: SourceLocation = .{ .file = chunk.source_file, .line = instr.line, .column = instr.column };

    switch (instr.opcode) {
        .op_const => {
            @branchHint(.likely);
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_const constant index out of range");
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = chunk.constants[instr.operand];
            sp += 1;
        },
        .op_load_local => {
            if (instr.operand >= locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = instr.operand, .max = locals.len });
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = locals[instr.operand];
            sp += 1;
        },
        .op_store_local => {
            if (instr.operand >= locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "let*", .index = instr.operand, .max = locals.len });
            if (sp == 0) return raiseInternal("vm: op_store_local on empty stack");
            sp -= 1;
            locals[instr.operand] = stack[sp];
        },
        .op_letfn_patch => {
            // operand = (count << 8) | base; both ≤ MAX_LOCALS (256).
            // Wire the just-stored letfn closures into a mutually-
            // recursive group (shared with TreeWalk's evalLetfn).
            const base: u16 = instr.operand & 0xFF;
            const count: u16 = instr.operand >> 8;
            tree_walk.patchLetfnClosures(locals, base, count);
        },
        .op_def => {
            if (sp == 0) return raiseInternal("vm: op_def on empty stack");
            sp -= 1;
            const value = stack[sp];
            const name_idx = instr.operand & opcode_mod.DEF_NAME_IDX_MASK;
            if (name_idx >= chunk.constants.len)
                return raiseInternal("vm: op_def name index out of range");
            const name_val = chunk.constants[name_idx];
            if (!name_val.isString())
                return raiseInternal("vm: op_def constant is not a String");
            const ns = env.current_ns orelse
                return error_catalog.raiseInternal(.{}, "def: no current namespace");
            const var_ptr = try env.intern(ns, string_mod.asString(name_val), value, null);
            var_ptr.flags.dynamic = (instr.operand & opcode_mod.DEF_FLAG_DYNAMIC) != 0;
            var_ptr.flags.macro_ = (instr.operand & opcode_mod.DEF_FLAG_MACRO) != 0;
            var_ptr.flags.private = (instr.operand & opcode_mod.DEF_FLAG_PRIVATE) != 0;
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.encodeHeapPtr(.var_ref, var_ptr);
            sp += 1;
        },
        .op_def_unbound => {
            // No-init `(def x)`: intern an UNBOUND placeholder (no stack value,
            // does not clobber an existing root, Var.bound stays false).
            const name_idx = instr.operand & opcode_mod.DEF_NAME_IDX_MASK;
            if (name_idx >= chunk.constants.len)
                return raiseInternal("vm: op_def_unbound name index out of range");
            const name_val = chunk.constants[name_idx];
            if (!name_val.isString())
                return raiseInternal("vm: op_def_unbound constant is not a String");
            const ns = env.current_ns orelse
                return error_catalog.raiseInternal(.{}, "def: no current namespace");
            const var_ptr = try env.internDeclare(ns, string_mod.asString(name_val));
            var_ptr.flags.dynamic = (instr.operand & opcode_mod.DEF_FLAG_DYNAMIC) != 0;
            var_ptr.flags.macro_ = (instr.operand & opcode_mod.DEF_FLAG_MACRO) != 0;
            var_ptr.flags.private = (instr.operand & opcode_mod.DEF_FLAG_PRIVATE) != 0;
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.encodeHeapPtr(.var_ref, var_ptr);
            sp += 1;
        },
        .op_get_var => {
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_get_var constant index out of range");
            const var_value = chunk.constants[instr.operand];
            const var_ptr = var_value.decodePtr(*Var);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = var_ptr.deref();
            sp += 1;
        },
        .op_ns_import => {
            // D-235: register one `(:import …)` simple->fqcn into the
            // current ns. Pushes nil (the ns form's running value).
            if (instr.operand >= chunk.import_sites.len)
                return raiseInternal("vm: op_ns_import site index out of range");
            const imp = chunk.import_sites[instr.operand];
            const here = env.current_ns orelse
                return error_catalog.raise(.current_namespace_missing, .{}, .{ .sym = imp.simple });
            try here.addImport(env.alloc, imp.simple, imp.fqcn);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.nil_val;
            sp += 1;
        },
        .op_set_var => {
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_set_var constant index out of range");
            if (sp == 0) return raiseInternal("vm: op_set_var on empty stack");
            const var_ptr = chunk.constants[instr.operand].decodePtr(*Var);
            const val = stack[sp - 1]; // peek: the assigned value stays as the result
            // ADR-0096: thread-bound-or-raise (JVM Var.set parity); never setRoot.
            if (!env_mod.setBinding(var_ptr, val)) {
                const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ var_ptr.ns.name, var_ptr.name });
                defer rt.gpa.free(full);
                return error_catalog.raise(.var_set_not_bound, .{}, .{ .@"var" = full });
            }
        },
        .op_set_field => {
            // ADR-0104: `(set! field v)` on a deftype mutable field. Stack:
            // [receiver, value]. operand = field-name String constant.
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_set_field constant index out of range");
            if (sp < 2) return raiseInternal("vm: op_set_field underflows operand stack");
            const field_name = string_mod.asString(chunk.constants[instr.operand]);
            const value = stack[sp - 1];
            const receiver = stack[sp - 2];
            if (receiver.tag() != .typed_instance)
                return raiseInternal("vm: op_set_field receiver is not a deftype instance (compiler bug)");
            const inst = receiver.decodePtr(*const td_mod.TypedInstance);
            const layout = inst.descriptor.field_layout orelse
                return raiseInternal("vm: op_set_field on a type with no fields (compiler bug)");
            var wrote = false;
            for (layout) |fe| {
                if (std.mem.eql(u8, fe.name, field_name)) {
                    inst.setField(fe.index, value);
                    wrote = true;
                    break;
                }
            }
            if (!wrote) return error_catalog.raise(.symbol_unresolved, .{}, .{ .sym = field_name });
            sp -= 2;
            stack[sp] = value;
            sp += 1;
        },
        .op_jump => {
            const offset: i16 = @bitCast(instr.operand);
            ip = applyJump(ip, offset) orelse
                return raiseInternal("vm: op_jump target out of range");
        },
        .op_jump_if_false => {
            if (sp == 0) return raiseInternal("vm: op_jump_if_false on empty stack");
            sp -= 1;
            if (!stack[sp].isTruthy()) {
                const offset: i16 = @bitCast(instr.operand);
                ip = applyJump(ip, offset) orelse
                    return raiseInternal("vm: op_jump_if_false target out of range");
            }
        },
        .op_call => {
            const arg_count: usize = instr.operand;
            if (sp < arg_count + 1)
                return raiseInternal("vm: op_call underflow");
            const result_slot: u16 = sp - @as(u16, @intCast(arg_count + 1));
            const callee = stack[result_slot];
            // ADR-0131 2b: flatten a monomorphic bytecode `.fn_val` call into an
            // in-VM frame (the eval loop pushes it). Leave `sp` UNCHANGED so the
            // callee + args stay rooted via `op_top` until `flattenPush` copies
            // the args into the locals arena. Exclude rest fns (rest-pack alloc on
            // the slow binder) and handler-bearing chunks (the bounded throw-unwind
            // assumes flattened frames are handler-free). Anything else falls
            // through to the slow `vt.callFn` path — the F-012 oracle seam.
            if (callee.tag() == .fn_val) {
                const f = callee.decodePtr(*Function);
                if (tree_walk.selectMethod(f, arg_count)) |m| {
                    if (m.bytecode) |bc| {
                        if (!m.has_rest and !bc.has_handlers) {
                            flatten_out.* = .{
                                .callee = callee,
                                .f = f,
                                .m = m,
                                .arg_count = @intCast(arg_count),
                                .result_slot = result_slot,
                                .call_loc = instr_loc,
                            };
                            return null;
                        }
                    }
                }
            }
            // Slow path: pop callee + args, dispatch through the oracle seam.
            sp = result_slot;
            const args = stack[sp + 1 .. sp + 1 + arg_count];
            const vt = rt.vtable orelse
                return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch call");
            // ADR-0118: thread the call form's source position (compiled onto
            // this op + the chunk's file) into callFn, so an error raised by
            // the callee annotates the failing call site instead of `0:0`.
            const call_loc = instr_loc;
            // ADR-0118 cycle 2.5: publish each arg's recorded loc (the parallel
            // loc_stack slots the operand pushes filled in) so a failing
            // primitive resolves an arg-precise caret; restore on return.
            const prev_arg_sources = error_mod.swapArgSources(loc_stack[sp + 1 .. sp + 1 + arg_count]);
            defer _ = error_mod.swapArgSources(prev_arg_sources);
            const result = try vt.callFn(rt, env, callee, args, call_loc);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            // The result's own loc is the call form (this op pops below sp_entry,
            // so the post-switch sweep does not reach this slot).
            loc_stack[sp] = call_loc;
            stack[sp] = result;
            sp += 1;
        },
        .op_add, .op_sub, .op_mul, .op_lt, .op_le, .op_gt, .op_ge, .op_eq, .op_mod, .op_rem, .op_quot, .op_ne => {
            // ADR-0130: binary arith/comparison intrinsic. Fixnum fast path skips
            // var-resolve + BuiltinFn dispatch; any other case (incl. errors)
            // defers to the cached builtin Var for full parity. `pristine` is
            // cleared by alter-var-root on a cached op (deopt → always builtin).
            if (sp < 2) return raiseInternal("vm: arith intrinsic underflow");
            sp -= 2;
            const a = stack[sp];
            const b = stack[sp + 1];
            const aop = intrinsic.fromOpcode(instr.opcode).?;
            const fast: ?Value = if (rt.core_arith_pristine)
                try intrinsic.fastBinaryFixnum(rt, aop, a, b)
            else
                null;
            const result = fast orelse blk: {
                const vt = rt.vtable orelse
                    return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch arith intrinsic");
                const pv = rt.arith_vars[@intFromEnum(aop)] orelse
                    return raiseInternal("vm: arith intrinsic emitted without a cached Var");
                const op_var: *const env_mod.Var = @ptrCast(@alignCast(pv));
                const two = [2]Value{ a, b };
                // Publish the operands' recorded locs so a builtin error
                // (e.g. `(+ 1 "a")`) resolves an arg-precise caret, matching
                // op_call / TreeWalk (ADR-0118). Only the fallback can error;
                // the fixnum fast path cannot.
                const prev_arg_sources = error_mod.swapArgSources(loc_stack[sp .. sp + 2]);
                defer _ = error_mod.swapArgSources(prev_arg_sources);
                break :blk try vt.callFn(rt, env, op_var.deref(), &two, instr_loc);
            };
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            loc_stack[sp] = instr_loc;
            stack[sp] = result;
            sp += 1;
        },
        .op_add_local_const, .op_sub_local_const, .op_mul_local_const, .op_lt_local_const, .op_le_local_const, .op_gt_local_const, .op_ge_local_const, .op_eq_local_const, .op_mod_local_const, .op_rem_local_const, .op_quot_local_const, .op_ne_local_const => {
            // PERF: D-386 (O-018) local-const arith superinstruction — operands come
            // from `locals[slot]` + `constants[idx]` (packed in the operand), NOT the
            // stack, fusing op_load_local + op_const + op_<arith> into one dispatch.
            // Same fixnum-fast / builtin-deopt semantics as the op_add family; net
            // stack effect +1 (a pure push). [refs: O-018]
            const lslot: usize = instr.operand >> 8;
            const cidx: usize = instr.operand & 0xFF;
            if (lslot >= locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = @as(u16, @intCast(lslot)), .max = locals.len });
            if (cidx >= chunk.constants.len)
                return raiseInternal("vm: local_const constant index out of range");
            const a = locals[lslot];
            const b = chunk.constants[cidx];
            const aop = intrinsic.fromLocalConstOpcode(instr.opcode).?;
            const fast: ?Value = if (rt.core_arith_pristine)
                try intrinsic.fastBinaryFixnum(rt, aop, a, b)
            else
                null;
            const result = fast orelse blk: {
                const vt = rt.vtable orelse
                    return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch arith intrinsic");
                const pv = rt.arith_vars[@intFromEnum(aop)] orelse
                    return raiseInternal("vm: arith intrinsic emitted without a cached Var");
                const op_var: *const env_mod.Var = @ptrCast(@alignCast(pv));
                const two = [2]Value{ a, b };
                break :blk try vt.callFn(rt, env, op_var.deref(), &two, instr_loc);
            };
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            loc_stack[sp] = instr_loc;
            stack[sp] = result;
            sp += 1;
        },
        .op_add_locals, .op_sub_locals, .op_mul_locals, .op_lt_locals, .op_le_locals, .op_gt_locals, .op_ge_locals, .op_eq_locals, .op_mod_locals, .op_rem_locals, .op_quot_locals, .op_ne_locals => {
            // PERF: D-386 (O-019) local-LOCAL arith superinstruction — both operands
            // from `locals[]` (slots packed in the operand), fusing op_load_local +
            // op_load_local + op_<arith> into one dispatch. Same fixnum-fast /
            // builtin-deopt as op_add; net stack effect +1. [refs: O-019]
            const sa: usize = instr.operand >> 8;
            const sb: usize = instr.operand & 0xFF;
            if (sa >= locals.len or sb >= locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = @as(u16, @intCast(if (sa >= locals.len) sa else sb)), .max = locals.len });
            const a = locals[sa];
            const b = locals[sb];
            const aop = intrinsic.fromLocalsOpcode(instr.opcode).?;
            const fast: ?Value = if (rt.core_arith_pristine)
                try intrinsic.fastBinaryFixnum(rt, aop, a, b)
            else
                null;
            const result = fast orelse blk: {
                const vt = rt.vtable orelse
                    return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch arith intrinsic");
                const pv = rt.arith_vars[@intFromEnum(aop)] orelse
                    return raiseInternal("vm: arith intrinsic emitted without a cached Var");
                const op_var: *const env_mod.Var = @ptrCast(@alignCast(pv));
                const two = [2]Value{ a, b };
                break :blk try vt.callFn(rt, env, op_var.deref(), &two, instr_loc);
            };
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            loc_stack[sp] = instr_loc;
            stack[sp] = result;
            sp += 1;
        },
        .op_branch_ne_local_const, .op_branch_ge_local_const, .op_branch_gt_local_const, .op_branch_ne_locals, .op_branch_ge_locals, .op_branch_gt_locals => {
            // PERF: D-386 (O-021) compare-and-branch superinstruction. `operand` =
            // the comparison's slot/const pair; the IMMEDIATELY-FOLLOWING instruction
            // is the DATA WORD carrying the i16 jump offset (the fused
            // `op_jump_if_false`, never dispatched). Compute the comparison
            // (locals[a] CMP locals/const[b], fixnum-fast / builtin-deopt) and JUMP
            // when it is FALSE (jump_if_false semantics). [refs: O-021]
            const info = intrinsic.fromBranchOpcode(instr.opcode).?;
            const sa: usize = instr.operand >> 8;
            const sb: usize = instr.operand & 0xFF;
            if (ip >= chunk.instructions.len)
                return raiseInternal("vm: op_branch_* missing offset data word");
            const offset: i16 = @bitCast(chunk.instructions[ip].operand);
            ip += 1;
            if (sa >= locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = @as(u16, @intCast(sa)), .max = locals.len });
            const a = locals[sa];
            const b = if (info.b_is_const) bblk: {
                if (sb >= chunk.constants.len)
                    return raiseInternal("vm: op_branch_* constant index out of range");
                break :bblk chunk.constants[sb];
            } else bblk: {
                if (sb >= locals.len)
                    return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = @as(u16, @intCast(sb)), .max = locals.len });
                break :bblk locals[sb];
            };
            const fast: ?Value = if (rt.core_arith_pristine)
                try intrinsic.fastBinaryFixnum(rt, info.cmp, a, b)
            else
                null;
            const cmp_result = fast orelse blk: {
                const vt = rt.vtable orelse
                    return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch arith intrinsic");
                const pv = rt.arith_vars[@intFromEnum(info.cmp)] orelse
                    return raiseInternal("vm: arith intrinsic emitted without a cached Var");
                const op_var: *const env_mod.Var = @ptrCast(@alignCast(pv));
                const two = [2]Value{ a, b };
                break :blk try vt.callFn(rt, env, op_var.deref(), &two, instr_loc);
            };
            // jump_if_false: branch when the comparison is FALSE.
            if (!cmp_result.isTruthy()) {
                ip = applyJump(ip, offset) orelse
                    return raiseInternal("vm: op_branch_* target out of range");
            }
        },
        .op_recur_loop => {
            // PERF: D-386 (O-022) fused loop back-edge. `operand` = (base << 8) | N;
            // the IMMEDIATELY-FOLLOWING instruction is the DATA WORD with the i16
            // back-jump offset. Store the top N operands to `locals[base..base+N)`
            // (arg k → binding k) and jump back to the loop body — collapses
            // op_recur + N op_store_local + op_jump. [refs: O-022]
            const base: usize = instr.operand >> 8;
            const nb: usize = instr.operand & 0xFF;
            if (ip >= chunk.instructions.len)
                return raiseInternal("vm: op_recur_loop missing offset data word");
            const offset: i16 = @bitCast(chunk.instructions[ip].operand);
            ip += 1;
            if (sp < nb) return raiseInternal("vm: op_recur_loop underflow");
            if (base + nb > locals.len)
                return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "loop*", .index = @as(u16, @intCast(base + nb)), .max = locals.len });
            const top: u16 = sp - @as(u16, @intCast(nb));
            var k: usize = 0;
            while (k < nb) : (k += 1) {
                locals[base + k] = stack[top + k];
            }
            sp = top;
            ip = applyJump(ip, offset) orelse
                return raiseInternal("vm: op_recur_loop target out of range");
        },
        .op_ret => {
            @branchHint(.likely);
            if (sp == 0) return raiseInternal("vm: op_ret on empty stack");
            sp -= 1;
            return stack[sp];
        },
        .op_pop => {
            if (sp == 0) return raiseInternal("vm: op_pop on empty stack");
            sp -= 1;
        },
        .op_dup => {
            if (sp == 0) return raiseInternal("vm: op_dup on empty stack");
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = stack[sp - 1];
            sp += 1;
        },
        .op_throw => {
            if (sp == 0) return raiseInternal("vm: op_throw on empty stack");
            sp -= 1;
            dispatch.last_thrown_exception = stack[sp];
            // Snapshot *error-context* while the binding frame is
            // live (ADR-0055 am2 / D-144) — symmetric with TreeWalk's
            // evalThrow so the two backends agree at the throw edge.
            dispatch.last_thrown_context = error_mod.snapshotContext();
            return error.ThrownValue;
        },
        .op_make_fn => {
            // The compiler stashes either a final closure-less
            // Function (slot_base == 0) or a template Function
            // (slot_base > 0, closure_bindings still null) in the
            // constant pool. For the template case the dispatcher
            // allocates a fresh Function with a snapshot of the
            // caller's locals[0..slot_base] so each fn* evaluation
            // captures its enclosing scope.
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_make_fn constant index out of range");
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            const template_val = chunk.constants[instr.operand];
            const template = template_val.decodePtr(*const Function);
            if (template.slot_base == 0) {
                stack[sp] = template_val;
            } else {
                // Row 7.8 cycle 1 (ADR-0041): rebuild a transient
                // FnNode from the template's per-method records so
                // `allocFunctionWithBytecode` can snapshot the
                // caller's locals + stamp per-method chunks.
                if (templateMethodsHaveAnyMissingChunk(template))
                    return raiseInternal("vm: op_make_fn template missing bytecode");
                var node_methods = std.heap.stackFallback(8 * @sizeOf(node_mod.FnMethod), rt.gpa);
                const allocator = node_methods.get();
                const ms = allocator.alloc(node_mod.FnMethod, template.methods.len) catch
                    return raiseInternal("vm: op_make_fn alloc failed");
                defer allocator.free(ms);
                const chunks = allocator.alloc(?*const opcode_mod.BytecodeChunk, template.methods.len) catch
                    return raiseInternal("vm: op_make_fn alloc failed");
                defer allocator.free(chunks);
                for (template.methods, 0..) |m, i| {
                    ms[i] = .{
                        .arity = m.arity,
                        .has_rest = m.has_rest,
                        .params = m.params,
                        .body = m.body,
                        .frame_slots = m.frame_slots, // ADR-0130 frame-rooting
                    };
                    chunks[i] = m.bytecode;
                }
                var variadic_node: ?node_mod.FnMethod = null;
                var variadic_chunk: ?*const opcode_mod.BytecodeChunk = null;
                if (template.variadic) |v| {
                    variadic_node = .{
                        .arity = v.arity,
                        .has_rest = v.has_rest,
                        .params = v.params,
                        .body = v.body,
                        .frame_slots = v.frame_slots, // ADR-0130 frame-rooting
                    };
                    variadic_chunk = v.bytecode;
                }
                const fn_node = node_mod.FnNode{
                    .methods = ms,
                    .variadic = variadic_node,
                    .slot_base = template.slot_base,
                    // ADR-0119: the closure instance inherits the template's name.
                    .name = template.name,
                    .defining_ns = template.defining_ns,
                };
                stack[sp] = try tree_walk.allocFunctionWithBytecode(rt, fn_node, locals, chunks, variadic_chunk);
            }
            sp += 1;
        },
        .op_recur => {
            // The compiler emits `op_recur <arity>` followed by N
            // op_store_local + op_jump <-back_offset>. The arity
            // check here is defensive — the analyser already
            // validated arity at parse time. The actual rebind
            // and back-jump happen in the following instructions.
            if (sp < instr.operand)
                return raiseInternal("vm: op_recur underflow");
        },
        .op_invoke_builtin => {
            // Reserved for analyzer-resolved direct builtin calls;
            // the compiler does not emit this (every call routes
            // through `op_call` + vtable). Per
            // `no_op_stub_forbidden.md`, raise rather than fall
            // through silently.
            return error_catalog.raise(.feature_not_supported, .{}, .{ .name = "op_invoke_builtin" });
        },
        .op_push_handler => {
            const offset: i16 = @bitCast(instr.operand);
            const catch_ip = applyJump(ip, offset) orelse
                return raiseInternal("vm: op_push_handler target out of range");
            if (handler_count >= HANDLER_STACK_MAX)
                return raiseInternal("vm: handler stack overflow");
            handlers[handler_count] = .{ .catch_ip = catch_ip, .saved_sp = sp, .kind = .catch_clause };
            handler_count += 1;
        },
        .op_push_cleanup => {
            const offset: i16 = @bitCast(instr.operand);
            const cleanup_ip = applyJump(ip, offset) orelse
                return raiseInternal("vm: op_push_cleanup target out of range");
            if (handler_count >= HANDLER_STACK_MAX)
                return raiseInternal("vm: handler stack overflow");
            handlers[handler_count] = .{ .catch_ip = cleanup_ip, .saved_sp = sp, .kind = .cleanup };
            handler_count += 1;
        },
        .op_reraise => {
            // Re-fire the error the cleanup-unwind branch stashed,
            // unchanged (ADR-0071). The cleanup bytecode just ran (e.g.
            // op_pop_binding_frame); the catalog Info / thrown context
            // is still intact, so the original error propagates as it
            // would have under TreeWalk's `defer`.
            const e = dispatch.vm_pending_reraise orelse
                return raiseInternal("vm: op_reraise without a pending error");
            dispatch.vm_pending_reraise = null;
            return e;
        },
        .op_pop_handler => {
            if (handler_count == 0)
                return raiseInternal("vm: op_pop_handler on empty handler stack");
            handler_count -= 1;
        },
        .op_push_binding_frame => {
            // Pops 2N entries [encVar0, val0, …] and installs a
            // per-thread BindingFrame on the env threadlocal (shared
            // with TreeWalk — assumes the single-threaded model;
            // Phase B concurrency revisits this, so for now
            // `Var.deref` stays backend-agnostic). The compiler wraps
            // the body in a cleanup handler so `op_pop_binding_frame`
            // runs on both the success and the exception edge.
            const n_pairs: usize = instr.operand;
            if (sp < n_pairs * 2)
                return raiseInternal("vm: op_push_binding_frame stack underflow");
            const base = sp - n_pairs * 2;
            const frame = rt.gpa.create(env_mod.BindingFrame) catch
                return raiseInternal("vm: op_push_binding_frame frame alloc");
            frame.* = .{};
            var pi: usize = 0;
            while (pi < n_pairs) : (pi += 1) {
                const var_ptr = stack[base + pi * 2].decodePtr(*const Var);
                const val = stack[base + pi * 2 + 1];
                if (!var_ptr.flags.dynamic) {
                    frame.bindings.deinit(rt.gpa);
                    rt.gpa.destroy(frame);
                    var name_buf: [512]u8 = undefined;
                    const qualified = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ var_ptr.ns.name, var_ptr.name }) catch var_ptr.name;
                    return error_catalog.raise(.binding_target_not_dynamic, .{}, .{ .@"var" = qualified });
                }
                frame.bindings.put(rt.gpa, var_ptr, val) catch {
                    frame.bindings.deinit(rt.gpa);
                    rt.gpa.destroy(frame);
                    return raiseInternal("vm: op_push_binding_frame put");
                };
            }
            sp = @intCast(base);
            env_mod.pushFrame(frame);
            // current_ns is a materialised view of *ns* (ADR-0085):
            // refresh in case this frame rebinds *ns*.
            env.refreshCurrentNs();
        },
        .op_pop_binding_frame => {
            const f = env_mod.current_frame orelse
                return raiseInternal("vm: op_pop_binding_frame on empty frame stack");
            env_mod.popFrame();
            f.bindings.deinit(rt.gpa);
            rt.gpa.destroy(f);
            // Restore current_ns to the outer *ns* after the frame pops.
            env.refreshCurrentNs();
        },
        .op_match_class => {
            if (sp == 0)
                return raiseInternal("vm: op_match_class on empty stack");
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_match_class constant index out of range");
            const class_val = chunk.constants[instr.operand];
            if (!class_val.isString())
                return raiseInternal("vm: op_match_class constant is not a String");
            const thrown = stack[sp - 1];
            const matches = matchExceptionClass(string_mod.asString(class_val), thrown);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = if (matches) Value.true_val else Value.false_val;
            sp += 1;
        },
        .op_match_type_keyword => {
            if (sp == 0)
                return raiseInternal("vm: op_match_type_keyword on empty stack");
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_match_type_keyword constant index out of range");
            const kw_val = chunk.constants[instr.operand];
            const thrown = stack[sp - 1];
            const matches = matchExceptionTypeKeyword(rt, kw_val, thrown);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = if (matches) Value.true_val else Value.false_val;
            sp += 1;
        },
        .op_in_ns => {
            // ADR-0032 in-ns — mirror of tree_walk::evalInNs.
            // ADR-0035 D9 second amendment (Phase 7 entry T3,
            // 2026-05-26): the prior auto-refer of rt +
            // clojure.core has been removed. `(in-ns 'foo)` is
            // now a naked ns switch. `.clj` heads use
            // `(ns foo (:refer-clojure))` which compiles to
            // `op_ns_with_refer_clojure` (= this opcode + both
            // refers).
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_in_ns constant index out of range");
            const name_val = chunk.constants[instr.operand];
            if (!name_val.isString())
                return raiseInternal("vm: op_in_ns constant is not a String");
            const target_ns = try env.findOrCreateNs(string_mod.asString(name_val));
            env.setCurrentNs(target_ns);
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            // Return the namespace value (clj parity, ADR-0083 / ADR-0085).
            stack[sp] = Env.nsValue(target_ns);
            sp += 1;
        },
        .op_ns_with_refer_clojure => {
            // ADR-0035 D9 second amendment + ADR-0036 dual-
            // backend parity contract. Mirror of post-T3
            // tree_walk::evalNs when `refer_clojure = true`.
            // op_in_ns logic + referAll(rt) + referAll(clojure.core).
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_ns_with_refer_clojure constant index out of range");
            const name_val = chunk.constants[instr.operand];
            if (!name_val.isString())
                return raiseInternal("vm: op_ns_with_refer_clojure constant is not a String");
            env.setCurrentNs(try env.findOrCreateNs(string_mod.asString(name_val)));
            if (env.findNs("rt")) |rt_ns| {
                try env.referAll(rt_ns, env.current_ns.?);
            }
            if (env.findNs("clojure.core")) |clojure_core_ns| {
                // ADR-0035 D9 revision: clojure.core overrides rt on collision.
                try env.referAllOverriding(clojure_core_ns, env.current_ns.?, &.{}, null);
            }
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.nil_val;
            sp += 1;
        },
        .op_ns_with_filter => {
            // D-098: mirror of tree_walk::evalNs's refer-clojure branch
            // with the `:exclude`/`:only` filter. Enter the ns, then
            // refer rt + clojure.core through referAllWithFilter.
            if (instr.operand >= chunk.ns_filters.len)
                return raiseInternal("vm: op_ns_with_filter index out of range");
            const f = chunk.ns_filters[instr.operand];
            env.setCurrentNs(try env.findOrCreateNs(f.name));
            if (env.findNs("rt")) |rt_ns| {
                try env.referAllWithFilter(rt_ns, env.current_ns.?, f.exclude, f.only);
            }
            if (env.findNs("clojure.core")) |clojure_core_ns| {
                // ADR-0035 D9 revision: clojure.core overrides rt on collision.
                try env.referAllOverriding(clojure_core_ns, env.current_ns.?, f.exclude, f.only);
            }
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.nil_val;
            sp += 1;
        },
        .op_require => {
            // ADR-0035 D2 — mirror of tree_walk::evalRequire.
            if (instr.operand >= chunk.constants.len)
                return raiseInternal("vm: op_require constant index out of range");
            const name_val = chunk.constants[instr.operand];
            if (!name_val.isString())
                return raiseInternal("vm: op_require constant is not a String");
            const ns_name = string_mod.asString(name_val);
            const already_loaded = blk: {
                const existing = env.findNs(ns_name) orelse break :blk false;
                break :blk existing.mappings.count() > 0;
            };
            if (!already_loaded) {
                const resolver = rt.require_resolver orelse
                    return error_catalog.raise(.lib_not_found, .{}, .{ .ns = ns_name });
                const resolved = (try resolver(rt, ns_name)) orelse
                    return error_catalog.raise(.lib_not_found, .{}, .{ .ns = ns_name });
                try loader.loadNamespace(rt, env, ns_name, resolved, .{});
            }
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.nil_val;
            sp += 1;
        },
        .op_require_with_libspec => {
            // Row 7.10 cycle 3 (D-073 sub-site d discharge,
            // ADR-0036 first real-feature exercise) — mirror of
            // tree_walk::evalRequire's full body. Pops the
            // LibspecEntry from the chunk side-table, runs the
            // op_require prelude, then applies alias + refers.
            if (instr.operand >= chunk.libspecs.len)
                return raiseInternal("vm: op_require_with_libspec libspec index out of range");
            const spec = chunk.libspecs[instr.operand];
            const target_ns = blk: {
                if (env.findNs(spec.ns_name)) |existing| {
                    if (existing.mappings.count() > 0) break :blk existing;
                }
                const resolver = rt.require_resolver orelse
                    return error_catalog.raise(.lib_not_found, .{}, .{ .ns = spec.ns_name });
                const resolved = (try resolver(rt, spec.ns_name)) orelse
                    return error_catalog.raise(.lib_not_found, .{}, .{ .ns = spec.ns_name });
                try loader.loadNamespace(rt, env, spec.ns_name, resolved, .{});
                break :blk env.findNs(spec.ns_name) orelse
                    return error_catalog.raise(.lib_not_found, .{}, .{ .ns = spec.ns_name });
            };
            const here = env.current_ns orelse
                return error_catalog.raise(.current_namespace_missing, .{}, .{ .sym = spec.ns_name });
            if (spec.alias) |alias_name| {
                try env.setAlias(here, alias_name, target_ns);
            }
            if (spec.refer_all) {
                // `:refer :all` / `:use` — refer every public var,
                // honouring a `:exclude` blacklist when present.
                try env.referAllWithFilter(target_ns, here, spec.exclude, null);
            }
            for (spec.refers) |refer_name| {
                const outcome = try env.referOne(target_ns, here, refer_name);
                switch (outcome) {
                    .installed => {},
                    .private_blocked => {
                        const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ spec.ns_name, refer_name });
                        defer rt.gpa.free(full);
                        return error_catalog.raise(.private_access_error, .{}, .{
                            .sym = full,
                            .ns = spec.ns_name,
                        });
                    },
                    .not_found => {
                        const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ spec.ns_name, refer_name });
                        defer rt.gpa.free(full);
                        return error_catalog.raise(.symbol_unresolved, .{}, .{ .sym = full });
                    },
                }
            }
            if (sp >= stack.len)
                return raiseInternal("vm: operand stack overflow");
            stack[sp] = Value.nil_val;
            sp += 1;
        },
        .op_vector_literal => {
            // Closes D-060: pop N values from top of stack, build a
            // PersistentVector, push result.
            const n: u16 = instr.operand;
            if (sp < n) return raiseInternal("vm: op_vector_literal underflows operand stack");
            // PERF: one-shot bulk build (fromSlice) instead of empty + N×conj
            // (which allocated N throwaway intermediate vectors). The elements
            // stay rooted on the operand stack `stack[sp-n..sp]` across the
            // build (op_top watermark). Mirrors O-026's VM-only map fast path.
            // [refs: O-040]
            const v = try vector_mod.fromSlice(rt, stack[sp - n .. sp]);
            sp -= n;
            stack[sp] = v;
            sp += 1;
        },
        .op_map_literal => {
            // Closes D-059: pop N stack values (= 2 * pair_count),
            // assoc k/v pairs in source order into an empty
            // ArrayMap, push result.
            const n: u16 = instr.operand;
            if (sp < n) return raiseInternal("vm: op_map_literal underflows operand stack");
            const pairs = stack[sp - n .. sp];
            // PERF: D-386 (O-026) one-alloc array-map build for the common
            // small-literal-with-simple-keys case (gc_stress: `{:a i :b … :c …}`
            // ×100k), instead of an N-deep assoc fold that copies the ArrayMap each
            // step. Guarded so the dedup keyEq is pure (no GC during the fill).
            // Else (HAMT-size, or custom-= keys) the assoc fold. [refs: O-026]
            if (n >= 2 and n <= 2 * map_mod.ARRAY_MAP_THRESHOLD and map_mod.allSimpleKeys(pairs)) {
                const result = try map_mod.fromLiteralPairs(rt, pairs);
                sp -= n;
                stack[sp] = result;
                sp += 1;
            } else {
                var m = map_mod.empty();
                var i: u16 = sp - n;
                while (i < sp) : (i += 2) {
                    m = try map_mod.assoc(rt, m, stack[i], stack[i + 1]);
                }
                sp -= n;
                stack[sp] = m;
                sp += 1;
            }
        },
        .op_set_literal => {
            // Closes D-061: pop N values, conj-fold into an empty
            // HashSet (duplicates collapse), push result.
            const n: u16 = instr.operand;
            if (sp < n) return raiseInternal("vm: op_set_literal underflows operand stack");
            var s = set_mod.empty();
            var i: u16 = sp - n;
            while (i < sp) : (i += 1) {
                s = try set_mod.conj(rt, s, stack[i]);
            }
            sp -= n;
            stack[sp] = s;
            sp += 1;
        },
        .op_ctor_call => {
            // operand = index into the ctor_sites side-table (D-233; the
            // class name carries full width, no 8-bit name_idx packing).
            if (instr.operand >= chunk.ctor_sites.len)
                return raiseInternal("vm: op_ctor_call site index out of range");
            const ctor = chunk.ctor_sites[instr.operand];
            const type_name = ctor.type_name;
            const arg_count: u16 = ctor.arg_count;
            if (sp < arg_count) return raiseInternal("vm: op_ctor_call underflow");
            const args_slice = stack[sp - arg_count .. sp];
            // Shared resolver/dispatcher (deftype/record + java-surface
            // `<init>`) — identical to TreeWalk's evalConstructorCall so a
            // `(java.io.File. …)` ctor works on both backends (D-196
            // blocker 3; was a deftype-only rt.types.get path here).
            const new_val = try special_forms.constructInstance(rt, env, type_name, args_slice, .{});
            sp -= arg_count;
            stack[sp] = new_val;
            sp += 1;
        },
        .op_method_call => {
            // operand = call_site_idx. ADR-0050 am1: the unified
            // instance-member resolver runs field-first (deftype/record
            // field_layout), then method_table; `field_only` (the
            // `.-name` form) stops after the field attempt. This folds
            // the retired op_field_access in, and lets native receivers
            // (field_layout == null) reach method_table for `(.m str)`.
            if (instr.operand >= chunk.call_sites.len)
                return raiseInternal("vm: op_method_call call_site index out of range");
            const cs_entry = &chunk.call_sites[instr.operand];
            const arg_count: u16 = cs_entry.arg_count;
            if (sp < arg_count) return raiseInternal("vm: op_method_call underflow");
            const receiver = stack[sp - arg_count];
            const td: *const td_mod.TypeDescriptor = if (receiver.tag() == .typed_instance) blk: {
                break :blk receiver.decodePtr(*const td_mod.TypedInstance).descriptor;
            } else if (receiver.tag() == .reified_instance) blk: {
                break :blk receiver.decodePtr(*const td_mod.ReifiedInstance).descriptor;
            } else if (receiver.tag() == .host_instance) blk: {
                // ADR-0106: a stateful host object carries its surface descriptor inline.
                break :blk @import("../../runtime/host_instance.zig").asHostInstance(receiver).descriptor;
            } else try rt.nativeDescriptor(receiver.tag());

            // FIELD-FIRST: a non-null field_layout implies the receiver
            // is a .typed_instance (reify + native carry null), so the
            // decode below is safe.
            const field_val: ?Value = if (td.field_layout) |layout| fblk: {
                for (layout) |fe| {
                    if (std.mem.eql(u8, fe.name, cs_entry.method_name))
                        break :fblk receiver.decodePtr(*const td_mod.TypedInstance).fields()[fe.index];
                }
                break :fblk null;
            } else null;

            if (field_val) |fv| {
                sp -= arg_count;
                stack[sp] = fv;
                sp += 1;
            } else if (cs_entry.field_only) {
                return error_catalog.raise(.symbol_unresolved, .{}, .{ .sym = cs_entry.method_name });
            } else {
                if (cs_entry.cache.lookupWithCache(td, null, cs_entry.method_name, rt.protocol_generation)) |me| {
                    if (me.method_val.tag() == .nil)
                        return error_catalog.raise(.feature_not_supported, .{}, .{ .name = "method declared but not implemented" });
                    const args_slice = stack[sp - arg_count .. sp];
                    const vt = rt.vtable orelse return error.NoVTable;
                    const result = try vt.callFn(rt, env, me.method_val, args_slice, .{});
                    sp -= arg_count;
                    stack[sp] = result;
                    sp += 1;
                } else if (try object_method.tryObjectMethod(rt, env, receiver, td, cs_entry.method_name, stack[sp - arg_count + 1 .. sp])) |r| {
                    // Universal java.lang.Object method fallback (D-207):
                    // str/=/hash/class — mirrors TreeWalk's evalInstanceMember.
                    sp -= arg_count;
                    stack[sp] = r;
                    sp += 1;
                } else if (try clojure_lang_method.tryClojureLangMethod(rt, env, receiver, cs_entry.method_name, stack[sp - arg_count + 1 .. sp], .{})) |r| {
                    // clojure.lang read/op methods on a native collection (D-371):
                    // .valAt/.cons/.count/… → the clojure.core equivalent.
                    sp -= arg_count;
                    stack[sp] = r;
                    sp += 1;
                } else {
                    return error_catalog.raise(.protocol_no_satisfies, .{}, .{
                        .protocol = "<.member>",
                        .method = cs_entry.method_name,
                        .type_name = td.fqcn orelse "<anonymous>",
                    });
                }
            }
        },
        .op_static_method_call => {
            // operand = call_site_idx. ADR-0050 am2 (D-130): static
            // dispatch — the descriptor is the analyze-time pointer in
            // the call-site (no receiver to derive it from). Raw
            // `lookupMethod` matches TreeWalk's evalStaticMethodCall
            // (no CallSite cache); arg_count is user args only.
            if (instr.operand >= chunk.call_sites.len)
                return raiseInternal("vm: op_static_method_call call_site index out of range");
            const cs_entry = &chunk.call_sites[instr.operand];
            const arg_count: u16 = cs_entry.arg_count;
            if (sp < arg_count) return raiseInternal("vm: op_static_method_call underflow");
            const td = cs_entry.descriptor orelse
                return raiseInternal("vm: op_static_method_call missing descriptor (compiler bug)");
            const me = td.lookupMethod(null, cs_entry.method_name) orelse {
                return error_catalog.raise(.protocol_no_satisfies, .{}, .{
                    .protocol = "<static>",
                    .method = cs_entry.method_name,
                    .type_name = td.fqcn orelse "<anonymous>",
                });
            };
            if (me.method_val.tag() == .nil)
                return error_catalog.raise(.feature_not_supported, .{}, .{ .name = "static method declared but not implemented" });
            const args_slice = stack[sp - arg_count .. sp];
            const vt = rt.vtable orelse return error.NoVTable;
            const result = try vt.callFn(rt, env, me.method_val, args_slice, .{});
            sp -= arg_count;
            stack[sp] = result;
            // Result loc = this call form (pops below sp_entry, so the sweep misses it).
            loc_stack[sp] = instr_loc;
            sp += 1;
        },
    }
    // ADR-0118 cycle 2.5: every operand this instruction newly pushed inherits
    // its compiled source loc, so a later `op_call` can read each arg's column.
    // (`op_call` pops before it pushes, so its result slot sits below `sp_entry`
    // and is set explicitly in its own arm — not by this sweep.)
    var pushed = sp_entry;
    while (pushed < sp) : (pushed += 1) loc_stack[pushed] = instr_loc;
    return null;
}

fn matchExceptionClass(class_name: []const u8, thrown: Value) bool {
    // Row 7.11 cycle 2 (D-077): delegate to the shared host-class
    // hierarchy table in `runtime/error/host_class.zig`. Mirror of
    // tree_walk.catchMatches:671 — both backends share the predicate.
    return host_class.matches(thrown, class_name);
}

fn matchExceptionTypeKeyword(rt: *Runtime, kw_val: Value, thrown: Value) bool {
    // Row 14.5 (D-014b): keyword catch matches when `thrown` is an ex-info
    // whose data map's `:type` equals the catch keyword (interned
    // identity). Mirror of tree_walk.catchMatches `.type_keyword` arm.
    if (thrown.tag() != .ex_info) return false;
    const data_v = ex_info_mod.data(thrown);
    const type_kw = keyword_mod.intern(rt, null, "type") catch return false;
    const got = map_mod.get(data_v, type_kw) catch return false;
    return @intFromEnum(got) == @intFromEnum(kw_val);
}

fn raiseInternal(comptime detail: []const u8) anyerror {
    return error_catalog.raiseInternal(.{}, detail);
}

fn templateMethodsHaveAnyMissingChunk(template: *const tree_walk.Function) bool {
    for (template.methods) |m| {
        if (m.bytecode == null) return true;
    }
    if (template.variadic) |v| if (v.bytecode == null) return true;
    return false;
}

/// Populate `rt.vtable` for the VM backend. The
/// `callFn` reuses `tree_walk.treeWalkCall` because the dispatch shape
/// per `Value.Tag` is identical across backends; the per-fn divergence
/// happens inside `tree_walk.callFunction`, which routes through the
/// new `evalChunk` vtable slot when the callee's `Function.bytecode`
/// is non-null. TreeWalk's `installVTable` leaves `evalChunk = null`,
/// so the two backends differ only in this single function-pointer
/// slot.
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &tree_walk.treeWalkCall,
        .valueTypeKey = &tree_walk.valueTypeKey,
        .evalChunk = &evalChunkErased,
    };
}

/// Trampoline that casts the Layer-0 `*const anyopaque` chunk pointer
/// back to `*const BytecodeChunk` (the concrete VM type) so the vtable
/// stays Layer-0-only (per `zone_deps.md`).
///
/// `pub` so `driver.installVTable` can wire it into the **tree_walk**
/// vtable too (ADR-0056 Cycle 0): a tree_walk-default runtime must
/// dispatch bytecode-backed fns (AOT-restored bootstrap / `cljw build`)
/// on the VM via the per-method `bytecode`/`body` hybrid
/// (`tree_walk.zig:1004`). Inert until a bytecode fn exists in the
/// runtime (pure-source tree_walk fns have `bytecode == null`).
pub fn evalChunkErased(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const anyopaque,
) anyerror!Value {
    return eval(rt, env, locals, @ptrCast(@alignCast(chunk)));
}

fn applyJump(ip: usize, offset: i16) ?usize {
    if (offset >= 0) {
        return ip + @as(usize, @intCast(offset));
    }
    const back = @as(usize, @intCast(-@as(i32, offset)));
    if (back > ip) return null;
    return ip - back;
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var f: Fixture = undefined;
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.env = try Env.init(&f.rt);
        tree_walk.installVTable(&f.rt);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn run(self: *Fixture, chunk: *const BytecodeChunk) anyerror!Value {
        var locals: [256]Value = [_]Value{.nil_val} ** 256;
        return eval(&self.rt, &self.env, &locals, chunk);
    }
};

test "op_const then op_ret returns the constant" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_pop discards the top of the operand stack" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_pop },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_dup duplicates the top of the operand stack" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_dup },
        .{ .opcode = .op_pop },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_store_local then op_load_local round-trips a slot" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_store_local, .operand = 7 },
        .{ .opcode = .op_load_local, .operand = 7 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_load_local out of range raises index_error" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_load_local, .operand = 1000 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.IndexError, f.run(&chunk));
}

test "op_jump unconditionally skips forward" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // op_jump +1 ; op_const false (skipped) ; op_const true ; op_ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_jump, .operand = @as(u16, @bitCast(@as(i16, 1))) },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_jump_if_false takes the jump when popped value is false" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // op_const false ; op_jump_if_false +1 ; op_const true (skipped) ; op_const false ; op_ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_jump_if_false, .operand = @as(u16, @bitCast(@as(i16, 1))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.false_val, try f.run(&chunk));
}

test "op_jump_if_false falls through when popped value is truthy" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // (if true true false): push true cond ; jump_if_false +2 (no jump) ;
    // push true ; ret ; push false ; ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_jump_if_false, .operand = @as(u16, @bitCast(@as(i16, 2))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_def interns the name into env.current_ns and pushes the Var" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const name_val = try string_mod.alloc(&f.rt, "answer");
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_def, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ name_val, Value.true_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    const result = try f.run(&chunk);
    try testing.expectEqual(value_mod.Value.Tag.var_ref, result.tag());
    const var_ptr = result.decodePtr(*Var);
    try testing.expectEqualStrings("answer", var_ptr.name);
    try testing.expectEqual(Value.true_val, var_ptr.deref());
    try testing.expect(!var_ptr.flags.dynamic);
}

test "op_def stamps dynamic / macro / private flags from the operand" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const name_val = try string_mod.alloc(&f.rt, "foo");
    const packed_operand: u16 = 0 | opcode_mod.DEF_FLAG_DYNAMIC | opcode_mod.DEF_FLAG_PRIVATE;
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_def, .operand = packed_operand },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ name_val, Value.nil_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    const result = try f.run(&chunk);
    const var_ptr = result.decodePtr(*Var);
    try testing.expect(var_ptr.flags.dynamic);
    try testing.expect(!var_ptr.flags.macro_);
    try testing.expect(var_ptr.flags.private);
}

test "op_get_var dereferences a Var pointer from the constant pool" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ns = f.env.current_ns.?;
    const var_ptr = try f.env.intern(ns, "x", Value.true_val, null);
    const var_value = Value.encodeHeapPtr(.var_ref, var_ptr);

    const instrs = [_]Instruction{
        .{ .opcode = .op_get_var, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{var_value};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_call routes through rt.vtable.callFn" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ns = f.env.current_ns.?;
    const builtin_val = Value.initBuiltinFn(@as(dispatch.BuiltinFn, &testReturnFirstArg));
    _ = try f.env.intern(ns, "first-arg", builtin_val, null);

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_const, .operand = 2 },
        .{ .opcode = .op_call, .operand = 2 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ builtin_val, Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_make_fn snapshots locals when template.slot_base > 0" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // Build a template Function with slot_base = 1, body returns
    // local 0 (which the closure snapshot will provide).
    const body: node_mod.Node = .{ .local_ref = .{ .name = "x", .index = 0 } };
    const methods = [_]node_mod.FnMethod{.{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
    }};
    const fn_node = node_mod.FnNode{
        .methods = &methods,
        .slot_base = 1,
    };
    // The template's bytecode body needs to actually produce a value;
    // a one-op chunk that loads local 0 + returns suffices.
    const template_instrs = [_]Instruction{
        .{ .opcode = .op_load_local, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const template_chunk: BytecodeChunk = .{
        .instructions = &template_instrs,
        .constants = &.{},
    };
    const method_chunks = [_]?*const BytecodeChunk{&template_chunk};
    const template_val = try tree_walk.allocFunctionTemplate(&f.rt, fn_node, &method_chunks, null);

    // Outer chunk: load local 5 (which the caller seeds with true),
    // make a closure (snapshot), then read its closure_bindings[0]
    // directly to verify the snapshot captured the right thing.
    const instrs = [_]Instruction{
        .{ .opcode = .op_make_fn, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{template_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    var locals: [256]Value = [_]Value{.nil_val} ** 256;
    locals[0] = Value.true_val;
    const result = try eval(&f.rt, &f.env, &locals, &chunk);

    try testing.expectEqual(value_mod.Value.Tag.fn_val, result.tag());
    const closure_fn = result.decodePtr(*const tree_walk.Function);
    try testing.expect(closure_fn.closure_bindings != null);
    try testing.expectEqual(@as(usize, 1), closure_fn.closure_bindings.?.len);
    try testing.expectEqual(Value.true_val, closure_fn.closure_bindings.?[0]);
    // The template itself must NOT have been mutated.
    const template_fn = template_val.decodePtr(*const tree_walk.Function);
    try testing.expect(template_fn.closure_bindings == null);
}

test "op_recur with insufficient stack raises internal_error" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_recur, .operand = 3 },
        .{ .opcode = .op_ret },
    };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &.{} };

    try testing.expectError(error.InternalError, f.run(&chunk));
}

test "op_make_fn pushes the pre-allocated Function from the constants pool" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const body: node_mod.Node = .{ .constant = .{ .value = Value.true_val } };
    const methods = [_]node_mod.FnMethod{.{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
    }};
    const fn_node = node_mod.FnNode{
        .methods = &methods,
        .slot_base = 0,
    };
    const fn_val = try tree_walk.allocFunction(&f.rt, fn_node, &.{});

    const instrs = [_]Instruction{
        .{ .opcode = .op_make_fn, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{fn_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(fn_val, try f.run(&chunk));
}

test "op_throw sets dispatch.last_thrown_exception and returns ThrownValue" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.ThrownValue, f.run(&chunk));
    try testing.expectEqual(Value.true_val, dispatch.last_thrown_exception.?);
    dispatch.last_thrown_exception = null;
}

test "op_invoke_builtin raises unsupported_feature (4.6 placeholder)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_invoke_builtin, .operand = 0 },
    };
    const constants = [_]Value{Value.nil_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.NotImplemented, f.run(&chunk));
}

fn testReturnFirstArg(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    if (args.len == 0) return Value.nil_val;
    return args[0];
}

test "op_push_handler routes thrown value into the catch arm" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    // op_push_handler +3 ; op_const ex ; op_throw ; op_pop_handler (unreachable) ; <handler> op_ret
    const ex_val = try ex_info_mod.alloc(&f.rt, "boom", Value.nil_val, Value.nil_val);
    const instrs = [_]Instruction{
        .{ .opcode = .op_push_handler, .operand = @as(u16, @bitCast(@as(i16, 3))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
        .{ .opcode = .op_pop_handler },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ex_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(ex_val, try f.run(&chunk));
    try testing.expect(dispatch.last_thrown_exception == null);
}

test "op_pop_handler removes the innermost handler so thrown propagates" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const instrs = [_]Instruction{
        .{ .opcode = .op_push_handler, .operand = @as(u16, @bitCast(@as(i16, 4))) },
        .{ .opcode = .op_pop_handler },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ex_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.ThrownValue, f.run(&chunk));
    try testing.expectEqual(ex_val, dispatch.last_thrown_exception.?);
    dispatch.last_thrown_exception = null;
}

test "op_match_class returns true for ExceptionInfo vs ex_info tag" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const class_val = try string_mod.alloc(&f.rt, "ExceptionInfo");

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_match_class, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ ex_val, class_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_match_class returns false for unknown class names" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const class_val = try string_mod.alloc(&f.rt, "IndexOutOfBoundsException");

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_match_class, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ ex_val, class_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.false_val, try f.run(&chunk));
}

test "vm.eval back-edge poll parks a worker mid-eval during a stop-the-world (D-244 #4)" {
    const io_default = @import("../../runtime/concurrency/io_default.zig");
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Route the safepoint sync through the same threaded io as the runtime so the
    // Io.Mutex/Condition block for real across threads (restored LIFO).
    const saved_io = io_default.get();
    defer io_default.set(saved_io);
    io_default.set(f.threaded.io());

    // A trivial alloc-free chunk the worker re-evaluates in a tight loop, so the
    // ONLY safe point it can reach is the back-edge poll (no alloc-prologue park).
    const instrs = [_]Instruction{ .{ .opcode = .op_const, .operand = 0 }, .{ .opcode = .op_ret } };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    const Shared = struct {
        var rt: *Runtime = undefined;
        var env: *Env = undefined;
        var chunk_ptr: *const BytecodeChunk = undefined;
        var ready: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);

        fn worker() void {
            var ctx: root_set.ThreadGcContext = .{
                .frame_slot = &env_mod.current_frame,
                .macro_slot = &root_set.macro_root_slot,
                .eval_frame_slot = &root_set.eval_frame_head,
                .self_guard_slot = &root_set.gc_self_guard,
            };
            root_set.registerThread(&ctx) catch return;
            defer root_set.unregisterThread(&ctx);
            var locals: [256]Value = [_]Value{.nil_val} ** 256;
            ready.store(true, .release);
            // Continuously in `eval`, so the back-edge poll is always being checked
            // — arming `gc_requested` deterministically catches the worker mid-eval.
            while (!done.load(.acquire)) {
                _ = eval(rt, env, &locals, chunk_ptr) catch break;
            }
        }
    };
    Shared.rt = &f.rt;
    Shared.env = &f.env;
    Shared.chunk_ptr = &chunk;
    Shared.ready.store(false, .monotonic);
    Shared.done.store(false, .monotonic);

    var t = try std.Thread.spawn(.{}, Shared.worker, .{});
    while (!Shared.ready.load(.acquire)) std.atomic.spinLoopHint();

    // stopWorld returns ONLY once the worker has parked at the back-edge poll
    // (target = registeredThreadCount() = 1). If the poll were broken the worker
    // would never park and this would hang (caught by the gate timeout).
    safepoint.stopWorld(false);
    safepoint.resumeWorld();
    Shared.done.store(true, .release);
    t.join();
    try testing.expect(!safepoint.gc_requested.load(.acquire));
}
