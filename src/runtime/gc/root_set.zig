// SPDX-License-Identifier: EPL-2.0
//! Root-set enumeration for cw v1 mark-sweep GC per ADR-0028 §5.
//!
//! Wires the 3 entry-point root walkers that exist in cw v1 (ADR-0028
//! §5 amendment 2 / ADR-0091):
//!
//!   1. **ns_vars**       — Namespace `Var.root` + `Var.meta` +
//!                        `Var.watches` across every registered Env
//!                        (`WalkContext.envs`). `Var.watches` is reachable
//!                        ONLY here (a `var_ref` is GC-membrane-filtered).
//!   2. **thread_roots**  — per-thread execution roots, walked for the
//!                        collecting thread + every registered worker
//!                        `ThreadGcContext`: its dynamic-binding frame
//!                        chain (`env.zig current_frame`), its VM
//!                        operand-stack frame chain (`vm.eval`
//!                        `stack[0..sp]` + `locals`), its in-flight
//!                        fabrication self-guard (`gc_self_guard`), and
//!                        its analysis-frame chain (`analysis_frame_head`,
//!                        D-430 — refusing cw v0's `suppressCollection`
//!                        escape hatch per F-002 + F-006). Layer 0 owns
//!                        the threadlocal slots; Layer 1 (vm / analyzer)
//!                        writes them via downward import. Subsumes the
//!                        former `current_frame` (#2) + `macro_root_slot`
//!                        (#7, retired — the analysis frame carries the
//!                        macro-expansion intermediates).
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
//! Such a registry would require changing `Env.init`'s return shape
//! (currently by-value; the registry needs a stable `*Env` address),
//! so the explicit slice is the finished form here — there is no
//! auto-registry in cw v1.

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

/// Identifier for one of the 9 root sources enumerated by the mark
/// phase (ADR-0028 §5 amendment 2 / ADR-0091). Only `ns_vars` /
/// `thread_roots` / `permanent_roots` yield roots; the others are
/// either tag-trace entries (`fn_closures` / `lazy_seqs` /
/// `typed_instances`) or no-op-by-construction (`protocol_caches` /
/// `refer_borrows` / `callsite_methods`).
pub const RootSource = enum {
    ns_vars,
    /// Per-thread execution roots: binding-frame chain + VM operand-stack
    /// frame chain + in-flight fabrication self-guard + analysis-frame
    /// chain (D-430), for the collecting thread (self TLS) + every
    /// registered worker `ThreadGcContext`. Subsumes the former
    /// `current_frame` (#2) + `macro_root_slot` (#7, retired).
    thread_roots,
    fn_closures, // tag-trace entry — see tag_ops.tag_trace_table[.fn_val]
    lazy_seqs, // tag-trace entry — see 5.7 registration
    protocol_caches, // no live structs in cw v1; Phase 7 entry territory
    refer_borrows, // closed at construction in env.zig:229 referAll
    typed_instances, // tag-trace entry — see 5.11 registration
    callsite_methods, // cache holds namespace-owned pointers; no GC edge
    permanent_roots,
};

/// (The former `macro_root_slot` — ADR-0028 §5 row 7 — was retired with the
/// D-430 analysis-roots frame: it never gained a production writer, and the
/// frame subsumes its declared purpose — `expandIfMacro` now pushes the
/// macro-expansion intermediates + result into the current AnalysisFrame.)
/// One operand-stack-resident root scope, published on the thread's
/// eval-frame chain so a GC `collect()` walks live operand Values
/// (`stack[0..sp]`) + slot Values (`locals`) — ADR-0091. Two kinds of
/// producer push these (ADR-0094): (1) every `vm.eval` activation
/// (`op_call -> callMethodImpl -> evalChunkErased -> eval`), each a fresh
/// Zig-local `stack`/`locals`; and (2) a reentrant Layer-2 primitive that
/// holds GC accumulators across a call back into `eval` (e.g. `reduceFn`
/// pushes a 2-slot `[acc, cur]` frame, `locals = &.{}`). Layer 0 owns the
/// struct + threadlocal head; Layer 1/2 push/`defer`-pop a frame via
/// downward import. Fields are raw `Value` pointers (no VM-type leak into
/// Layer 0): `stack`/`sp` are read together at walk time as
/// `stack[0..sp.*]` — the array is `undefined` above `sp`, so the walker
/// must NOT read past it; `locals` must be fully nil-initialised (or empty)
/// so the whole slice is walk-safe (immediates skipped).
pub const EvalFrame = struct {
    stack: [*]const Value,
    sp: *const u16,
    locals: []const Value,
    /// The executing chunk's constant pool (D-251). Bytecode literal
    /// constants (string / collection literals) are GC-allocated but stored in
    /// the chunk's pool, which lives in the analyser arena and is itself NOT a
    /// GC object — so a literal is reachable ONLY through the pool until an
    /// `op_const` loads it onto `stack`. A collect firing BEFORE that load (the
    /// torture case) would sweep the still-unloaded literal, so `op_const` then
    /// pushes a dangling pointer. Publishing the whole pool here roots every
    /// literal for the chunk's entire execution. Empty (`&.{}`) for a
    /// primitive-pushed frame (e.g. `reduceFn`) that owns no chunk. `var_ref` /
    /// `ns` constants are skipped by `Value.heapHeader()` like everywhere else.
    constants: []const Value = &.{},
    parent: ?*EvalFrame,
};

/// Head of the current thread's eval-frame chain (see `EvalFrame`).
/// Null between top-level evaluations; non-null while a `vm.eval` is on
/// the C stack. Threadlocal: each worker publishes its own head through
/// a `ThreadGcContext.eval_frame_slot` pointer (union walk).
pub threadlocal var eval_frame_head: ?*EvalFrame = null;

