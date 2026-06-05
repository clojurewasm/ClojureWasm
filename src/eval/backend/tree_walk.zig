//! TreeWalk — evaluate the Node tree by recursive descent.
//!
//! This is the simplest possible interpreter. It is also the
//! differential oracle the bytecode VM (`vm.zig`) is checked against:
//! `Evaluator.compare` runs both backends over the same source and
//! requires bit-for-bit identical Values (dual-backend verification,
//! ADR-0005 / ADR-0022).
//!
//! ### Scope
//!
//! - Constants / locals / vars.
//! - Special forms: def, if, do, quote, fn*, let*, letfn*, loop*,
//!   recur, binding, try/throw, in-ns/ns/require.
//! - Function call: dispatched through `Runtime.vtable.callFn`, which
//!   `installVTable(rt)` populates with `treeWalkCall` from this file.
//!   Multi-arity dispatch, closures over locals, deftype/protocol/
//!   multimethod dispatch, and interop are all handled here.
//! - Built-ins: `Value.builtin_fn` invoked directly via the
//!   `dispatch.BuiltinFn` signature.
//!
//! ### Function representation
//!
//! `Function` is a heap-allocated struct wrapped in a NaN-boxed
//! `.fn_val` Value. A fn nested inside `let*` / `fn*` snapshots its
//! enclosing locals into `closure_bindings` at allocation time and
//! replays them on every call; top-level fns capture nothing.
//!
//! ### Locals
//!
//! Every call frame uses a fixed-size 256-slot stack array. A future
//! pass may tighten this to the analyser-known frame size.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const HeapHeader = @import("../../runtime/value/value.zig").HeapHeader;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const lookup_mod = @import("../../runtime/collection/lookup.zig");
const host_class = @import("../../runtime/error/host_class.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const ex_info_collection = @import("../../runtime/collection/ex_info.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const list_mod = @import("../../runtime/collection/list.zig");
const multimethod_mod = @import("../../runtime/multimethod.zig");
const protocol_mod = @import("../../runtime/protocol.zig");
const method_table = @import("../../runtime/dispatch/method_table.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const node_mod = @import("../node.zig");
const loader = @import("../loader.zig");
const Node = node_mod.Node;
const special_forms = @import("../analyzer/special_forms.zig");
const opcode_mod = @import("vm/opcode.zig");
const BytecodeChunk = opcode_mod.BytecodeChunk;
const tag_ops = @import("../../runtime/gc/tag_ops.zig");
const mark_sweep = @import("../../runtime/gc/mark_sweep.zig");
const gc_heap_mod = @import("../../runtime/gc/gc_heap.zig");

/// Per-frame slot-array size. Generous so the analyser can lay out
/// `let*` chains without checking; a future pass may switch to a
/// frame-size known at analyse time.
pub const MAX_LOCALS: u16 = 256;

/// TreeWalk error surface. Aliases `error_mod.ClojureWasmError` so
/// calls to `error_catalog.raise(.code, loc, args)` type-check; the
/// backend still only **emits** `error.TypeError` (non-callable
/// callee), `error.ArityError` (wrong number of args),
/// `error.IndexError` (slot out of range), `error.NotImplemented`
/// (defensive guard, e.g. invoking a deserialized VM-only fn with no
/// evalChunk), `error.InternalError` (defensive runtime
/// invariants), and `error.OutOfMemory`. Mirrors the `ReadError` /
/// `AnalyzeError` treatment in §9.5/3.2 / 3.3.
pub const EvalError = error_mod.ClojureWasmError;

// --- §9.5/3.11 control-flow signals ---
//
// `recur` and `throw` use Zig errors purely as a non-local control
// channel; they carry no payload (errors don't in Zig). Per-thread
// scratch state holds the actual Values:
//
//   - `pending_recur_buf` / `pending_recur_len` — recur args, drained
//     by the matching `evalLoop` / `callFunction` frame.
//   - `dispatch.last_thrown_exception` — the thrown Value, drained by
//     the matching `evalTry`'s catch handler.
//
// Buffer is fixed-size (matches `MAX_LOCALS`) so recur cannot allocate
// during the unwind. Survey: `private/notes/phase3-3.11-survey.md`
// concluded this matches v1_ref's `error.RecurSignaled` idiom and
// satisfies ROADMAP P10 (Zig 0.16 idioms) without diverging.
threadlocal var pending_recur_buf: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
threadlocal var pending_recur_len: u16 = 0;

// --- Function (heap object representing a Clojure fn) ---

/// Closure object emitted by `fn*`. `slot_base` and `closure_bindings`
/// let a fn nested inside `let*` / `fn*` snapshot its enclosing locals
/// at allocation time and replay them on every call. Top-level fns have `slot_base == 0` and `closure_bindings ==
/// null`. The `body` and `params` slices borrow from the analyser's
/// per-eval arena, so the Function lives only as long as that arena
/// does. `closure_bindings` is owned by the Function (separate
/// gpa allocation) and freed by `freeFunction`.
/// Row 7.8 cycle 1 (ADR-0041) runtime-side per-arity record. Mirrors
/// `node_mod.FnMethod` plus an optional bytecode chunk (the VM
/// compile arm stamps one chunk per method).
pub const FunctionMethod = struct {
    arity: u16,
    has_rest: bool,
    /// Parameter names (debug + error frames). Borrowed from the
    /// analyser arena.
    params: []const []const u8,
    /// Body Node — borrowed too. The TreeWalk backend evaluates it
    /// directly when `bytecode == null`.
    body: *const Node,
    /// Compiled bytecode body. `null` means TreeWalk evaluates the
    /// `body` Node directly; non-null means the VM dispatcher uses
    /// this chunk and ignores `body`. The two paths produce bit-for-
    /// bit identical Values under `Evaluator.compare` (ADR-0005 /
    /// ADR-0022). The chunk lives in the analyser arena alongside
    /// `body`/`params`.
    bytecode: ?*const BytecodeChunk = null,
};

pub const Function = struct {
    // `align(8)` forces `header` into the struct's max-alignment group so
    // Zig's auto field-ordering keeps it at offset 0. The GC reads every
    // heap-tagged Value's `HeapHeader` at offset 0 (`value.heapHeader` ->
    // `decodePtr(*HeapHeader)`), but `Function` is `gpa.create`'d — it
    // bypasses `gc.alloc`'s `assertHeaderAtOffsetZero`, so without this a
    // non-extern struct sorts the align-8 slice fields (`methods` /
    // `closure_bindings`) ahead of an align-4 header and the GC reads
    // `methods.ptr`'s low byte as a bogus tag (D-251). The `comptime`
    // assert below makes any future reorder a build failure, not a UAF.
    header: HeapHeader align(8),
    /// Number of locals the analyser allocated above this fn — these
    /// are the slots the closure snapshot fills, and the active
    /// method's params land at `[slot_base, slot_base + method.arity)`.
    slot_base: u16,
    /// Fixed-arity methods, sorted by arity ascending (analyser-time).
    /// Single-arity ships as a 1-element slice. JVM rule 2 (no two
    /// same-arity fixed) enforced at analyzer-time.
    methods: []const FunctionMethod,
    /// Variadic body, separate slot per ADR-0041 — JVM allows ≤ 1
    /// variadic per fn (rule 1).
    variadic: ?FunctionMethod,
    /// Captured outer locals; null when the fn closes over nothing
    /// (top-level fn) so the common case stays a single null check
    /// rather than an empty-slice round-trip.
    closure_bindings: ?[]Value,

    comptime {
        std.debug.assert(@offsetOf(Function, "header") == 0);
    }
};

/// Per-tag GC trace for `.fn_val` (D-251 rooting-gap class). A `Function`
/// owns GC Values reachable ONLY through it: the `closure_bindings`
/// snapshot, and the constant pools of its compiled method / variadic
/// bytecode (literal collections / strings the body refers to). Without
/// this the fn is treated as a leaf and those captures are swept under a
/// collect (the cause of swept-intermediate failures D-250 torture
/// surfaced). The Function struct itself is `gpa.create`'d + `trackHeap`'d
/// (not GC-swept), so this is mark-only; no finaliser is registered.
/// `header` aliases `*Function` because header is at offset 0 (asserted
/// above). Nested `fn_val` constants recurse safely via mark's cycle bit.
pub fn traceFunction(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const f: *Function = @ptrCast(@alignCast(header));
    if (f.closure_bindings) |caps| {
        for (caps) |cap| if (cap.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
    // Mark each compiled method / variadic chunk's literal CONSTANTS (D-251 /
    // ADR-0095 Alt D). Literal *values* are `gc.alloc`'d but sit in the
    // run-lifetime analyser arena's constant pool; while this fn is DORMANT
    // (reachable via a var but not executing) its pool has no `EvalFrame` root,
    // so without this trace a literal in a not-currently-running fn is swept and
    // the next call loads a dangling pointer (`(defn g [x] (str "n=" x))
    // (mapv g …)` swept "n="). Safe now that `heapHeader()` consults the total
    // `isGcManaged` membrane: `symbol`/`keyword`/`var_ref`/`ns` constants are
    // filtered before decode, so the prior `tag_trace_table` OOB cannot recur.
    // Nested `fn_val` template constants recurse via mark's cycle bit + the
    // persistent-waypoint re-clear.
    for (f.methods) |m| {
        if (m.bytecode) |chunk| {
            for (chunk.constants) |c| if (c.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
        }
    }
    if (f.variadic) |v| {
        if (v.bytecode) |chunk| {
            for (chunk.constants) |c| if (c.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
        }
    }
}

/// Register the `.fn_val` trace. Called from `driver.installVTable` (a
/// Layer-1 startup hook) rather than `runtime.zig`'s `registerGcHooks`
/// aggregator, because `Function` lives in this Layer-1 module and Layer 0
/// must not import it (zone rule).
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.fn_val, &traceFunction);
}

/// Heap-allocate a Function and wrap it in a NaN-boxed Value. The
/// caller's `locals` array supplies the snapshot for closure capture:
/// slots `[0, fn_node.slot_base)` are duplicated into a fresh
/// gpa-owned slice the Function will later replay on every call. Top
/// -level fns (`slot_base == 0`) skip the allocation entirely. Until
/// the Phase-5 GC arrives, register the allocation with
/// `rt.heap_objects` so `Runtime.deinit` frees it.
pub fn allocFunction(rt: *Runtime, fn_node: node_mod.FnNode, locals: []const Value) !Value {
    return allocFunctionWithBytecodes(rt, fn_node, locals, null);
}

/// Same as `allocFunction` but stamps per-method bytecode chunks onto
/// the Function. The slice length must equal `fn_node.methods.len` (a
/// `null` entry within the slice means "no bytecode for that method";
/// useful when a future per-method JIT can lazily fill chunks).
/// `variadic_chunk` covers `fn_node.variadic` when present.
pub fn allocFunctionWithBytecode(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    locals: []const Value,
    method_chunks: []const ?*const BytecodeChunk,
    variadic_chunk: ?*const BytecodeChunk,
) !Value {
    std.debug.assert(method_chunks.len == fn_node.methods.len);
    return allocFunctionWithBytecodes(rt, fn_node, locals, .{
        .method_chunks = method_chunks,
        .variadic_chunk = variadic_chunk,
    });
}

const Bytecodes = struct {
    method_chunks: []const ?*const BytecodeChunk,
    variadic_chunk: ?*const BytecodeChunk,
};

/// Allocate a Function that carries `fn_node.slot_base` for the VM's
/// `op_make_fn` dispatcher to read at run time, but defers the actual
/// closure snapshot until then. `closure_bindings` is `null` even when
/// `slot_base > 0`. The dispatcher calls `allocFunctionWithBytecode`
/// with the live `locals` to produce the per-evaluation Function from
/// this template.
pub fn allocFunctionTemplate(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    method_chunks: []const ?*const BytecodeChunk,
    variadic_chunk: ?*const BytecodeChunk,
) !Value {
    std.debug.assert(method_chunks.len == fn_node.methods.len);
    const methods = try buildFunctionMethods(rt, fn_node.methods, method_chunks);
    errdefer rt.gpa.free(methods);
    var variadic: ?FunctionMethod = null;
    if (fn_node.variadic) |v| variadic = methodFromNode(v, variadic_chunk);

    const f = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(f);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .slot_base = fn_node.slot_base,
        .methods = methods,
        .variadic = variadic,
        .closure_bindings = null,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn allocFunctionWithBytecodes(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    locals: []const Value,
    bytecodes: ?Bytecodes,
) !Value {
    const closure: ?[]Value = if (fn_node.slot_base == 0)
        null
    else blk: {
        const slice = try rt.gpa.alloc(Value, fn_node.slot_base);
        @memcpy(slice, locals[0..fn_node.slot_base]);
        break :blk slice;
    };
    errdefer if (closure) |s| rt.gpa.free(s);

    const method_chunks: []const ?*const BytecodeChunk = if (bytecodes) |bc| bc.method_chunks else &.{};
    const variadic_chunk: ?*const BytecodeChunk = if (bytecodes) |bc| bc.variadic_chunk else null;
    const methods = if (bytecodes != null)
        try buildFunctionMethods(rt, fn_node.methods, method_chunks)
    else
        try buildFunctionMethodsNoBytecode(rt, fn_node.methods);
    errdefer rt.gpa.free(methods);
    var variadic: ?FunctionMethod = null;
    if (fn_node.variadic) |v| variadic = methodFromNode(v, variadic_chunk);

    const f = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(f);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .slot_base = fn_node.slot_base,
        .methods = methods,
        .variadic = variadic,
        .closure_bindings = closure,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn buildFunctionMethods(
    rt: *Runtime,
    src: []const node_mod.FnMethod,
    bytecodes: []const ?*const BytecodeChunk,
) ![]FunctionMethod {
    const out = try rt.gpa.alloc(FunctionMethod, src.len);
    for (src, 0..) |m, i| {
        out[i] = methodFromNode(m, bytecodes[i]);
    }
    return out;
}

fn buildFunctionMethodsNoBytecode(rt: *Runtime, src: []const node_mod.FnMethod) ![]FunctionMethod {
    const out = try rt.gpa.alloc(FunctionMethod, src.len);
    for (src, 0..) |m, i| {
        out[i] = methodFromNode(m, null);
    }
    return out;
}

fn methodFromNode(m: node_mod.FnMethod, bytecode: ?*const BytecodeChunk) FunctionMethod {
    return .{
        .arity = m.arity,
        .has_rest = m.has_rest,
        .params = m.params,
        .body = m.body,
        .bytecode = bytecode,
    };
}

fn freeFunction(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const f: *Function = @ptrCast(@alignCast(ptr));
    if (f.closure_bindings) |s| gpa.free(s);
    if (f.methods.len > 0) gpa.free(f.methods);
    gpa.destroy(f);
}

/// Sentinel body for deserialized (VM-only) functions (ADR-0034 am2 A2-D3).
/// A deserialized fn carries `bytecode`, so the VM `evalChunk` path runs and
/// the body Node is never walked; it has no source Node. This immortal
/// module-const stands in for `FunctionMethod.body`; the guard at the
/// tree_walk fn-body site raises if it is ever reached.
const deserialized_fn_body: Node = .{ .constant = .{ .value = .nil_val } };

/// One method's worth of deserialized data (ADR-0034 am2 A2-D3). Param names
/// are dropped (D-139); `bytecode` is an `allocator`-owned chunk the caller
/// (`serialize.zig`) frees via `freeChunk` recursion.
pub const SerializedMethod = struct {
    arity: u16,
    has_rest: bool,
    bytecode: ?*const BytecodeChunk,
};

/// Reconstruct a Function from deserialized data (ADR-0034 am2 A2-D3). gpa +
/// trackHeap like a compiled top-level fn (so `freeFunction` is unchanged),
/// `closure_bindings = null` (a constant fn never captures runtime locals),
/// `params = &.{}` (D-139), `body = &deserialized_fn_body`. The method
/// `bytecode` chunks are borrowed — owned by `serialize.zig`'s allocator and
/// freed by `freeChunk` recursion before `rt.deinit`.
pub fn allocFunctionFromSerialized(
    rt: *Runtime,
    slot_base: u16,
    methods: []const SerializedMethod,
    variadic: ?SerializedMethod,
) !Value {
    const out = try rt.gpa.alloc(FunctionMethod, methods.len);
    errdefer rt.gpa.free(out);
    for (methods, 0..) |m, i| {
        out[i] = .{
            .arity = m.arity,
            .has_rest = m.has_rest,
            .params = &.{},
            .body = &deserialized_fn_body,
            .bytecode = m.bytecode,
        };
    }
    var variadic_method: ?FunctionMethod = null;
    if (variadic) |vm| variadic_method = .{
        .arity = vm.arity,
        .has_rest = vm.has_rest,
        .params = &.{},
        .body = &deserialized_fn_body,
        .bytecode = vm.bytecode,
    };

    const f = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(f);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .slot_base = slot_base,
        .methods = out,
        .variadic = variadic_method,
        .closure_bindings = null,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

// --- Top-level eval ---

/// Evaluate one Node into a Value. `locals` is the slot array owned
/// by the caller — typically a fixed 256-entry stack array.
pub fn eval(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    node: *const Node,
) anyerror!Value {
    return switch (node.*) {
        .constant => |n| n.value,
        .local_ref => |n| {
            if (n.index >= locals.len)
                return error_catalog.raise(.slot_out_of_range, n.loc, .{ .form = "Local", .index = n.index, .max = locals.len });
            return locals[n.index];
        },
        .var_ref => |n| n.var_ptr.deref(),
        .def_node => |n| try evalDef(rt, env, locals, n),
        .if_node => |n| try evalIf(rt, env, locals, n),
        .do_node => |n| try evalDo(rt, env, locals, n.forms),
        .quote_node => |n| n.quoted,
        .fn_node => |n| try allocFunction(rt, n, locals),
        .let_node => |n| try evalLet(rt, env, locals, n),
        .letfn_node => |n| try evalLetfn(rt, env, locals, n),
        .call_node => |n| try evalCall(rt, env, locals, n),
        .loop_node => |n| try evalLoop(rt, env, locals, n),
        .binding_node => |n| try evalBinding(rt, env, locals, n),
        .recur_node => |n| try evalRecur(rt, env, locals, n),
        .try_node => |n| try evalTry(rt, env, locals, n),
        .throw_node => |n| try evalThrow(rt, env, locals, n),
        .interop_call_node => |n| try evalInteropCall(rt, env, locals, n),
        .in_ns_node => |n| try evalInNs(env, n),
        .require_node => |n| try evalRequire(rt, env, n),
        .ns_node => |n| try evalNs(rt, env, n),
        .vector_literal_node => |n| try evalVectorLiteral(rt, env, locals, n),
        .map_literal_node => |n| try evalMapLiteral(rt, env, locals, n),
        .set_literal_node => |n| try evalSetLiteral(rt, env, locals, n),
        .set_node => |n| try evalSet(rt, env, locals, n),
    };
}

/// `(set! *v* value)` — evaluate value, then update the innermost active
/// thread binding for the Var; if none is active, set the Var root (covers
/// top-level compiler-flag vars like `*warn-on-reflection*`). Returns the
/// assigned value.
fn evalSet(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.SetNode) anyerror!Value {
    const val = try eval(rt, env, locals, n.value_expr);
    if (!env_mod.setBinding(n.var_ptr, val)) n.var_ptr.setRoot(val);
    return val;
}

/// `(in-ns 'foo.bar)` — switch `env.current_ns` to the named namespace,
/// creating it if absent. Returns the namespace value (clj parity +
/// consistency with the in-ns runtime fn, ADR-0083 / ADR-0085).
///
/// Naked ns switch — no auto-refer (ADR-0035 D9 second amendment). User
/// code reaches `clojure.core` / `rt/` vars via `(ns foo
/// (:refer-clojure))` (which fires the widened refer semantic) or
/// explicit `(refer ...)` calls.
fn evalInNs(env: *Env, n: node_mod.InNsNode) !Value {
    const ns = try env.findOrCreateNs(n.ns_name);
    env.setCurrentNs(ns);
    // Return the namespace value (clj parity + consistency with the in-ns
    // runtime fn, ADR-0083 / ADR-0085) — not nil.
    return env_mod.Env.nsValue(ns);
}

/// `(ns foo)` / `(ns foo (:refer-clojure))`. ADR-0035 D1 + D9
/// second amendment. When `:refer-clojure` is in effect (default
/// true), the cw v1 widened semantic refers BOTH `rt` AND
/// `clojure.core` into the entering ns (divergence from JVM which
/// has no rt ns). When `refer_clojure = false`, the ns switch is
/// naked — same shape as `(in-ns 'foo)`. The widening makes the
/// refer mechanism grep-traceable from the `.clj` head: every
/// user-visible refer of rt + clojure.core comes from a
/// `(:refer-clojure)` directive (boot-time fan-out for user/
/// remains in bootstrap.zig + primitive.zig + macro_transforms.zig).
fn evalNs(rt: *Runtime, env: *Env, n: node_mod.NsNode) !Value {
    env.setCurrentNs(try env.findOrCreateNs(n.name));
    if (n.refer_clojure) {
        // Row 14.7 (D-098): filters apply to both rt/ and clojure.core
        // (the two auto-refer sources). `rt/` is cw-side primitives;
        // its `+` / `-` / etc. are what `:exclude [+]` shadows.
        if (env.findNs("rt")) |rt_ns| {
            try env.referAllWithFilter(rt_ns, env.current_ns.?, n.refer_clojure_exclude, n.refer_clojure_only);
        }
        if (env.findNs("clojure.core")) |cc_ns| {
            try env.referAllWithFilter(cc_ns, env.current_ns.?, n.refer_clojure_exclude, n.refer_clojure_only);
        }
    }
    // Row 14.7 (D-098): walk ns-level (:require [...]) libspecs. Each
    // mirrors the top-level (require '[...]) shape; evalRequire is
    // factored so RequireNode can be applied directly.
    for (n.libspecs) |libspec| {
        _ = try evalRequire(rt, env, libspec);
    }
    // D-235: register `(:import …)` simple-name → FQCN into the entering ns.
    for (n.imports) |imp| {
        try env.current_ns.?.addImport(env.alloc, imp.simple, imp.fqcn);
    }
    return .nil_val;
}

/// `(require 'foo.bar)` / `(require '[foo.bar :as a :refer [x y]])`.
/// ADR-0035 D2/D3/D4/D5/D8. Vector-libspec support: `:as` installs an
/// alias in the calling ns; `:refer` installs explicit per-name refers
/// (raising `private_access_error` on private targets,
/// `symbol_unresolved` when the source ns lacks the name).
/// Already-loaded namespaces skip the load step but still apply
/// :as/:refer; a not-yet-loaded namespace is source-loaded via
/// `loader.loadNamespace`.
fn evalRequire(rt: *Runtime, env: *Env, n: node_mod.RequireNode) !Value {
    const target_ns = blk: {
        if (env.findNs(n.ns_name)) |existing| {
            if (existing.mappings.count() > 0) break :blk existing;
        }
        const resolver = rt.require_resolver orelse
            return error_catalog.raise(.lib_not_found, n.loc, .{ .ns = n.ns_name });
        const resolved = (try resolver(rt, n.ns_name)) orelse
            return error_catalog.raise(.lib_not_found, n.loc, .{ .ns = n.ns_name });
        try loader.loadNamespace(rt, env, n.ns_name, resolved, n.loc);
        break :blk env.findNs(n.ns_name) orelse
            return error_catalog.raise(.lib_not_found, n.loc, .{ .ns = n.ns_name });
    };

    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, n.loc, .{ .sym = n.ns_name });

    if (n.alias) |alias_name| {
        try env.setAlias(here, alias_name, target_ns);
    }
    if (n.refer_all) {
        // `:refer :all` / `:use` — refer every public var (skips privates),
        // honouring a `:exclude` blacklist when present.
        try env.referAllWithFilter(target_ns, here, n.exclude, null);
    }
    for (n.refers) |refer_name| {
        const outcome = try env.referOne(target_ns, here, refer_name);
        switch (outcome) {
            .installed => {},
            .private_blocked => {
                const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ n.ns_name, refer_name });
                defer rt.gpa.free(full);
                return error_catalog.raise(.private_access_error, n.loc, .{
                    .sym = full,
                    .ns = n.ns_name,
                });
            },
            .not_found => {
                const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ n.ns_name, refer_name });
                defer rt.gpa.free(full);
                return error_catalog.raise(.symbol_unresolved, n.loc, .{ .sym = full });
            },
        }
    }
    return .nil_val;
}

/// `[expr1 expr2 ...]` — evaluate each child, conj into an empty
/// PersistentVector. ROADMAP §9.7 PersistentVector is the heap shape;
/// `vector_collection.empty()` + `conj` produces the Phase 5 HAMT-
/// backed Value.
fn evalVectorLiteral(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.VectorLiteralNode) !Value {
    var v = vector_collection.empty();
    for (n.elements) |*elt| {
        const elt_val = try eval(rt, env, locals, elt);
        v = try vector_collection.conj(rt, v, elt_val);
    }
    return v;
}

/// `{k1 v1 k2 v2 ...}` — evaluate each child, assoc the k/v pair
/// into an empty ArrayMap. Flat element layout per MapLiteralNode
/// (reader guarantees even count).
fn evalMapLiteral(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.MapLiteralNode) !Value {
    var m = map_collection.empty();
    var i: usize = 0;
    while (i < n.elements.len) : (i += 2) {
        const k = try eval(rt, env, locals, &n.elements[i]);
        const v = try eval(rt, env, locals, &n.elements[i + 1]);
        m = try map_collection.assoc(rt, m, k, v);
    }
    return m;
}

/// `#{e1 e2 ...}` — evaluate each child, conj into an empty HashSet.
/// Duplicates collapse via set semantics.
fn evalSetLiteral(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.SetLiteralNode) !Value {
    var s = set_collection.empty();
    for (n.elements) |*elt| {
        const elt_val = try eval(rt, env, locals, elt);
        s = try set_collection.conj(rt, s, elt_val);
    }
    return s;
}

const type_descriptor_mod = @import("../../runtime/type_descriptor.zig");
const object_method = @import("object_method.zig");

/// Unified Java/host interop dispatch arm (ADR-0050, am1). Routes on
/// `n.kind` to the three kind-specific helpers below.
fn evalInteropCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.InteropCallNode) !Value {
    return switch (n.kind) {
        .constructor => evalConstructorCall(rt, env, locals, n),
        .instance_member => evalInstanceMember(rt, env, locals, n),
        .static_method => evalStaticMethodCall(rt, env, locals, n),
    };
}

fn evalConstructorCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.InteropCallNode) !Value {
    // Eval the ctor args, then delegate to the shared resolver/dispatcher
    // (special_forms.constructInstance) so TreeWalk + VM construct
    // identically — incl. the java-surface `<init>` path `(java.io.File.
    // "path")` rides (ADR-0036 dual-backend parity; D-196 blocker 3).
    var buf: [MAX_LOCALS]Value = undefined;
    if (n.args.len > MAX_LOCALS)
        return error_catalog.raise(.call_args_exceed_max_locals, n.loc, .{ .got = n.args.len, .max = MAX_LOCALS });
    for (n.args, 0..) |arg_node, i| {
        buf[i] = try eval(rt, env, locals, &arg_node);
    }
    return special_forms.constructInstance(rt, env, n.type_name, buf[0..n.args.len], n.loc);
}

