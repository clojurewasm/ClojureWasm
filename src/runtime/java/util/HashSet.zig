// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.HashSet` — a mutable set of distinct elements
//! (D-431 interop completeness). Appears in ported Clojure code that reaches for
//! a mutable Java Set; the persistent `#{}` is the idiomatic cljw analogue.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Stored as a `.host_instance` (ADR-0106) whose state[0] holds a cljw PERSISTENT
//! SET Value (the HAMT), so element equality / de-duplication reuse cljw's value
//! semantics for free and the descriptor's `host_trace` marks the one set Value
//! each GC (no off-heap buffer, so no `host_finalise`). A mutating method conj/
//! disj's the set and writes the new HAMT root back into state[0] — since the
//! receiver set always lives in the (rooted) instance, the mutators need no extra
//! rooting; only `<init>`'s fresh-set build does (an EvalFrame).
//!
//! Seqability: a `(Seqable -seq)` + `(IPersistentCollection -count)` MethodEntry
//! makes `(seq hs)` / `(count hs)` / `(into [] hs)` / `(set hs)` work through the
//! generic seq/count dispatch. Iteration ORDER is cljw's HAMT order, NOT clj's
//! HashSet hash order — an accepted, unobservable-by-set-semantics divergence
//! (AD-001 class: set order is not part of set identity).
//!
//! Methods: `<init>` (empty / vector / cljw-set / another HashSet seed) + add /
//! remove / contains / size / isEmpty / clear / addAll. `add`/`remove` return the
//! JVM "changed?" boolean. Like `ArrayList`, `<init>` and `.addAll` walk a VECTOR
//! (or, for `<init>`, share a set/HashSet HAMT); a general seqable goes via
//! `(HashSet. (vec coll))` / `(.addAll hs (vec coll))` (seq realization is Layer 2,
//! out of reach of this Layer-0 surface).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const set_mod = @import("../../collection/set.zig");
const vector_mod = @import("../../collection/vector.zig");
const root_set = @import("../../gc/root_set.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

var hs_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn setOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}
fn storeSet(recv: Value, s: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(s));
}
fn isHashSet(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == hs_descriptor;
}

fn allocWith(rt: *Runtime, s: Value) !Value {
    const td = hs_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(s), 0, 0, 0 });
}

/// `(java.util.HashSet.)` — empty. `(HashSet. coll)` — seed from a vector (conj
/// each element), a cljw set, or another HashSet (share the HAMT — immutable, so
/// later add/remove fork their own version). A general seqable seeds via
/// `(HashSet. (vec coll))` (Layer-2 seq realization is out of this surface's reach).
pub fn initHashSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.HashSet.", .expected = 1 });
    if (args.len == 0) return allocWith(rt, set_mod.empty());
    switch (args[0].tag()) {
        // Share the source HAMT — the instance's set is immutable, so a later
        // add/remove forks a new version without mutating the shared source.
        .hash_set => return allocWith(rt, args[0]),
        .host_instance => {
            if (!isHashSet(args[0]))
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.HashSet.", .expected = "vector, set, or HashSet", .actual = @tagName(args[0].tag()) });
            return allocWith(rt, setOf(args[0]));
        },
        .vector => {
            // GC-ROOT: §C — the fresh set lives only as a Zig local across the conj
            // allocs (and the final alloc); publish it on an EvalFrame so a collect
            // mid-build cannot sweep it [ref: .dev/gc_rooting.md §C].
            var roots: [1]Value = .{set_mod.empty()};
            var sp: u16 = 1;
            var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
            root_set.eval_frame_head = &frame;
            defer root_set.eval_frame_head = frame.parent;
            const n = vector_mod.count(args[0]);
            var i: u32 = 0;
            while (i < n) : (i += 1) roots[0] = try set_mod.conj(rt, roots[0], vector_mod.nth(args[0], i));
            return allocWith(rt, roots[0]);
        },
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.HashSet.", .expected = "vector, set, or HashSet", .actual = @tagName(args[0].tag()) }),
    }
}

/// `(.add hs x)` — add `x`; returns true iff the set CHANGED (JVM `Set.add`).
fn add(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".add", args, 2, loc);
    const had = try set_mod.contains(setOf(args[0]), args[1]);
    if (!had) storeSet(args[0], try set_mod.conj(rt, setOf(args[0]), args[1]));
    return Value.initBoolean(!had);
}

/// `(.remove hs x)` — remove `x`; returns true iff it was present (JVM `Set.remove`).
fn remove(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".remove", args, 2, loc);
    const had = try set_mod.contains(setOf(args[0]), args[1]);
    if (had) storeSet(args[0], try set_mod.disj(rt, setOf(args[0]), args[1]));
    return Value.initBoolean(had);
}

fn contains(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".contains", args, 2, loc);
    return Value.initBoolean(try set_mod.contains(setOf(args[0]), args[1]));
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(set_mod.count(setOf(args[0]))));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(set_mod.count(setOf(args[0])) == 0);
}

/// `(.clear hs)` — drop all elements, return nil.
fn clear(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".clear", args, 1, loc);
    storeSet(args[0], set_mod.empty());
    return Value.nil_val;
}

/// `(.addAll hs coll)` — add every element of a VECTOR `coll`, returning true iff
/// the set changed (JVM `Collection.addAll`). `setOf(hs)` lives in the rooted
/// instance, so threading the conj allocs through state[0] needs no extra rooting.
/// A non-vector seqable goes via `(.addAll hs (vec coll))` (mirrors ArrayList).
fn addAll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".addAll", args, 2, loc);
    if (args[1].tag() != .vector)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".addAll", .expected = "vector (use (vec coll) for other seqables)", .actual = @tagName(args[1].tag()) });
    const before = set_mod.count(setOf(args[0]));
    const n = vector_mod.count(args[1]);
    var i: u32 = 0;
    while (i < n) : (i += 1) storeSet(args[0], try set_mod.conj(rt, setOf(args[0]), vector_mod.nth(args[1], i)));
    return Value.initBoolean(set_mod.count(setOf(args[0])) != before);
}

/// `(Seqable -seq)` — a seq of the elements (cljw HAMT order), so `(seq hs)` /
/// `(into [] hs)` / `(set hs)` work. Empty → nil (clj's `(seq empty)`).
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    return set_mod.seq(rt, setOf(args[0]));
}

/// `(IPersistentCollection -count)` — element count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(set_mod.count(setOf(args[0]))));
}

/// GC-trace: mark the backing set Value (held as a raw u64 in state[0], invisible
/// to the field-walker).
/// GC-ROOT: §H — a moving GC must RELOCATE state[0], not just mark
/// [ref: .dev/gc_rooting.md §H].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const s: Value = @enumFromInt(state[0]);
    if (s.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct {
    name: []const u8,
    proto: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .proto = "", .f = &initHashSet },
    .{ .name = "add", .proto = "", .f = &add },
    .{ .name = "remove", .proto = "", .f = &remove },
    .{ .name = "contains", .proto = "", .f = &contains },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "clear", .proto = "", .f = &clear },
    .{ .name = "addAll", .proto = "", .f = &addAll },
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    hs_descriptor = td;
    td.host_trace = &traceState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = m.proto,
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.HashSet",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.HashSet",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