/// Analysis-roots frame (D-430 root cause; EvalFrame's analysis-side
/// sibling): GC Values produced BEFORE any frame executes — literal strings /
/// quoted data (`analyzer.makeConstant` / `analyzeQuote`), compiler-alloc'd
/// name strings (`Compiler.addConstant`), deserialized AOT constants
/// (`serialize.deserializeChunk`), and the macro-expansion result Value —
/// live only in arena `Node`s / arena constant slices, none of which is a GC
/// object, so they were on NO root until execution (`EvalFrame.constants`
/// roots a chunk's pool only WHILE IT RUNS). A collect in the window — a
/// user-macro expansion mid-analysis (arbitrary eval reentry), or the D-519
/// alloc-boundary auto-collect crossing the threshold mid-analysis of a large
/// in-eval load — swept the literal; the cell got recycled and the form later
/// read another value's bytes (instaparse's per-run garbage-symbol NameError;
/// the deftype "host-marker method not yet wired" raise on a wired method).
///
/// Discipline: every analyze/compile/deserialize→eval bracket owns a frame
/// on its C stack (`beginAnalysis`/`defer endAnalysis`); producers push into
/// the HEAD frame and ASSERT a frame exists (safe builds) — a producer
/// running outside any bracket is a caught bug, not a silent unrooted
/// window. Nesting (load-within-load, macro-triggered analysis, the
/// top-level `do` unroll) is the parent chain; error unwind is the `defer`.
/// A frame's roots stay published through the form's EVALUATION too (the
/// bracket closes after eval), which also covers tree_walk Node constants
/// (no EvalFrame constants slice on that backend).
pub const AnalysisFrame = struct {
    roots: std.ArrayList(Value) = .empty,
    /// Allocator the frame's root list grows on (the process-lifetime
    /// `gc.infra`), captured at `beginAnalysis` so producers push with no
    /// allocator/rt threading (`makeConstant`'s ~20 call sites unchanged).
    alloc: std.mem.Allocator,
    parent: ?*AnalysisFrame = null,
};

/// Head of the current thread's analysis-frame chain. Null only while no
/// analyze/compile/deserialize bracket is on the C stack.
pub threadlocal var analysis_frame_head: ?*AnalysisFrame = null;

/// Open an analysis bracket: chain `frame` (caller stack memory) as the new
/// head. `alloc` = the process-lifetime `gc.infra`. Pair with
/// `defer endAnalysis(&frame)`.
pub fn beginAnalysis(frame: *AnalysisFrame, alloc: std.mem.Allocator) void {
    frame.* = .{ .roots = .empty, .alloc = alloc, .parent = analysis_frame_head };
    analysis_frame_head = frame;
}

/// Close an analysis bracket: unchain + free the frame's root list. Frames
/// close LIFO (the C stack guarantees it; asserted in safe builds).
pub fn endAnalysis(frame: *AnalysisFrame) void {
    std.debug.assert(analysis_frame_head == frame);
    analysis_frame_head = frame.parent;
    frame.roots.deinit(frame.alloc);
}

/// Root a Value produced during analysis/compile/deserialize until the
/// owning bracket closes. Immediates / infra-lifetime values (var_ref, ns)
/// are filtered here so the registry holds only real heap objects.
pub fn pushAnalysisRoot(v: Value) !void {
    if (v.heapHeader() == null) return;
    // Safe-build tripwire: a constant producer outside any bracket is an
    // unrooted-window bug at the NEXT collect — fail loud at the source.
    std.debug.assert(analysis_frame_head != null);
    const f = analysis_frame_head orelse return;
    try f.roots.append(f.alloc, v);
}

/// In-flight fabrication self-guard (ADR-0090 "D-244 decision" Alt B,
/// #3b-step2b). A bytecode op that assembles a collection from already-
/// computed operand-stack values (`op_vector_literal` / `op_map_literal`
/// / `op_set_literal`, and `callMethodImpl`'s rest-list cons-wrap) holds
/// its partial accumulator in a Zig local ACROSS the next `conj`/`assoc`
/// alloc — NOT on `stack[0..sp]`. If that alloc triggers a collection
/// (the thread's own, or a peer's via the #3b-step2 safepoint while this
/// thread is parked at its `alloc` entry), the un-installed partial is
/// invisible to the operand-stack walk → swept → UAF. The fabrication
/// loop sets this slot to the partial before each alloc and clears it
/// after the result lands on the stack. A SINGLE slot (not a stack)
/// suffices: the Q1 ops assemble values already on `stack[0..sp]`, with
/// no nested `eval`/fabrication inside the assembly loop — mirroring
/// analysis frames. Walked per-thread (self + every registered worker:
/// a parked worker mid-fabrication holds its partial here too, so it is
/// NOT "collecting-thread only" despite the D-244 name). This slot
/// publishes a precise root for a partial *Value* across an eval-reentrant
/// trigger — it refuses cw v0's *un-scoped* `suppressCollection` hatch (the
/// one that could wrap eval-reentry, the real F-006 hazard). It does NOT
/// speak to builder-INTERNAL raw nodes (`*TailNode`/`*HamtNode`/`*Cons`):
/// those are covered by ADR-0150's bounded `fabrication_depth` no-collect
/// region around pure-Zig builders (no user code, no eval-reentry) — a
/// different hazard class, correct under F-006. This slot's set/clear wiring
/// lands with the worker/auto-collect trigger (#4); the slot + its walk are
/// the runtime-inert infra until then.
pub threadlocal var gc_self_guard: ?Value = null;