/// `(.member recv args...)` / `(.-field recv)` unified instance member
/// dispatch (ADR-0050 am1). Resolves the receiver's TypeDescriptor and
/// applies the field-first resolver: deftype/record receivers carry a
/// `field_layout`, so a name matching a declared field reads that field;
/// native types (`field_layout == null`) skip straight to `method_table`.
/// `field_only` (the `.-name` form) stops after the field attempt — it
/// never falls back to a method. A non-field name otherwise looks up the
/// `method_table` (Path A2 — `lookupMethod(null, name)`) and calls via
/// `vt.callFn` with `[receiver, ...args]`. Field-first keying eliminates
/// the field/method name-collision silent-shadow (am1 caveat 1).
fn evalInstanceMember(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.InteropCallNode) !Value {
    const target = n.target orelse return error.InternalError;
    const receiver = try eval(rt, env, locals, target);
    const td = try receiverDescriptor(rt, receiver);

    // FIELD-FIRST: `field_layout` is non-null only for deftype/record, so a
    // hit here implies the receiver is a `.typed_instance` (reify + native
    // both carry `field_layout == null`), making the decode below safe.
    if (td.field_layout) |layout| {
        for (layout) |fe| {
            if (std.mem.eql(u8, fe.name, n.name)) {
                return receiver.decodePtr(*const type_descriptor_mod.TypedInstance).fields()[fe.index];
            }
        }
    }
    if (n.field_only) {
        return error_catalog.raise(.symbol_unresolved, n.loc, .{ .sym = n.name });
    }

    // Build the args buffer (receiver + analysed args) BEFORE the lookup:
    // both the method call and the Object-method fallback (D-207) need the
    // evaluated args, and clj evaluates args before dispatch.
    const total = 1 + n.args.len;
    const args_buf = try rt.gpa.alloc(Value, total);
    defer rt.gpa.free(args_buf);
    args_buf[0] = receiver;
    for (n.args, 0..) |*a, i| {
        args_buf[1 + i] = try eval(rt, env, locals, a);
    }

    const me = td.lookupMethod(null, n.name) orelse {
        // Universal java.lang.Object method fallback (D-207): str/=/hash/class.
        if (try object_method.tryObjectMethod(rt, env, receiver, td, n.name, args_buf[1..])) |r| return r;
        return error_catalog.raise(.protocol_no_satisfies, n.loc, .{
            .protocol = "<.member>",
            .method = n.name,
            .type_name = td.fqcn orelse "<anonymous>",
        });
    };
    if (me.method_val.tag() == .nil) return error_catalog.raise(.feature_not_supported, n.loc, .{
        .name = "method declared but not implemented",
    });
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, me.method_val, args_buf, n.loc);
}

