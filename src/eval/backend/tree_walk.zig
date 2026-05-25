//! TreeWalk — Phase-2 backend: evaluate the Node tree by recursive
//! descent.
//!
//! This is the simplest possible interpreter. Phase 4 adds a bytecode
//! VM, but TreeWalk stays in the tree afterwards: it's the reference
//! implementation Phase 8's `Evaluator.compare` cross-checks the VM
//! against (dual-backend verification, ROADMAP §4.4).
//!
//! ### Phase-2 scope (this commit)
//!
//! - Constants / locals / vars: trivial.
//! - Special forms: def, if, do, quote, fn*, let*.
//! - Function call: dispatched through `Runtime.vtable.callFn`, which
//!   `installVTable(rt)` populates with `treeWalkCall` from this file.
//! - Built-ins: `Value.builtin_fn` invoked directly via the
//!   `dispatch.BuiltinFn` signature.
//!
//! `loop*` / `recur` / macros / multi-arity / closures-over-locals are
//! deferred to Phase 3+.
//!
//! ### Function representation
//!
//! `Function` is a heap-allocated struct wrapped in a NaN-boxed
//! `.fn_val` Value. Phase-2 minimum: no closure capture — top-level
//! fns and any fn that only references global Vars work. Genuine
//! lexical closures (`(let* [x 1] (fn* [y] (+ x y)))`) need an
//! environment slot vector and land in Phase 3+.
//!
//! ### Locals
//!
//! Every call frame uses a fixed-size 256-slot stack array. The VM
//! (Phase 4) will tighten this to the analyser-known frame size.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const HeapHeader = @import("../../runtime/value/value.zig").HeapHeader;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const list_mod = @import("../../runtime/collection/list.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const opcode_mod = @import("vm/opcode.zig");
const BytecodeChunk = opcode_mod.BytecodeChunk;

/// Per-frame slot-array size. Generous so the analyser can lay out
/// `let*` chains without checking; the VM (Phase 4) will switch to a
/// frame-size known at analyse time.
pub const MAX_LOCALS: u16 = 256;

/// TreeWalk error surface. Aliases `error_mod.ClojureWasmError` so
/// calls to `error_catalog.raise(.code, loc, args)` type-check; the
/// backend still only **emits** `error.TypeError` (non-callable
/// callee), `error.ArityError` (wrong number of args),
/// `error.IndexError` (slot out of range), `error.NotImplemented`
/// (Phase-3+ feature stub), `error.InternalError` (defensive runtime
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

/// Closure object emitted by `fn*`. Phase 3.11 adds `slot_base` and
/// `closure_bindings` so a fn nested inside `let*` / `fn*` snapshots
/// its enclosing locals at allocation time and replays them on every
/// call. Top-level fns have `slot_base == 0` and `closure_bindings ==
/// null`. The `body` and `params` slices borrow from the analyser's
/// per-eval arena, so the Function lives only as long as that arena
/// does. `closure_bindings` is owned by the Function (separate
/// gpa allocation) and freed by `freeFunction`.
pub const Function = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    arity: u16,
    has_rest: bool,
    /// Number of locals the analyser allocated above this fn — these
    /// are the slots the closure snapshot fills, and the fn's params
    /// land at `[slot_base, slot_base + arity)`.
    slot_base: u16,
    /// Function body — borrowed from the analyser arena.
    body: *const Node,
    /// Parameter names (debug + error frames). Borrowed too.
    params: []const []const u8,
    /// Captured outer locals; null when the fn closes over nothing
    /// (top-level fn) so the common case stays a single null check
    /// rather than an empty-slice round-trip.
    closure_bindings: ?[]Value,
    /// Compiled bytecode body. `null` means TreeWalk evaluates the
    /// `body` Node directly; non-null means the VM dispatcher
    /// (task 4.6) uses this chunk and ignores `body`. The two paths
    /// produce bit-for-bit identical Values under
    /// `Evaluator.compare` (ADR-0005 / ADR-0022). The chunk slices
    /// live in the analyser arena alongside `body`/`params`.
    bytecode: ?*const BytecodeChunk = null,
};

/// Heap-allocate a Function and wrap it in a NaN-boxed Value. The
/// caller's `locals` array supplies the snapshot for closure capture:
/// slots `[0, fn_node.slot_base)` are duplicated into a fresh
/// gpa-owned slice the Function will later replay on every call. Top
/// -level fns (`slot_base == 0`) skip the allocation entirely. Until
/// the Phase-5 GC arrives, register the allocation with
/// `rt.heap_objects` so `Runtime.deinit` frees it.
pub fn allocFunction(rt: *Runtime, fn_node: node_mod.FnNode, locals: []const Value) !Value {
    return allocFunctionMaybeBytecode(rt, fn_node, locals, null);
}