/// The `Env` the current thread's outermost `vm.eval` is running under, or null
/// when no VM eval is on the C stack. The VM publishes it (set on entry, restore
/// on exit) ONLY so the alloc-driven GC torture (`gc_torture.allocTick`, D-386)
/// can build a `WalkContext` for a collect forced from inside `gc.alloc` — that
/// path has only `*GcHeap`, no `env`. Outside a VM eval it stays null and the
/// alloc-torture collect is skipped (no root context). It is NOT a production
/// root source (the collect's roots come from the env passed explicitly); it is
/// validation-mode plumbing, inert unless `CLJW_GC_TORTURE_ALLOC` is armed.
pub threadlocal var active_env: ?*Env = null;

// =====================================================================
// Worker-thread GC-root registry (ADR-0090 "D-244 decision", Alt B).
//
// A Phase-B `future`/`pmap`/`agent` WORKER thread registers a
// `ThreadGcContext` pointing at its own `env.current_frame` +
// analysis-frame threadlocal slots (and, at #3b, its VM operand-stack
// frame chain), so a `collect()` running on ANOTHER thread can walk the
// UNION of every live thread's roots — not just the collecting thread's.
// The collecting/main thread reads its own TLS directly (see
// `nextCurrentFrame`/`nextMacroRoot`) and does NOT register, so there is
// no double-walk. Runtime-inert until real threads land (#4): with an
// empty registry the walk is byte-identical to today's single-thread
// behaviour. The registry lives HERE (not a separate `concurrency/
// gc_thread.zig`) because it must reference the TLS root slots, which this
// module owns — a separate module would import root_set while root_set
// imports it (cycle). A fixed array (not an ArrayList) keeps it
// allocator-free and immune to resize-during-walk.
// =====================================================================

const io_default = @import("../concurrency/io_default.zig");
const safepoint = @import("../concurrency/safepoint.zig");

/// Max concurrently-registered worker threads. Phase-B `pmap`/`agent`
/// pools are CPU-bounded; 64 is generous headroom.
pub const MAX_GC_THREADS = 64;

/// One worker thread's published GC roots. The four slots point at that
/// thread's `env.current_frame` / `analysis_frame_head` / `eval_frame_head` /
/// `gc_self_guard` TLS so the collector reads each worker's CURRENT roots
/// through the pointers (ADR-0091 — `eval_frame_slot` is the VM operand-
/// stack chain head added at #3b-step1; `self_guard_slot` is the in-flight
/// fabrication partial added at #3b-step2b).
/// Default `tx_slot` target for a worker not running STM — a static null so the
/// existing 4-slot construction sites need no change (only the `future`/`agent`
/// workers, which CAN run a `dosync`, point `tx_slot` at their `lock_tx.current_tx`).
var no_tx: ?*anyopaque = null;
/// Default `analysis_frame_slot` target for a worker that never analyzes code.
var no_analysis_frame: ?*AnalysisFrame = null;

pub const ThreadGcContext = struct {
    frame_slot: *const ?*env_mod.BindingFrame,
    eval_frame_slot: *const ?*EvalFrame,
    self_guard_slot: *const ?Value,
    /// The worker's `analysis_frame_head` TLS chain (D-430). Defaults to a
    /// static null so the existing construction sites need no change — only
    /// a worker that ANALYZES code (eval/load-string on a future/agent
    /// thread) points it at its own `root_set.analysis_frame_head`.
    analysis_frame_slot: *const ?*AnalysisFrame = &no_analysis_frame,
    /// OPAQUE pointer to the worker's `lock_tx.current_tx` (#4a' in-txn-map
    /// rooting). Opaque so root_set does NOT import lock_tx (cycle: lock_tx →
    /// safepoint → root_set); `mark_sweep` (which MAY import lock_tx) casts it.
    tx_slot: *const ?*anyopaque = &no_tx,
};

var thread_registry: [MAX_GC_THREADS]?*ThreadGcContext = @splat(null);
var registry_mutex: std.Io.Mutex = .init;

/// Live registered-worker count, mirroring the non-null slots in
/// `thread_registry`. Maintained under `registry_mutex` (register/unregister)
/// but exposed lock-free via `registeredCountRelaxed` so `safepoint.stopWorld`
/// can re-read the rendezvous target while holding `sp_mutex` — taking
/// `registry_mutex` under `sp_mutex` would invert the lock order against the
/// unregister path (registry_mutex → sp_mutex wake). The array scan in
/// `registeredThreadCount` stays the SSOT for callers that already hold (or do
/// not need) the precise locked snapshot.
var registered_count: std.atomic.Value(u32) = .init(0);

/// True on a thread that has registered itself as a GC worker (set by
/// `registerThread`, cleared by `unregisterThread`, both running ON the worker
/// thread). The main / unregistered thread leaves it false. Read by the GC
/// torture poll (D-250 / D-244 #4): a WORKER-initiated stop-the-world collect
/// would (a) self-deadlock (`stopWorld` waits for the calling worker to park)
/// and (b) miss the MAIN thread's roots (the collect walks the collecting
/// thread's TLS + registered workers, never the unregistered main) — so torture
/// fires only on the main thread, where the collect parks the workers and walks
/// the complete root set. The worker-initiated multi-thread collect is the
/// dormant D-244 #4 path, validated separately under user awareness.
pub threadlocal var is_registered_worker: bool = false;