/// Resolve the dispatch descriptor for an instance-member receiver.
/// `.typed_instance` / `.reified_instance` carry their descriptor inline;
/// every other tag uses the per-Runtime native descriptor (lazily
/// allocated, `method_table` populated by `String.installNativeMethods`
/// at runtime init). Mirrors the VM's `op_method_call` resolution.
fn receiverDescriptor(rt: *Runtime, receiver: Value) !*const type_descriptor_mod.TypeDescriptor {
    return switch (receiver.tag()) {
        .typed_instance => receiver.decodePtr(*const type_descriptor_mod.TypedInstance).descriptor,
        .reified_instance => receiver.decodePtr(*const type_descriptor_mod.ReifiedInstance).descriptor,
        else => try rt.nativeDescriptor(receiver.tag()),
    };
}

/// `(Class/method args...)` static method dispatch (D-121 + ADR-0050).
/// Descriptor pointer was resolved at analyze time; only the
/// method-table linear lookup runs here. Eval is symmetric to
/// `evalInstanceMember`'s method branch minus the receiver — no
/// `args[0]` insert, just user args.
fn evalStaticMethodCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.InteropCallNode) !Value {
    const td = n.descriptor orelse return error.InternalError;
    const me = td.lookupMethod(null, n.name) orelse {
        return error_catalog.raise(.protocol_no_satisfies, n.loc, .{
            .protocol = "<static>",
            .method = n.name,
            .type_name = td.fqcn orelse "<anonymous>",
        });
    };
    if (me.method_val.tag() == .nil) return error_catalog.raise(.feature_not_supported, n.loc, .{
        .name = "static method declared but not implemented",
    });
    const buf = try rt.gpa.alloc(Value, n.args.len);
    defer rt.gpa.free(buf);
    for (n.args, 0..) |*a, i| {
        buf[i] = try eval(rt, env, locals, a);
    }
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, me.method_val, buf, n.loc);
}