/// Same as `allocFunction` but stamps a compiled bytecode body onto
/// the Function. The VM dispatcher (task 4.6) uses `bytecode` when
/// set; the `body` Node is still stored so error frames can cite the
/// source form.
pub fn allocFunctionWithBytecode(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    locals: []const Value,
    bytecode: *const BytecodeChunk,
) !Value {
    return allocFunctionMaybeBytecode(rt, fn_node, locals, bytecode);
}

/// Allocate a Function that carries `fn_node.slot_base` for the VM's
/// `op_make_fn` dispatcher to read at run time, but defers the actual
/// closure snapshot until then. `closure_bindings` is `null` even when
/// `slot_base > 0`. The dispatcher calls `allocFunctionWithBytecode`
/// with the live `locals` to produce the per-evaluation Function from
/// this template.
pub fn allocFunctionTemplate(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    bytecode: *const BytecodeChunk,
) !Value {
    const f = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(f);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .arity = fn_node.arity,
        .has_rest = fn_node.has_rest,
        .slot_base = fn_node.slot_base,
        .body = fn_node.body,
        .params = fn_node.params,
        .closure_bindings = null,
        .bytecode = bytecode,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn allocFunctionMaybeBytecode(
    rt: *Runtime,
    fn_node: node_mod.FnNode,
    locals: []const Value,
    bytecode: ?*const BytecodeChunk,
) !Value {
    const closure: ?[]Value = if (fn_node.slot_base == 0)
        null
    else blk: {
        const slice = try rt.gpa.alloc(Value, fn_node.slot_base);
        @memcpy(slice, locals[0..fn_node.slot_base]);
        break :blk slice;
    };
    errdefer if (closure) |s| rt.gpa.free(s);

    const f = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(f);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .arity = fn_node.arity,
        .has_rest = fn_node.has_rest,
        .slot_base = fn_node.slot_base,
        .body = fn_node.body,
        .params = fn_node.params,
        .closure_bindings = closure,
        .bytecode = bytecode,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}

fn freeFunction(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const f: *Function = @ptrCast(@alignCast(ptr));
    if (f.closure_bindings) |s| gpa.free(s);
    gpa.destroy(f);
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
        .call_node => |n| try evalCall(rt, env, locals, n),
        .loop_node => |n| try evalLoop(rt, env, locals, n),
        .recur_node => |n| try evalRecur(rt, env, locals, n),
        .try_node => |n| try evalTry(rt, env, locals, n),
        .throw_node => |n| try evalThrow(rt, env, locals, n),
        .deftype_node => |n| try evalDeftype(rt, n),
        .ctor_call_node => |n| try evalCtorCall(rt, env, locals, n),
        .field_access_node => |n| try evalFieldAccess(rt, env, locals, n),
        .in_ns_node => |n| try evalInNs(env, n),
        .vector_literal_node => |n| try evalVectorLiteral(rt, env, locals, n),
        .map_literal_node => |n| try evalMapLiteral(rt, env, locals, n),
        .set_literal_node => |n| try evalSetLiteral(rt, env, locals, n),
    };
}