/// Register a worker thread's published roots. Locked (workers register
/// at `Thread.spawn`). Returns `error.TooManyThreads` past the cap.
pub fn registerThread(ctx: *ThreadGcContext) error{TooManyThreads}!void {
    io_default.lockMutex(&registry_mutex);
    defer io_default.unlockMutex(&registry_mutex);
    for (&thread_registry) |*slot| {
        if (slot.* == null) {
            slot.* = ctx;
            is_registered_worker = true;
            _ = registered_count.fetchAdd(1, .release);
            return;
        }
    }
    return error.TooManyThreads;
}

/// Deregister a worker thread's context (at `Thread.join`). No-op if absent.
pub fn unregisterThread(ctx: *ThreadGcContext) void {
    is_registered_worker = false;
    var removed = false;
    {
        io_default.lockMutex(&registry_mutex);
        defer io_default.unlockMutex(&registry_mutex);
        for (&thread_registry) |*slot| {
            if (slot.* == ctx) {
                slot.* = null;
                _ = registered_count.fetchSub(1, .release);
                removed = true;
                break;
            }
        }
    }
    // Wake a stop-the-world collector that may be waiting on THIS worker to
    // park: a worker running a tiny action can finish + leave before it ever
    // reaches a safepoint poll, so the collector's rendezvous target must drop
    // by one. Signalled AFTER the count decrement + outside `registry_mutex` so
    // the collector (holding `sp_mutex`, reading the lock-free count) sees the
    // lower target with no lock-order inversion. Without this the collector's
    // `parked_count < target` wait never completes (D-244 #4 hang).
    if (removed) safepoint.noteWorkerLeft();
}

/// Lock-free snapshot of the registered-worker count for `safepoint.stopWorld`'s
/// rendezvous-target recompute (see `registered_count`).
pub fn registeredCountRelaxed() u32 {
    return registered_count.load(.acquire);
}

/// Count of currently-registered worker contexts (test/introspection).
pub fn registeredThreadCount() usize {
    io_default.lockMutex(&registry_mutex);
    defer io_default.unlockMutex(&registry_mutex);
    var n: usize = 0;
    for (thread_registry) |slot| {
        if (slot != null) n += 1;
    }
    return n;
}

/// Mark every registered worker thread's in-transaction roots via `markTxFn`
/// (#4a' in-txn-map rooting). The collector calls this AFTER the root walk.
/// During a stop-the-world collect the workers are parked at safepoints, so the
/// registry + each `tx_slot.*` are quiescent (no `registry_mutex` needed); a
/// single-thread collect sees an empty registry → no-op. `markTxFn` receives the
/// opaque `current_tx` value (the worker's `?*LockingTransaction`, reinterpreted).
pub fn markRegisteredTxs(context: *anyopaque, markTxFn: *const fn (*anyopaque, ?*anyopaque) void) void {
    for (thread_registry) |slot| {
        if (slot) |ctx| markTxFn(context, ctx.tx_slot.*);
    }
}

// Per-thread root addressing (ADR-0091, commonized from #3a's separate
// `frameSourceAt`/`macroSourceAt`): thread index 0 is THIS (collecting) thread's
// TLS, read directly; index `k>=1` is `thread_registry[k-1]` (a registered
// worker), read through its published TLS pointers. `.end` terminates the walk
// past the registry cap. A sparse (null) registry slot yields an all-empty
// contribution and the cursor advances. Reading the registry array during the
// walk is safe because (a) it is empty until Phase-B real threads (#3a/#3b are
// runtime-inert), and (b) the #3b-step2 safepoint guarantees no concurrent
// register/unregister during collect.
const ThreadRoots = struct {
    frame_head: ?*env_mod.BindingFrame,
    eval_head: ?*EvalFrame,
    self_guard: ?Value,
    analysis_head: ?*AnalysisFrame,
};
const ThreadSource = union(enum) { roots: ThreadRoots, end: void };
fn threadContextAt(idx: usize) ThreadSource {
    if (idx == 0) return .{ .roots = .{
        .frame_head = env_mod.current_frame,
        .eval_head = eval_frame_head,
        .self_guard = gc_self_guard,
        .analysis_head = analysis_frame_head,
    } };
    const ri = idx - 1;
    if (ri >= MAX_GC_THREADS) return .end;
    if (thread_registry[ri]) |ctx| return .{ .roots = .{
        .frame_head = ctx.frame_slot.*,
        .eval_head = ctx.eval_frame_slot.*,
        .self_guard = ctx.self_guard_slot.*,
        .analysis_head = ctx.analysis_frame_slot.*,
    } };
    return .{ .roots = .{ .frame_head = null, .eval_head = null, .self_guard = null, .analysis_head = null } };
}

/// Explicit context passed to `enumerate()`. The walker discovers
/// Envs through a caller-supplied slice rather than a `Runtime.envs`
/// auto-registry (there is no such registry in cw v1). `gc` carries
/// the `permanent_roots` source.
pub const WalkContext = struct {
    envs: []const *Env,
    gc: *GcHeap,
};