fn evalDef(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.DefNode) !Value {
    const ns = env.current_ns orelse
        return error_catalog.raiseInternal(n.loc, "def: no current namespace");
    // A no-init `(def x)` interns an UNBOUND placeholder (does not clobber an
    // existing root — clj parity; leaves `Var.bound` false). `(def x v)`
    // assigns the value via `intern` (sets `Var.bound`).
    const var_ptr = if (n.has_init) blk: {
        const v = try eval(rt, env, locals, n.value_expr);
        break :blk try env.intern(ns, n.name, v, null);
    } else try env.internDeclare(ns, n.name);
    var_ptr.flags.dynamic = n.is_dynamic;
    var_ptr.flags.macro_ = n.is_macro;
    var_ptr.flags.private = n.is_private;
    return Value.encodeHeapPtr(.var_ref, var_ptr);
}

fn evalIf(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.IfNode) !Value {
    const cond = try eval(rt, env, locals, n.cond);
    if (cond.isTruthy()) {
        return eval(rt, env, locals, n.then_branch);
    }
    if (n.else_branch) |eb| {
        return eval(rt, env, locals, eb);
    }
    return .nil_val;
}

fn evalDo(rt: *Runtime, env: *Env, locals: []Value, forms: []const Node) !Value {
    var last: Value = .nil_val;
    for (forms) |*f| {
        last = try eval(rt, env, locals, f);
    }
    return last;
}