/// `(in-ns 'foo.bar)` — switch `env.current_ns` to the named namespace,
/// creating it if absent. Returns `nil` (JVM Clojure returns the
/// namespace value — documented divergence pending the `ns` heap
/// Value landing per F-004 Group B slot 21).
///
/// Additionally refers `rt/` into the entered namespace so primitive
/// vars (`reduce` / `conj` / `disj` / `count` / `every?` / ...) are
/// reachable unqualified from within the ns body. This extends the
/// `referAll(rt_ns, user_ns)` pattern that `primitive.zig::registerAll`
/// establishes for the REPL's initial `user/` ns to every other ns the
/// user opens via `in-ns`. Without this, `(in-ns 'clojure.set) (def
/// union (fn* [s1 s2] (reduce conj s1 s2)))` would fail symbol
/// resolution on `reduce` / `conj`. The full `(ns ...)` macro +
/// explicit `(refer 'clojure.core)` semantics arrive at ADR-0035
/// (Phase 6.16.b-4); until then in-ns carries the convenience refer.
/// Idempotent via `referAll`'s existing-key skip.
fn evalInNs(env: *Env, n: node_mod.InNsNode) !Value {
    env.current_ns = try env.findOrCreateNs(n.ns_name);
    if (env.findNs("rt")) |rt_ns| {
        try env.referAll(rt_ns, env.current_ns.?);
    }
    // clojure.core may not exist yet during core.clj's own (in-ns
    // 'clojure.core) — in that case the entered ns IS clojure.core
    // and refer is a no-op self-cycle. For every later ns (set /
    // walk / string / user dynamic in-ns), clojure.core has been
    // populated by core.clj and is refer'd so unqualified names
    // like `set` / `select-keys` / `merge` / `partial` resolve.
    if (env.findNs("clojure.core")) |clojure_core_ns| {
        try env.referAll(clojure_core_ns, env.current_ns.?);
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

/// Evaluate a `(deftype Name [f1 f2 ...])` form. Allocates a fresh
/// process-lifetime TypeDescriptor on `rt.gpa` and registers it in
/// `rt.types` keyed on the declared name. Returns `nil` (Clojure's
/// `deftype` return value).
fn evalDeftype(rt: *Runtime, n: node_mod.DeftypeNode) !Value {
    // Build the field_layout slice on rt.gpa (process-lifetime).
    const layout = try rt.gpa.alloc(type_descriptor_mod.TypeDescriptor.FieldEntry, n.fields.len);
    errdefer rt.gpa.free(layout);
    for (n.fields, 0..) |fname, i| {
        const dup = try rt.gpa.dupe(u8, fname);
        layout[i] = .{ .name = dup, .index = @intCast(i) };
    }

    const td = try rt.gpa.create(type_descriptor_mod.TypeDescriptor);
    errdefer rt.gpa.destroy(td);
    const fqcn = try rt.gpa.dupe(u8, n.name);
    td.* = .{
        .fqcn = fqcn,
        .kind = .deftype,
        .field_layout = layout,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };

    // Re-register: replacing an existing entry frees the old one to
    // keep `rt.types` consistent across REPL re-defs.
    if (rt.types.fetchRemove(n.name)) |old| {
        rt.gpa.free(old.key);
        if (old.value.field_layout) |old_layout| {
            for (old_layout) |fe| rt.gpa.free(fe.name);
            rt.gpa.free(old_layout);
        }
        if (old.value.fqcn) |o_n| rt.gpa.free(o_n);
        rt.gpa.destroy(@constCast(old.value));
    }
    const key = try rt.gpa.dupe(u8, n.name);
    errdefer rt.gpa.free(key);
    try rt.types.put(key, td);
    return .nil_val;
}

fn evalCtorCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.CtorCallNode) !Value {
    const td = rt.types.get(n.type_name) orelse
        return error_catalog.raise(.symbol_unresolved, n.loc, .{ .sym = n.type_name });
    const expected = if (td.field_layout) |fl| fl.len else 0;
    if (n.args.len != expected) {
        return error_catalog.raise(.arity_not_expected, n.loc, .{ .got = n.args.len, .fn_name = n.type_name, .expected = expected });
    }
    const buf = try rt.gpa.alloc(Value, n.args.len);
    defer rt.gpa.free(buf);
    for (n.args, 0..) |arg_node, i| {
        buf[i] = try eval(rt, env, locals, &arg_node);
    }
    return try type_descriptor_mod.allocInstance(rt, td, buf);
}

fn evalFieldAccess(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.FieldAccessNode) !Value {
    const target_val = try eval(rt, env, locals, n.target);
    if (target_val.tag() != .typed_instance) {
        return error_catalog.raise(.type_arg_not_number, n.loc, .{ .fn_name = "field access", .actual = @tagName(target_val.tag()) });
    }
    const inst = target_val.decodePtr(*const type_descriptor_mod.TypedInstance);
    const layout = inst.descriptor.field_layout orelse
        return error_catalog.raise(.symbol_unresolved, n.loc, .{ .sym = n.field_name });
    for (layout) |fe| {
        if (std.mem.eql(u8, fe.name, n.field_name)) {
            return inst.fields()[fe.index];
        }
    }
    return error_catalog.raise(.symbol_unresolved, n.loc, .{ .sym = n.field_name });
}

fn evalDef(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.DefNode) !Value {
    const v = try eval(rt, env, locals, n.value_expr);
    const ns = env.current_ns orelse
        return error_catalog.raiseInternal(n.loc, "def: no current namespace");
    const var_ptr = try env.intern(ns, n.name, v, null);
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
    } else |err| switch (err) {
        error.ThrownValue => {
            const thrown = dispatch.last_thrown_exception orelse return error_catalog.raiseInternal(n.loc, "ThrownValue without last_thrown_exception");
            // Walk catch clauses linearly — Phase 3 only matches
            // `ExceptionInfo` against `.ex_info`-tagged Values.
            for (n.catch_clauses) |cc| {
                if (catchMatches(cc.class_name, thrown)) {
                    dispatch.last_thrown_exception = null;
                    if (cc.binding_index >= locals.len)
                        return error_catalog.raise(.slot_out_of_range, cc.loc, .{ .form = "catch", .index = cc.binding_index, .max = locals.len });
                    locals[cc.binding_index] = thrown;
                    const caught = eval(rt, env, locals, cc.body);
                    if (n.finally_body) |fb| {
                        _ = try eval(rt, env, locals, fb);
                    }
                    return caught;
                }
            }
            // No catch matched — finally runs, then we re-raise.
            if (n.finally_body) |fb| {
                _ = try eval(rt, env, locals, fb);
            }
            // last_thrown_exception is still populated; the outer
            // frame (or the CLI) sees the same Value.
            return error.ThrownValue;
        },
        else => {
            // Non-Clojure errors (OOM, internal_error, etc.) still run
            // finally so external resources get released, then bubble.
            if (n.finally_body) |fb| {
                _ = eval(rt, env, locals, fb) catch {};
            }
            return err;
        },
    }
}