/// Root-set iterator. Walks the 3 live sources in source order
/// (`ns_vars` → `thread_roots` → `permanent_roots`); the other 6 enum
/// slots advance immediately to the next source per their early-return
/// contract (see RootSource enum docstring for the per-source
/// disposition).
pub const RootIterator = struct {
    ctx: WalkContext,
    source: RootSource = .ns_vars,
    /// Per-source cursor state. Union of state-machine variants;
    /// only the variant matching `source` is active.
    cursor: Cursor = .{ .ns_vars = .{} },

    pub const Cursor = union(enum) {
        ns_vars: NsVarsCursor,
        thread_roots: ThreadRootsCursor,
        empty: void, // every deferred source uses this
        permanent_roots: PermanentRootsCursor,
    };

    pub const NsVarsCursor = struct {
        env_idx: usize = 0,
        ns_it: ?env_mod.NamespaceMap.ValueIterator = null,
        var_it: ?env_mod.VarMap.ValueIterator = null,
        /// Most-recently yielded Var so the iterator can yield its
        /// `meta` slot on the next `next()` call before advancing.
        pending_meta: ?*const env_mod.Var = null,
        /// Same, for the Var's `watches` map (yielded after `meta`): a
        /// `var_ref` is GC-filtered, so its watch fns are reachable for the
        /// collector ONLY here.
        pending_watches: ?*const env_mod.Var = null,
        /// Same, for the Var's `validator` fn (yielded after `watches`): a
        /// `var_ref` is GC-filtered, so the `set-validator!` fn is reachable
        /// for the collector ONLY here.
        pending_validator: ?*const env_mod.Var = null,
    };

    /// Walks the per-thread execution roots thread-major (ADR-0091): for
    /// each thread index (0 = self TLS, k>=1 = registered worker k-1),
    /// drains that thread's binding-frame chain, then its macro slot,
    /// then its eval-frame (operand-stack) chain, then its in-flight
    /// fabrication self-guard, then advances to the next thread. One
    /// cursor subsumes #3a's separate `current_frame` + macro-slot
    /// cursors and adds the operand-stack (#3b-step1) + self-guard
    /// (#3b-step2b) sub-walks.
    pub const ThreadRootsCursor = struct {
        thread_idx: usize = 0,
        /// False until the current `thread_idx`'s roots are loaded into
        /// `roots` (and the binding sub-walk primed). Reset on each
        /// thread advance.
        loaded: bool = false,
        phase: Phase = .binding,
        roots: ThreadRoots = undefined,
        // binding-phase state:
        frame: ?*env_mod.BindingFrame = null,
        bindings_it: ?env_mod.BindingMap.ValueIterator = null,
        // eval-phase state:
        eval_frame: ?*EvalFrame = null,
        // analysis-phase state:
        analysis_frame: ?*AnalysisFrame = null,
        slot_idx: usize = 0,
        /// Which sub-array of the current eval frame is being drained:
        /// `stack[0..sp]` → `locals` → `constants` (D-251), then the parent.
        eval_part: EvalPart = .stack,

        pub const Phase = enum { binding, eval, self_guard, analysis };
        pub const EvalPart = enum { stack, locals, constants };
    };

    pub const PermanentRootsCursor = struct {
        idx: usize = 0,
    };

    pub fn next(self: *RootIterator) ?*HeapHeader {
        while (true) {
            switch (self.source) {
                .ns_vars => if (self.nextNsVar()) |hdr| return hdr else self.advance(),
                .thread_roots => if (self.nextThreadRoots()) |hdr| return hdr else self.advance(),
                .fn_closures, .lazy_seqs, .protocol_caches, .refer_borrows, .typed_instances, .callsite_methods => self.advance(),
                .permanent_roots => if (self.nextPermanentRoot()) |hdr| return hdr else return null,
            }
        }
    }

    fn advance(self: *RootIterator) void {
        const next_source: RootSource = switch (self.source) {
            .ns_vars => .thread_roots,
            .thread_roots => .fn_closures,
            .fn_closures => .lazy_seqs,
            .lazy_seqs => .protocol_caches,
            .protocol_caches => .refer_borrows,
            .refer_borrows => .typed_instances,
            .typed_instances => .callsite_methods,
            .callsite_methods => .permanent_roots,
            .permanent_roots => unreachable, // next() returns null instead
        };
        self.source = next_source;
        self.cursor = switch (next_source) {
            .ns_vars => .{ .ns_vars = .{} },
            .thread_roots => .{ .thread_roots = .{} },
            .permanent_roots => .{ .permanent_roots = .{} },
            else => .{ .empty = {} },
        };
    }

    fn nextNsVar(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.ns_vars;
        while (true) {
            // Flush pending Var.meta → Var.watches → Var.validator from the
            // previous Var before advancing (each immediate/absent slot falls
            // through to the next; validator immediate/absent advances the Var).
            if (c.pending_meta) |v_ptr| {
                c.pending_meta = null;
                c.pending_watches = v_ptr;
                if (v_ptr.meta) |m| if (m.heapHeader()) |hdr| return hdr;
            }
            if (c.pending_watches) |v_ptr| {
                c.pending_watches = null;
                c.pending_validator = v_ptr;
                if (v_ptr.watches.heapHeader()) |hdr| return hdr;
            }
            if (c.pending_validator) |v_ptr| {
                c.pending_validator = null;
                if (v_ptr.validator.heapHeader()) |hdr| return hdr;
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
                    // Namespace-level meta (D-239): a heap meta map roots as
                    // the walk enters the ns (immediate/nil falls through).
                    if (ns_pp.*.meta.heapHeader()) |hdr| return hdr;
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

    /// Thread-major per-thread root walk (ADR-0091). Yields, per thread
    /// index in turn (0 = self TLS, k>=1 = registered worker k-1): the
    /// binding-frame chain Values → the macro slot → the eval-frame chain
    /// (`stack[0..sp]` then `locals`). Returns `null` when no live thread
    /// remains. A thread with empty sub-walks loops straight to the next.
    fn nextThreadRoots(self: *RootIterator) ?*HeapHeader {
        const c = &self.cursor.thread_roots;
        while (true) {
            // Load this thread's roots on first touch + prime the binding walk.
            if (!c.loaded) {
                switch (threadContextAt(c.thread_idx)) {
                    .end => return null,
                    .roots => |r| {
                        c.roots = r;
                        c.loaded = true;
                        c.phase = .binding;
                        c.frame = r.frame_head;
                        c.bindings_it = null;
                    },
                }
            }
            switch (c.phase) {
                .binding => {
                    // Drain the current frame's bindings.
                    if (c.bindings_it) |*it| {
                        while (it.next()) |val_ptr| {
                            if (val_ptr.heapHeader()) |hdr| return hdr;
                        }
                        c.bindings_it = null;
                    }
                    // Walk down the binding-frame parent chain.
                    if (c.frame) |f| {
                        c.bindings_it = f.bindings.valueIterator();
                        c.frame = f.parent;
                        continue;
                    }
                    // Binding chain exhausted → prime + enter the eval
                    // sub-walk. (The former `.macro` phase was retired with
                    // `macro_root_slot` — the analysis frame subsumes it.)
                    c.phase = .eval;
                    c.eval_frame = c.roots.eval_head;
                    c.slot_idx = 0;
                    c.eval_part = .stack;
                },
                .eval => {
                    if (c.eval_frame) |ef| {
                        // Drain this frame's three Value arrays in turn:
                        // `stack[0..sp]` (the array is `undefined` above `sp` —
                        // never read past it), the fully-nil-initialised
                        // `locals`, then the chunk `constants` pool (D-251 —
                        // roots unloaded bytecode literals). Immediates +
                        // var_ref/ns are skipped by `heapHeader()`.
                        if (c.eval_part == .stack) {
                            const sp = ef.sp.*;
                            while (c.slot_idx < sp) {
                                const v = ef.stack[c.slot_idx];
                                c.slot_idx += 1;
                                if (v.heapHeader()) |hdr| return hdr;
                            }
                            c.eval_part = .locals;
                            c.slot_idx = 0;
                        }
                        if (c.eval_part == .locals) {
                            while (c.slot_idx < ef.locals.len) {
                                const v = ef.locals[c.slot_idx];
                                c.slot_idx += 1;
                                if (v.heapHeader()) |hdr| return hdr;
                            }
                            c.eval_part = .constants;
                            c.slot_idx = 0;
                        }
                        while (c.slot_idx < ef.constants.len) {
                            const v = ef.constants[c.slot_idx];
                            c.slot_idx += 1;
                            if (v.heapHeader()) |hdr| return hdr;
                        }
                        // This eval frame done → its parent.
                        c.eval_frame = ef.parent;
                        c.slot_idx = 0;
                        c.eval_part = .stack;
                        continue;
                    }
                    // Eval chain exhausted → self-guard phase.
                    c.phase = .self_guard;
                },
                .self_guard => {
                    // Yield this thread's in-flight fabrication partial (at most
                    // one heap yield), then move to the analysis-frame drain.
                    // The transition is set BEFORE the yield so a resume lands
                    // in `.analysis` (mirrors the macro phase).
                    c.phase = .analysis;
                    c.analysis_frame = c.roots.analysis_head;
                    c.slot_idx = 0;
                    if (c.roots.self_guard) |sv| {
                        if (sv.heapHeader()) |hdr| return hdr;
                    }
                },
                .analysis => {
                    // Drain the thread's analysis-frame chain (D-430): literal
                    // / quoted / compile-time / deserialized Values not yet
                    // reachable through any executing frame. Then advance to
                    // the next thread.
                    if (c.analysis_frame) |af| {
                        while (c.slot_idx < af.roots.items.len) {
                            const v = af.roots.items[c.slot_idx];
                            c.slot_idx += 1;
                            if (v.heapHeader()) |hdr| return hdr;
                        }
                        c.analysis_frame = af.parent;
                        c.slot_idx = 0;
                        continue;
                    }
                    c.thread_idx += 1;
                    c.loaded = false;
                },
            }
        }
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
/// + gc pointer (no auto-registry — see the WalkContext doc).
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

test "RootSource enum lists 9 sources per ADR-0028 §5 amendment 2" {
    try testing.expectEqual(@as(comptime_int, 9), @typeInfo(RootSource).@"enum".fields.len);
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

test "analysis-frame walker yields pushed roots; nothing outside a bracket" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell = try gc.alloc(Cell);
    cell.* = .{ .header = HeapHeader.init(.list) };

    // No bracket open → walker yields nothing.
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        try testing.expect(it.next() == null);
    }
    // Open a bracket, push → walker yields the cell's header; a nested
    // (parent-chained) frame's roots are yielded too; endAnalysis unchains.
    var af: AnalysisFrame = undefined;
    beginAnalysis(&af, testing.allocator);
    try pushAnalysisRoot(Value.encodeHeapPtr(.list, cell));
    try pushAnalysisRoot(Value.nil_val); // immediate — filtered, not stored
    try testing.expectEqual(@as(usize, 1), af.roots.items.len);
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        const hdr = it.next() orelse return error.AnalysisRootMissed;
        try testing.expectEqual(@as(*HeapHeader, @ptrCast(cell)), hdr);
        try testing.expect(it.next() == null);
    }
    const cell2 = try gc.alloc(Cell);
    cell2.* = .{ .header = HeapHeader.init(.vector) };
    var inner: AnalysisFrame = undefined;
    beginAnalysis(&inner, testing.allocator);
    try pushAnalysisRoot(Value.encodeHeapPtr(.vector, cell2));
    {
        var found_outer = false;
        var found_inner = false;
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        while (it.next()) |hdr| {
            if (hdr == @as(*HeapHeader, @ptrCast(cell))) found_outer = true;
            if (hdr == @as(*HeapHeader, @ptrCast(cell2))) found_inner = true;
        }
        try testing.expect(found_outer);
        try testing.expect(found_inner);
    }
    endAnalysis(&inner);
    endAnalysis(&af);
    try testing.expect(analysis_frame_head == null);
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
    _ = try env1.intern(ns1, "x", Value.encodeHeapPtr(.string, cell1), null);
    const ns2 = env2.findNs("user").?;
    _ = try env2.intern(ns2, "y", Value.encodeHeapPtr(.vector, cell2), null);

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
    const var_x = try env.intern(ns, "x", Value.nil_val, null);
    const var_y = try env.intern(ns, "y", Value.nil_val, null);

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

test "thread GC registry: register / count / unregister / no-op-absent (D-244 #3a)" {
    // Two contexts pointing at this thread's TLS slots (the values are
    // irrelevant here — #3a's cursor fold consumes them; this asserts the
    // registry lifecycle). Ends at count 0 so it does not pollute other tests.
    var ctx_a: ThreadGcContext = .{ .frame_slot = &env_mod.current_frame, .eval_frame_slot = &eval_frame_head, .self_guard_slot = &gc_self_guard };
    var ctx_b: ThreadGcContext = .{ .frame_slot = &env_mod.current_frame, .eval_frame_slot = &eval_frame_head, .self_guard_slot = &gc_self_guard };

    try testing.expectEqual(@as(usize, 0), registeredThreadCount());
    try registerThread(&ctx_a);
    try registerThread(&ctx_b);
    try testing.expectEqual(@as(usize, 2), registeredThreadCount());

    unregisterThread(&ctx_a);
    try testing.expectEqual(@as(usize, 1), registeredThreadCount());
    unregisterThread(&ctx_a); // absent now → no-op
    try testing.expectEqual(@as(usize, 1), registeredThreadCount());

    unregisterThread(&ctx_b);
    try testing.expectEqual(@as(usize, 0), registeredThreadCount());
}

test "union walk: a registered worker's frame + macro + operand stack are walked alongside self (D-244 #3a/#3b)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();
    const ns = env.findNs("user").?;
    const var_w = try env.intern(ns, "w", Value.nil_val, null);

    const cell_frame = try gc.alloc(Cell);
    cell_frame.* = .{ .header = HeapHeader.init(.string) };
    const cell_macro = try gc.alloc(Cell);
    cell_macro.* = .{ .header = HeapHeader.init(.vector) };
    const cell_stack = try gc.alloc(Cell);
    cell_stack.* = .{ .header = HeapHeader.init(.string) };
    const cell_local = try gc.alloc(Cell);
    cell_local.* = .{ .header = HeapHeader.init(.vector) };
    const cell_guard = try gc.alloc(Cell);
    cell_guard.* = .{ .header = HeapHeader.init(.list) };

    // A "worker" thread's published roots — a binding-frame chain + an
    // operand-stack EvalFrame + an in-flight fabrication self-guard + an
    // analysis frame — all held in locals (simulating another thread's TLS),
    // NOT on this thread's current_frame/eval_frame_head/gc_self_guard/
    // analysis_frame_head. They appear ONLY if the registry union walk
    // reaches thread index >= 1.
    var worker_bindings: env_mod.BindingMap = .empty;
    defer worker_bindings.deinit(env.alloc);
    try worker_bindings.put(env.alloc, var_w, Value.encodeHeapPtr(.string, cell_frame));
    var worker_frame: env_mod.BindingFrame = .{ .bindings = worker_bindings };
    var worker_current: ?*env_mod.BindingFrame = &worker_frame;

    var worker_stack = [_]Value{ Value.encodeHeapPtr(.string, cell_stack), Value.nil_val };
    var worker_sp: u16 = 1; // only stack[0] is live
    var worker_locals = [_]Value{ Value.encodeHeapPtr(.vector, cell_local), Value.nil_val };
    var worker_eval: EvalFrame = .{ .stack = &worker_stack, .sp = &worker_sp, .locals = &worker_locals, .parent = null };
    var worker_eval_head: ?*EvalFrame = &worker_eval;
    var worker_self_guard: ?Value = Value.encodeHeapPtr(.list, cell_guard);

    var worker_af: AnalysisFrame = .{ .roots = .empty, .alloc = testing.allocator };
    defer worker_af.roots.deinit(testing.allocator);
    try worker_af.roots.append(testing.allocator, Value.encodeHeapPtr(.vector, cell_macro));
    var worker_af_head: ?*AnalysisFrame = &worker_af;

    var ctx: ThreadGcContext = .{ .frame_slot = &worker_current, .eval_frame_slot = &worker_eval_head, .self_guard_slot = &worker_self_guard, .analysis_frame_slot = &worker_af_head };
    try registerThread(&ctx);
    defer unregisterThread(&ctx);

    var found_frame: bool = false;
    var found_macro: bool = false;
    var found_stack: bool = false;
    var found_local: bool = false;
    var found_guard: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_frame))) found_frame = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_macro))) found_macro = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_stack))) found_stack = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_local))) found_local = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_guard))) found_guard = true;
    }
    try testing.expect(found_frame); // worker's binding-frame value (union thread 1)
    try testing.expect(found_macro); // worker's analysis-frame root (union thread 1)
    try testing.expect(found_stack); // worker's operand stack[0] (union thread 1)
    try testing.expect(found_local); // worker's locals[0] (union thread 1)
    try testing.expect(found_guard); // worker's in-flight self-guard (union thread 1)
}