fn evalLet(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LetNode) !Value {
    for (n.bindings) |b| {
        if (b.index >= locals.len)
            return error_catalog.raise(.slot_out_of_range, n.loc, .{ .form = "let*", .index = b.index, .max = locals.len });
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    return eval(rt, env, locals, n.body);
}

fn evalLetfn(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LetfnNode) !Value {
    // Step 1: nil-init every letfn slot so the closures (which snapshot
    // their enclosing locals by value at allocation) see a defined — if
    // not-yet-real — sibling.
    for (n.bindings) |b| {
        if (b.index >= locals.len)
            return error_catalog.raise(.slot_out_of_range, n.loc, .{ .form = "letfn*", .index = b.index, .max = locals.len });
        locals[b.index] = .nil_val;
    }
    // Step 2: allocate each closure and store it in its slot.
    for (n.bindings) |b| {
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    // Step 3: patch every closure's captured letfn slots with the real
    // siblings so mutual (and self) recursion resolves at call time. The
    // analyser declares the names consecutively, so the slots are the
    // contiguous range [base, base+count).
    if (n.bindings.len > 0)
        patchLetfnClosures(locals, n.bindings[0].index, @intCast(n.bindings.len));
    return eval(rt, env, locals, n.body);
}

/// Wire a letfn group's by-value closures together: for each bound fn in
/// the contiguous slot range `[base, base+count)`, overwrite the captured
/// copies of those slots with the now-final sibling fns. Shared by the
/// TreeWalk `evalLetfn` arm and the VM `op_letfn_patch` dispatch arm so
/// both backends agree by construction.
pub fn patchLetfnClosures(locals: []const Value, base: u16, count: u16) void {
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const fv = locals[base + i];
        if (fv.tag() != .fn_val) continue;
        const f = fv.decodePtr(*Function);
        const cb = f.closure_bindings orelse continue;
        var j: u16 = 0;
        while (j < count) : (j += 1) {
            if (base + j < cb.len) cb[base + j] = locals[base + j];
        }
    }
}

/// `(binding [*v* e ...] body)` — push a per-thread dynamic frame.
/// JVM parallel-eval: all inits evaluate in the OUTER context first,
/// then all targets are validated dynamic (mirroring
/// `pushThreadBindings`'s per-Var check), then one frame is pushed for
/// the body. `defer popFrame()` pops on both normal return and an
/// error unwind (= JVM `finally`).
fn evalBinding(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.BindingNode) anyerror!Value {
    var frame: env_mod.BindingFrame = .{};
    defer frame.bindings.deinit(rt.gpa);
    // Pass 1: eval inits in the outer scope (side effects happen here,
    // before any validation — matches JVM hash-map construction order).
    for (n.pairs) |pair| {
        const val = try eval(rt, env, locals, pair.value_expr);
        try frame.bindings.put(rt.gpa, pair.var_ptr, val);
    }
    // Pass 2: validate dynamic-ness before installing the frame.
    for (n.pairs) |pair| {
        if (!pair.var_ptr.flags.dynamic) {
            var name_buf: [512]u8 = undefined;
            const qualified = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ pair.var_ptr.ns.name, pair.var_ptr.name }) catch pair.var_ptr.name;
            return error_catalog.raise(.binding_target_not_dynamic, n.loc, .{ .@"var" = qualified });
        }
    }
    env_mod.pushFrame(&frame);
    // current_ns is a materialised view of *ns* (ADR-0085): if this frame
    // rebinds *ns*, refresh now so the body sees the bound ns; the deferred
    // refresh (declared before popFrame, so it runs AFTER it) restores the
    // outer ns on pop.
    defer env.refreshCurrentNs();
    defer env_mod.popFrame();
    env.refreshCurrentNs();
    return eval(rt, env, locals, n.body);
}