fn catchMatches(class_name: []const u8, thrown: Value) bool {
    if (std.mem.eql(u8, class_name, "ExceptionInfo")) {
        return thrown.tag() == .ex_info;
    }
    // Phase 3.11 only recognises `ExceptionInfo`; other class symbols
    // were accepted at analyse time so user code stays readable, but
    // they never match a thrown Value until later phases extend the
    // type-name table.
    return false;
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
        else => |t| error_catalog.raise(.value_not_callable, loc, .{ .actual = @tagName(t) }),
    };
}

pub fn callFunction(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) !Value {
    const f = fn_val.decodePtr(*Function);
    if (!f.has_rest) {
        if (args.len != f.arity)
            return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "fn", .got = args.len, .expected = f.arity });
    } else {
        if (args.len < f.arity)
            return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "fn", .got = args.len, .min = f.arity });
    }
    if (@as(usize, f.slot_base) + f.arity + @intFromBool(f.has_rest) > MAX_LOCALS)
        return error_catalog.raise(.fn_frame_exceeds_max_locals, loc, .{ .base = f.slot_base, .arity = f.arity, .max = MAX_LOCALS });
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    // Replay captured outer locals into the fresh frame so LocalRefs
    // resolved against the analyser's enclosing scope still find their
    // values. Top-level fns skip this entirely.
    if (f.closure_bindings) |snap| {
        @memcpy(locals[0..snap.len], snap);
    }
    // Params land at `[slot_base, slot_base + arity)` — the slots the
    // analyser allocated when it descended into the fn body.
    for (args[0..f.arity], 0..) |v, i| {
        locals[f.slot_base + i] = v;
    }
    if (f.has_rest) {
        // Build a list of the trailing args (those past `f.arity`).
        // JVM Clojure binds `& rest` to a seq view; cw v1 builds the
        // simpler heap List (Cons chain). Empty trailing → nil per
        // `(defn f [& xs] xs) → (f)` returning nil (matches v1 list.rest
        // empty-list semantics; full empty-PersistentList singleton
        // lands at Phase 7 entry per ADR-0033 follow-up).
        var rest_list: Value = .nil_val;
        var i: usize = args.len;
        while (i > f.arity) {
            i -= 1;
            rest_list = try list_mod.consHeap(rt, args[i], rest_list);
        }
        locals[f.slot_base + f.arity] = rest_list;
    }
    // VM backend hook: when the Function carries compiled bytecode and
    // the vtable has the `evalChunk` slot wired (vm.installVTable), run
    // the chunk instead of walking the Node body. The TreeWalk backend
    // leaves `evalChunk` null and always reaches the `eval(...)` line.
    if (f.bytecode) |chunk| {
        if (rt.vtable) |vt| {
            if (vt.evalChunk) |ec| return ec(rt, env, &locals, @ptrCast(chunk));
        }
    }
    return eval(rt, env, &locals, f.body);
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
        const form = (try reader.read()) orelse return error.NotImplemented;
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
            else => return error.NotImplemented,
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
    const fn_node = node_mod.FnNode{
        .arity = 0,
        .params = &.{},
        .body = &body,
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