test "thread_roots walks this thread's operand stack via eval_frame_head (D-244 #3b)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_stack = try gc.alloc(Cell);
    cell_stack.* = .{ .header = HeapHeader.init(.string) };
    const cell_local = try gc.alloc(Cell);
    cell_local.* = .{ .header = HeapHeader.init(.vector) };

    // Null eval_frame_head → the eval sub-walk yields nothing (runtime-inert).
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        try testing.expect(it.next() == null);
    }

    var stack = [_]Value{ Value.encodeHeapPtr(.string, cell_stack), Value.nil_val };
    var sp: u16 = 1;
    var locals = [_]Value{ Value.encodeHeapPtr(.vector, cell_local), Value.nil_val };
    var frame: EvalFrame = .{ .stack = &stack, .sp = &sp, .locals = &locals, .parent = null };
    eval_frame_head = &frame;
    defer eval_frame_head = null;

    var found_stack: bool = false;
    var found_local: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_stack))) found_stack = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_local))) found_local = true;
    }
    try testing.expect(found_stack); // self thread's operand stack[0] (union source 0)
    try testing.expect(found_local); // self thread's locals[0]
}

test "thread_roots eval sub-walk reads stack[0..sp] only, never the undefined region above sp (D-244 #3b)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_live = try gc.alloc(Cell);
    cell_live.* = .{ .header = HeapHeader.init(.string) };
    const cell_above_sp = try gc.alloc(Cell);
    cell_above_sp.* = .{ .header = HeapHeader.init(.vector) };

    // stack[0] is live (sp=1); stack[1] holds a heap Value but sits ABOVE sp,
    // standing in for `vm.eval`'s `undefined` region — it must NOT be walked
    // (reading it would treat garbage as a root → false retention / a crash on
    // real undefined memory).
    var stack = [_]Value{ Value.encodeHeapPtr(.string, cell_live), Value.encodeHeapPtr(.vector, cell_above_sp) };
    var sp: u16 = 1;
    var locals = [_]Value{Value.nil_val};
    var frame: EvalFrame = .{ .stack = &stack, .sp = &sp, .locals = &locals, .parent = null };
    eval_frame_head = &frame;
    defer eval_frame_head = null;

    var found_live: bool = false;
    var found_above: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_live))) found_live = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_above_sp))) found_above = true;
    }
    try testing.expect(found_live);
    try testing.expect(!found_above);
}