fn evalLoop(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LoopNode) anyerror!Value {
    // Initial bindings — same shape as `let*`, but every recur returns
    // here to rewrite the same slots and re-enter the body.
    for (n.bindings) |b| {
        if (b.index >= locals.len)
            return error_catalog.raise(.slot_out_of_range, n.loc, .{ .form = "loop*", .index = b.index, .max = locals.len });
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    while (true) {
        if (eval(rt, env, locals, n.body)) |result| {
            return result;
        } else |err| switch (err) {
            error.RecurSignaled => {
                if (pending_recur_len != n.bindings.len)
                    return error_catalog.raise(.recur_arity_mismatch, n.loc, .{ .target = "loop*", .expected = n.bindings.len, .got = pending_recur_len });
                for (n.bindings, 0..) |b, i| {
                    locals[b.index] = pending_recur_buf[i];
                }
                pending_recur_len = 0;
            },
            else => return err,
        }
    }
}

fn evalRecur(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.RecurNode) anyerror!Value {
    if (n.args.len > pending_recur_buf.len)
        return error_catalog.raise(.recur_args_exceed_buffer, n.loc, .{ .got = n.args.len, .max = pending_recur_buf.len });
    // Evaluate **all** args before mutating any slot — otherwise a
    // recur arg that referenced an earlier binding would see the
    // partially-rewritten frame. Stash them in the threadlocal scratch
    // so the matching loop frame can drain them once the unwind
    // returns control.
    for (n.args, 0..) |*a, i| {
        pending_recur_buf[i] = try eval(rt, env, locals, a);
    }
    pending_recur_len = @intCast(n.args.len);
    return error.RecurSignaled;
}

fn evalThrow(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.ThrowNode) anyerror!Value {
    const v = try eval(rt, env, locals, n.expr);
    dispatch.last_thrown_exception = v;
    // Snapshot *error-context* now — the `binding` frame is still live
    // here, but is popped by `defer popFrame` as this error unwinds, so
    // the renderer cannot deref it later (ADR-0055 am2 / D-144).
    dispatch.last_thrown_context = error_mod.snapshotContext();
    return error.ThrownValue;
}

fn evalTry(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.TryNode) anyerror!Value {
    if (eval(rt, env, locals, n.body)) |result| {
        // Success path — finally still runs unconditionally. If
        // finally itself throws, that exception propagates and the
        // original result is dropped (matches Clojure JVM semantics).
        if (n.finally_body) |fb| {
            _ = try eval(rt, env, locals, fb);
        }
        return result;
    } else |err| {
        // Determine the thrown Value for catch-matching. Two sources
        // funnel into the SAME catch-clause loop (F-011 commonisation):
        //  - user `(throw v)`: error.ThrownValue + last_thrown_exception.
        //  - ADR-0060: a user-domain internal error (error_catalog) whose
        //    Kind maps to an exception class → synthesize a class-name-
        //    bearing ex_info from the threadlocal Info. internal_error /
        //    out_of_memory / not_implemented map to null = uncatchable.
        var thrown: ?Value = null;
        if (err == error.ThrownValue) {
            thrown = dispatch.last_thrown_exception orelse return error_catalog.raiseInternal(n.loc, "ThrownValue without last_thrown_exception");
        } else if (error_mod.peekLastError()) |info| {
            if (host_class.kindToHostClass(info.kind)) |class| {
                // Synthesize ONCE: the internal error becomes a thrown
                // exception Value and propagates as error.ThrownValue
                // thereafter — identical to a user throw, identical to the
                // VM handler path (parity). A truly uncaught error (no
                // enclosing try) never reaches here, so it keeps its raw
                // Zig error + `[kind]` CLI header.
                const synth = try ex_info_collection.allocException(rt, info.message, class);
                dispatch.last_thrown_exception = synth;
                error_mod.clearLastError();
                thrown = synth;
            }
        }
        if (thrown) |tv| {
            for (n.catch_clauses) |cc| {
                if (try catchMatches(rt, cc.target, tv)) {
                    dispatch.last_thrown_exception = null;
                    dispatch.last_thrown_context = null;
                    if (cc.binding_index >= locals.len)
                        return error_catalog.raise(.slot_out_of_range, cc.loc, .{ .form = "catch", .index = cc.binding_index, .max = locals.len });
                    locals[cc.binding_index] = tv;
                    const caught = eval(rt, env, locals, cc.body);
                    if (n.finally_body) |fb| {
                        _ = try eval(rt, env, locals, fb);
                    }
                    return caught;
                }
            }
            // No catch matched — finally runs, then re-raise as a thrown
            // value (last_thrown_exception holds `tv`), so the outer frame's
            // ThrownValue arm matches it.
            if (n.finally_body) |fb| {
                _ = try eval(rt, env, locals, fb);
            }
            return error.ThrownValue;
        }
        // Uncatchable (internal_error / out_of_memory / not_implemented /
        // a non-catalog Zig error such as OOM) — finally for resource
        // release, then bubble with the `[kind]` Info intact.
        if (n.finally_body) |fb| {
            _ = eval(rt, env, locals, fb) catch {};
        }
        return err;
    }
}

fn catchMatches(rt: *Runtime, target: node_mod.TryNode.CatchTarget, thrown: Value) !bool {
    return switch (target) {
        // Row 7.11 cycle 2 (D-077): delegate to the shared host-class
        // hierarchy. The VM backend mirrors this arm at vm.zig:594.
        .class_name => |name| host_class.matches(thrown, name),
        // Row 14.5 (D-014b): keyword target matches when the thrown
        // is an ex-info whose data map carries `:type` equal (by
        // interned identity) to the catch keyword. The VM lowering
        // for this arm rides ADR-0036 VM-DEFER per compiler.zig.
        .type_keyword => |kw_val| blk: {
            if (thrown.tag() != .ex_info) break :blk false;
            const data_v = ex_info_collection.data(thrown);
            const type_kw = (try keyword_mod.intern(rt, null, "type"));
            const got = map_collection.get(data_v, type_kw) catch break :blk false;
            break :blk @intFromEnum(got) == @intFromEnum(kw_val);
        },
    };
}

fn evalCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.CallNode) !Value {
    const callee = try eval(rt, env, locals, n.callee);
    var args_buf: [MAX_LOCALS]Value = undefined;
    if (n.args.len > MAX_LOCALS)
        return error_catalog.raise(.call_args_exceed_max_locals, n.loc, .{ .got = n.args.len, .max = MAX_LOCALS });
    for (n.args, 0..) |*a, i| {
        args_buf[i] = try eval(rt, env, locals, a);
    }
    const args = args_buf[0..n.args.len];
    if (rt.vtable) |vt| {
        return vt.callFn(rt, env, callee, args, n.loc);
    }
    return error_catalog.raiseInternal(n.loc, "Runtime vtable not installed; cannot dispatch call");
}

// --- Backend's callFn (registered as rt.vtable.callFn) ---

/// `dispatch.CallFn` implementation. Dispatches on the callee's tag:
/// `.fn_val` evaluates the body; `.builtin_fn` calls the C function
/// directly.
pub fn treeWalkCall(
    rt: *Runtime,
    env: *Env,
    callee: Value,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value {
    return switch (callee.tag()) {
        .fn_val => callFunction(rt, env, callee, args, loc),
        .builtin_fn => callBuiltin(rt, env, callee, args, loc),
        .multi_fn => multimethod_mod.callMultiFn(rt, env, callee, args, loc),
        .protocol_fn => callProtocolFn(rt, env, callee, args, loc),
        // Data structures + keywords as IFn (D-085): (:k m) / (m k) /
        // (#{…} x) / ([…] i). Routes through the same dispatch so the VM,
        // `apply`, and `(map :k coll)` all get it for free.
        .keyword, .symbol, .array_map, .hash_map, .hash_set, .vector, .sorted_map, .sorted_set => lookup_mod.invoke(rt, env, callee, args, loc),
        else => |t| error_catalog.raise(.value_not_callable, loc, .{ .actual = @tagName(t) }),
    };
}

/// Dispatch `(m receiver args...)` where `m` is a `.protocol_fn`
/// Value. The receiver is `args[0]` (cw v1 mirrors JVM Clojure's
/// "first arg is the dispatch target" convention); the impl
/// fn (typically `(fn* [this ...] body)`) receives the receiver as
/// its first parameter, so the FULL `args` slice (receiver +
/// remaining) flows through to `dispatch.dispatch` → `vt.callFn`.
/// CallSite is stack-allocated per call. (Compiled method dispatch
/// uses an analyzer-arena-owned, inline-cached CallSite via
/// `op_method_call`; this protocol-fn path keeps a per-call CallSite,
/// so every invocation pays one method_table linear scan — small N,
/// Clojure protocols typically ≤ 8 methods.)
pub fn callProtocolFn(rt: *Runtime, env: *Env, callee: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "protocol-fn", .got = args.len, .min = 1 });
    const pfn = protocol_mod.asProtocolFn(callee);
    const receiver = args[0];
    var cs: method_table.CallSite = .{};
    return dispatch.dispatch(
        rt,
        env,
        &cs,
        receiver,
        pfn.descriptor.fqcn(),
        pfn.methodName(),
        args,
        loc,
    );
}

/// How `& rest` is bound from the trailing args. `wrap` cons-packs the
/// trailing args into a fresh one-element-or-more list — the correct,
/// default behaviour for EVERY normal call (incl. a single seq-shaped
/// arg: `((fn [a & xs] xs) 1 '(2 3))` → `xs = ((2 3))`). `bind_direct`
/// binds a single seq-shaped trailing arg straight to `& rest` (no
/// re-cons, lazy-preserving) — used ONLY by `apply`'s spread (ADR-0042
/// am1). The mode is an explicit typed parameter, not shared state: the
/// original shape-only gate (and cw v0's `apply_rest_is_seq` threadlocal)
/// conflated apply-spread with a normal single-seq-arg call (a
/// correctness bug ADR-0042's own Decision rejected on F-002 grounds).
const RestMode = enum { wrap, bind_direct };

/// Generic fn call — the entry every backend reaches via `vtable.callFn`.
/// Always cons-wraps `& rest` (unconditionally correct).
pub fn callFunction(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) !Value {
    return callMethodImpl(rt, env, fn_val.decodePtr(*Function), args, loc, .wrap);
}

/// ADR-0042 am1: `apply`'s lazy-preserving entry. `args = [leading…,
/// rest_seq]`; `applyFn::canBindDirect` has verified the callee is a
/// variadic fn whose `& rest` should bind `rest_seq` DIRECTLY. Distinct
/// from `callFunction` so the generic path stays wrap-only — no flag, no
/// shared mutable state, the signal is the in-band `RestMode` argument.
pub fn callFunctionBindingRest(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) !Value {
    return callMethodImpl(rt, env, fn_val.decodePtr(*Function), args, loc, .bind_direct);
}