test "thread_roots eval sub-walk follows the eval-frame parent chain (D-244 #3b)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_outer = try gc.alloc(Cell);
    cell_outer.* = .{ .header = HeapHeader.init(.string) };
    const cell_inner = try gc.alloc(Cell);
    cell_inner.* = .{ .header = HeapHeader.init(.vector) };

    var outer_stack = [_]Value{Value.encodeHeapPtr(.string, cell_outer)};
    var outer_sp: u16 = 1;
    var outer_locals = [_]Value{Value.nil_val};
    var outer: EvalFrame = .{ .stack = &outer_stack, .sp = &outer_sp, .locals = &outer_locals, .parent = null };

    var inner_stack = [_]Value{Value.encodeHeapPtr(.vector, cell_inner)};
    var inner_sp: u16 = 1;
    var inner_locals = [_]Value{Value.nil_val};
    var inner: EvalFrame = .{ .stack = &inner_stack, .sp = &inner_sp, .locals = &inner_locals, .parent = &outer };

    eval_frame_head = &inner;
    defer eval_frame_head = null;

    var found_outer: bool = false;
    var found_inner: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell_outer))) found_outer = true;
        if (hdr == @as(*HeapHeader, @ptrCast(cell_inner))) found_inner = true;
    }
    try testing.expect(found_outer); // parent eval frame walked
    try testing.expect(found_inner); // head eval frame walked
}