fn callMethodImpl(rt: *Runtime, env: *Env, f: *Function, args: []const Value, loc: SourceLocation, rest_mode: RestMode) !Value {
    // Row 7.8 cycle 1 (ADR-0041): linear scan over `methods`, fixed-
    // arity wins on exact match; fall through to `variadic` when
    // `args.len >= variadic.arity`. Single-arity fns produce a
    // 1-element `methods` slice = same code path.
    const m: *const FunctionMethod = selectMethod(f, args.len) orelse {
        return raiseArityNotMatched(f, args.len, loc);
    };

    const frame_slots: usize = @as(usize, f.slot_base) + m.arity + @intFromBool(m.has_rest);
    if (frame_slots > MAX_LOCALS)
        return error_catalog.raise(.fn_frame_exceeds_max_locals, loc, .{ .base = f.slot_base, .arity = m.arity, .max = MAX_LOCALS });

    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    if (f.closure_bindings) |snap| {
        @memcpy(locals[0..snap.len], snap);
    }
    for (args[0..m.arity], 0..) |v, i| {
        locals[f.slot_base + i] = v;
    }
    if (m.has_rest) {
        // bind_direct only fires on apply's exact shape (one seq-shaped
        // trailing arg); vectors are excluded so JVM `(apply f x [y])`
        // spread stays (xs = (y), not [y]). Everything else cons-wraps.
        if (rest_mode == .bind_direct and args.len == m.arity + 1 and isRestSeqShaped(args[m.arity])) {
            locals[f.slot_base + m.arity] = args[m.arity];
        } else {
            // Cons-wrap the trailing args (those past `m.arity`). JVM
            // Clojure binds `& rest` to a seq view; cw v1 builds the
            // simpler heap List (Cons chain). Empty trailing → nil per
            // `(defn f [& xs] xs) → (f)` returning nil.
            var rest_list: Value = .nil_val;
            var i: usize = args.len;
            while (i > m.arity) {
                i -= 1;
                rest_list = try list_mod.consHeap(rt, args[i], rest_list);
            }
            locals[f.slot_base + m.arity] = rest_list;
        }
    }
    // VM backend hook: when this method carries compiled bytecode and
    // the vtable has the `evalChunk` slot wired (vm.installVTable), run
    // the chunk instead of walking the Node body. The TreeWalk backend
    // leaves `evalChunk` null and always reaches the `eval(...)` line.
    if (m.bytecode) |chunk| {
        if (rt.vtable) |vt| {
            if (vt.evalChunk) |ec| return ec(rt, env, &locals, @ptrCast(chunk));
        }
    }
    // A deserialized (AOT) fn has bytecode but only a sentinel body; it must
    // run via the VM `evalChunk` path above. Reaching the tree_walk body
    // here means a deserialized fn was called on a backend without
    // `evalChunk` wired — surface it rather than silently walking the nil
    // sentinel (ADR-0034 am2 A2-D3).
    if (m.body == &deserialized_fn_body)
        return error_catalog.raise(.feature_not_supported, .{}, .{
            .name = "deserialized function on a backend without VM evalChunk",
        });
    // A tail `recur` in the fn body re-enters here with the parameter
    // slots rebound — JVM treats a fn as an implicit `loop*` over its
    // params (D-090). Mirrors `evalLoop`'s catch, targeting the param
    // slots `[slot_base, slot_base + arity (+rest)]`. A `recur` inside an
    // enclosing `loop*` unwinds to that `evalLoop` first (inner frame), so
    // only fn-tail recurs reach this catch.
    const recur_arity: u16 = m.arity + @intFromBool(m.has_rest);
    while (true) {
        if (eval(rt, env, &locals, m.body)) |result| {
            return result;
        } else |err| switch (err) {
            error.RecurSignaled => {
                if (pending_recur_len != recur_arity)
                    return error_catalog.raise(.recur_arity_mismatch, loc, .{ .target = "fn*", .expected = recur_arity, .got = pending_recur_len });
                for (0..recur_arity) |i| {
                    locals[f.slot_base + i] = pending_recur_buf[i];
                }
                pending_recur_len = 0;
            },
            else => return err,
        }
    }
}

/// ADR-0042: tags eligible for the bind-direct rest-pack fast-path —
/// already shape-compatible with Clojure's `& rest` binding (an ISeq).
/// Vector / set / map / etc. are intentionally excluded so their spread
/// semantics stay observable for `(apply f x [y])`-style calls.
fn isRestSeqShaped(v: Value) bool {
    return switch (v.tag()) {
        .list, .cons, .chunked_cons, .lazy_seq, .nil => true,
        else => false,
    };
}

fn selectMethod(f: *const Function, n: usize) ?*const FunctionMethod {
    for (f.methods) |*m| {
        if (m.arity == n) return m;
    }
    if (f.variadic) |*v| {
        if (n >= v.arity) return v;
    }
    return null;
}

fn raiseArityNotMatched(f: *const Function, got: usize, loc: SourceLocation) anyerror {
    // For single-arity fixed fns, preserve the existing
    // arity_not_expected / arity_below_min diagnostics so existing
    // user-visible error text stays stable.
    if (f.variadic == null and f.methods.len == 1) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "fn", .got = got, .expected = f.methods[0].arity });
    }
    if (f.variadic) |v| {
        if (f.methods.len == 0) {
            return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "fn", .got = got, .min = v.arity });
        }
    }
    // Multi-arity: build a "1, 2, or [3 & rest]" string for the message.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var first = true;
    for (f.methods) |m| {
        if (!first) w.print(", ", .{}) catch break;
        w.print("{d}", .{m.arity}) catch break;
        first = false;
    }
    if (f.variadic) |v| {
        if (!first) w.print(", or ", .{}) catch {};
        w.print("[{d} & rest]", .{v.arity}) catch {};
    }
    return error_catalog.raise(.arity_not_expected_multi, loc, .{ .fn_name = "fn", .got = got, .arities = w.buffered() });
}

fn callBuiltin(rt: *Runtime, env: *Env, callee: Value, args: []const Value, loc: SourceLocation) !Value {
    // `.builtin_fn` carries the 48-bit fn pointer in the Value itself.
    const fn_ptr = callee.asBuiltinFn(dispatch.BuiltinFn);
    return fn_ptr(rt, env, args, loc);
}

// --- VTable installer ---

/// Populate `rt.vtable` with the TreeWalk callbacks. Call once at
/// startup, after `Runtime.init` and `Env.init`. Macro expansion is
/// **not** installed here — it lives in `eval/macro_dispatch.zig` and
/// is threaded explicitly into `analyze`. See ADR 0001.
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &treeWalkCall,
        .valueTypeKey = &valueTypeKey,
    };
}

pub fn valueTypeKey(v: Value) []const u8 {
    return @tagName(v.tag());
}

// --- tests ---

const testing = std.testing;
const Reader = @import("../reader.zig").Reader;
const analyze = @import("../analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../macro_dispatch.zig");

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    macro_table: macro_dispatch.Table,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.macro_table = macro_dispatch.Table.init(alloc);
        installVTable(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.macro_table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn evalStr(self: *TestFixture, source: []const u8) !Value {
        var reader = Reader.init(self.arena.allocator(), source);
        const form = (try reader.read()) orelse return error.ReadEmpty;
        const node = try analyze(self.arena.allocator(), &self.rt, &self.env, null, form, &self.macro_table);
        var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
        return eval(&self.rt, &self.env, &locals, node);
    }
};

// Built-in `+` used by the Phase-2 exit-criterion smoke tests. Phase
// 2.7 / 2.8 land the proper version under `lang/primitive/math.zig`;
// inlining a minimal one here keeps this test-only and avoids the
// upward import (zone violation) into lang/.
fn builtinPlus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    var sum: i64 = 0;
    for (args) |v| {
        sum += switch (v.tag()) {
            .integer => @as(i64, v.asInteger()),
            else => return error.PlusArgNotInteger,
        };
    }
    return Value.initInteger(sum);
}