test "thread_roots walks this thread's in-flight fabrication self-guard via gc_self_guard (D-244 #3b-step2b)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell = try gc.alloc(Cell);
    cell.* = .{ .header = HeapHeader.init(.string) };

    // Null gc_self_guard → the self-guard sub-walk yields nothing (inert).
    {
        var it = enumerate(.{ .envs = &.{}, .gc = &gc });
        try testing.expect(it.next() == null);
    }
    // Set → the in-flight partial is rooted (would survive a mid-fabrication
    // collect instead of being swept).
    gc_self_guard = Value.encodeHeapPtr(.string, cell);
    defer gc_self_guard = null;
    var found: bool = false;
    var it = enumerate(.{ .envs = &.{}, .gc = &gc });
    while (it.next()) |hdr| {
        if (hdr == @as(*HeapHeader, @ptrCast(cell))) found = true;
    }
    try testing.expect(found);
}

test "registry: concurrent register/unregister churn is race-free (D-244 #3a robustness)" {
    // The registry's io_default-locked array must serialize register/unregister
    // across real OS threads (Phase-B workers register at spawn / join). Set a
    // threaded io so the Io.Mutex blocks for real, then restore it (the singleton
    // is process-wide; tests run serially).
    const saved_io = io_default.get();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    defer io_default.set(saved_io); // runs before threaded.deinit (LIFO)
    io_default.set(threaded.io());

    try testing.expectEqual(@as(usize, 0), registeredThreadCount());

    const Worker = struct {
        fn run() void {
            // Each thread owns one context pointing at its own TLS; register +
            // immediately unregister in a tight loop (≤4 concurrent < cap 64).
            var ctx: ThreadGcContext = .{ .frame_slot = &env_mod.current_frame, .eval_frame_slot = &eval_frame_head, .self_guard_slot = &gc_self_guard };
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                registerThread(&ctx) catch return;
                unregisterThread(&ctx);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (&threads) |t| t.join();

    // Every register paired with an unregister → back to empty, no leaked slot,
    // no corruption (a torn array under contention would strand a registration).
    try testing.expectEqual(@as(usize, 0), registeredThreadCount());
}