fn allocFunctionFailingHarness(alloc_inner: std.mem.Allocator) !void {
    var th = std.Io.Threaded.init(alloc_inner, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), alloc_inner);
    defer rt.deinit();
    // Minimal FnNode reaching allocFunction's slot_base == 0 path
    // (no closure). The body Node lives on the stack — allocFunction
    // only stores the pointer, never dereferences it during alloc.
    const body = node_mod.Node{ .constant = .{ .value = .nil_val } };
    const methods = [_]node_mod.FnMethod{.{
        .arity = 0,
        .params = &.{},
        .body = &body,
    }};
    const fn_node = node_mod.FnNode{
        .methods = &methods,
        .slot_base = 0,
    };
    _ = try allocFunction(&rt, fn_node, &.{});
}

test "allocFunction returns OOM without leaking under each allocation failure (uniform errdefer)" {
    try testing.checkAllAllocationFailures(testing.allocator, allocFunctionFailingHarness, .{});
}

test "Function is 8-byte aligned (NaN boxing safety)" {
    try testing.expectEqual(@as(usize, 8), @alignOf(Function));
}

test "eval atoms: nil / true / 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, try fix.evalStr("nil"));
    try testing.expectEqual(Value.true_val, try fix.evalStr("true"));
    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("42")).asInteger());
}

test "eval (if true 1 2) and (if false 1 2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 1), (try fix.evalStr("(if true 1 2)")).asInteger());
    try testing.expectEqual(@as(i48, 2), (try fix.evalStr("(if false 1 2)")).asInteger());
}

test "eval (if false 1) without else returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(Value.nil_val, try fix.evalStr("(if false 1)"));
}

test "eval (do 1 2 3) returns the last form" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(do 1 2 3)")).asInteger());
}

test "eval (let* [x 1 y 2] y)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(@as(i48, 2), (try fix.evalStr("(let* [x 1 y 2] y)")).asInteger());
}

test "eval (def x 42) creates a Var; subsequent x returns 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def x 42)");
    const user = fix.env.findNs("user").?;
    const v = user.resolve("x").?;
    try testing.expectEqual(@as(i48, 42), v.root.asInteger());

    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("x")).asInteger());
}

test "eval (quote nil) returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectEqual(Value.nil_val, try fix.evalStr("(quote nil)"));
}

test "eval (fn* [x] x) returns a callable .fn_val" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(fn* [x] x)");
    try testing.expect(r.tag() == .fn_val);
}

test "eval ((fn* [x] x) 41) → 41 (Phase-2 exit criterion 2/2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("((fn* [x] x) 41)");
    try testing.expectEqual(@as(i48, 41), r.asInteger());
}

test "eval (def id (fn* [x] x)) (id 7) → 7" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    try testing.expectEqual(@as(i48, 7), (try fix.evalStr("(id 7)")).asInteger());
}

test "eval calls a built-in registered through Env.intern" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus), null);

    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(+ 1 2)")).asInteger());
}

test "eval (let* [x 1] (+ x 2)) → 3 (Phase-2 exit criterion 1/2)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus), null);

    try testing.expectEqual(@as(i48, 3), (try fix.evalStr("(let* [x 1] (+ x 2))")).asInteger());
}

test "eval ((fn* [x] (+ x 1)) 41) → 42 (Phase-2 exit criterion combined)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus), null);

    try testing.expectEqual(@as(i48, 42), (try fix.evalStr("((fn* [x] (+ x 1)) 41)")).asInteger());
}

test "calling a non-callable Value yields NotCallable" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", Value.initInteger(7), null);
    try testing.expectError(error.TypeError, fix.evalStr("(x 1 2)"));
}

test "calling a fn with wrong arity yields ArityMismatch" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    try testing.expectError(error.ArityError, fix.evalStr("(id 1 2)"));
}

test "non-callable callee populates last_error with eval phase" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", Value.initInteger(7), null);

    error_mod.clearLastError();
    try testing.expectError(error.TypeError, fix.evalStr("(x 1 2)"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.type_error, info.kind);
    try testing.expectEqual(error_mod.Phase.eval, info.phase);
    try testing.expect(std.mem.find(u8, info.message, "Cannot call value") != null);
}

test "wrong arity populates last_error with eval phase" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    _ = try fix.evalStr("(def id (fn* [x] x))");
    error_mod.clearLastError();
    try testing.expectError(error.ArityError, fix.evalStr("(id 1 2)"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.arity_error, info.kind);
    try testing.expectEqual(error_mod.Phase.eval, info.phase);
}

// --- §9.5/3.11 — loop* / recur ---

test "eval (loop* [x nil] (if x x (recur 42))) → 42" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(loop* [x nil] (if x x (recur 42)))");
    try testing.expectEqual(@as(i48, 42), r.asInteger());
}

test "eval (loop* [n 3 acc nil] (if acc acc (recur n n))) → 3" {
    // Two-binding loop: rebinds both slots; second iteration the
    // previously-nil acc is now `n` (3, truthy) and we return it.
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(loop* [n 3 acc nil] (if acc acc (recur n n)))");
    try testing.expectEqual(@as(i48, 3), r.asInteger());
}

test "recur outside loop / fn is rejected at analysis (already in 3.9)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectError(error.SyntaxError, fix.evalStr("(recur 1)"));
}

// --- §9.5/3.11 — throw / try / catch / finally ---

test "eval (throw 42) raises ThrownValue and stashes the Value" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    dispatch.last_thrown_exception = null;
    try testing.expectError(error.ThrownValue, fix.evalStr("(throw 42)"));
    const v = dispatch.last_thrown_exception orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i48, 42), v.asInteger());
    dispatch.last_thrown_exception = null;
}

test "eval try with no catch returns body value" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const r = try fix.evalStr("(try 7)");
    try testing.expectEqual(@as(i48, 7), r.asInteger());
}

test "eval try / catch ExceptionInfo binds the thrown ex-info" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Register `ex-info` so the catch path has a real ex_info Value to
    // match against. Phase 3.10 lives in `lang/primitive/error.zig`;
    // the Node tree imports nothing from `lang/`, but tests are
    // exempt from the zone gate so we can set up a minimal binding
    // here without dragging registerAll in.
    const error_prim = @import("../../lang/primitive/error.zig");
    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "ex-info", Value.initBuiltinFn(&error_prim.exInfo), null);

    const r = try fix.evalStr(
        "(try (throw (ex-info \"boom\" 0)) (catch ExceptionInfo e e))",
    );
    try testing.expect(r.tag() == .ex_info);
}

test "eval try / finally runs finally on success" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Use `def` from inside finally so we can observe the side effect.
    _ = try fix.evalStr("(try 1 (finally (def *side* 42)))");
    const user = fix.env.findNs("user").?;
    const v = user.resolve("*side*").?;
    try testing.expectEqual(@as(i48, 42), v.root.asInteger());
}

test "eval try / finally runs finally then rethrows" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    dispatch.last_thrown_exception = null;
    try testing.expectError(
        error.ThrownValue,
        fix.evalStr("(try (throw 7) (finally (def *side2* 99)))"),
    );
    const user = fix.env.findNs("user").?;
    const v = user.resolve("*side2*").?;
    try testing.expectEqual(@as(i48, 99), v.root.asInteger());
    const thrown = dispatch.last_thrown_exception orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i48, 7), thrown.asInteger());
    dispatch.last_thrown_exception = null;
}

// --- §9.5/3.11 — fn* closure capture ---

test "eval ((fn* [x] (fn* [y] x)) 3) returns a closure capturing x" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const inner = try fix.evalStr("((fn* [x] (fn* [y] x)) 3)");
    try testing.expect(inner.tag() == .fn_val);
}

test "eval (((fn* [x] (fn* [y] (+ x y))) 3) 4) → 7 (lexical closure)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus), null);

    const r = try fix.evalStr("(((fn* [x] (fn* [y] (+ x y))) 3) 4)");
    try testing.expectEqual(@as(i48, 7), r.asInteger());
}

test "eval (let* [x 5] ((fn* [y] (+ x y)) 6)) → 11 (closure over let)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", Value.initBuiltinFn(&builtinPlus), null);

    const r = try fix.evalStr("(let* [x 5] ((fn* [y] (+ x y)) 6))");
    try testing.expectEqual(@as(i48, 11), r.asInteger());
}
