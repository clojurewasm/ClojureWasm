// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.TreeSet` — a mutable sorted set (D-431 interop
//! completeness; the sorted sibling of `HashSet`). Appears in ported Clojure code
//! that needs Java's sorted-set ordering; the persistent `(sorted-set …)` is the
//! idiomatic cljw analogue, and backs this surface.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Stored as a `.host_instance` (ADR-0106) whose state[0] holds a cljw PERSISTENT
//! SORTED SET Value (a red-black tree; `runtime/collection/sorted.zig`), so element
//! ordering / de-duplication reuse cljw's comparator semantics and the descriptor's
//! `host_trace` marks the one set Value each GC (no off-heap buffer → no
//! `host_finalise`). A mutating method conj/disj's the set and writes the new root
//! back into state[0]; the mutators need no extra rooting (the receiver set lives in
//! the rooted instance), only `<init>`'s fresh-set build does (an EvalFrame).
//!
//! Unlike `HashSet`, iteration is SORTED, matching clj's `TreeSet` exactly — so the
//! seq order is a real parity property, not an AD-001 divergence. `(seq ts)` /
//! `(count ts)` / `(into [] ts)` work via the Seqable / IPersistentCollection
//! MethodEntries. `.first` / `.last` return the min / max.
//!
//! Methods: `<init>` (empty / vector / cljw-sorted-set / another TreeSet seed) +
//! add / remove / contains / size / isEmpty / clear / addAll / first / last. The
//! wider NavigableSet surface (floor/ceiling/headSet/tailSet/subSet/descendingSet)
//! is a deliberate follow-up (D-431). `<init>` / `.addAll` walk a VECTOR (or share a
//! sorted-set / TreeSet HAMT); a general seqable goes via `(vec coll)` (ArrayList's
//! documented Layer-2 limit).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const sorted = @import("../../collection/sorted.zig");
const list_mod = @import("../../collection/list.zig");
const vector_mod = @import("../../collection/vector.zig");
const root_set = @import("../../gc/root_set.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

var ts_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn setOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}
/// Print hook (D-468): a java.util.TreeSet prints by content like clj (`#{1 2}`,
/// sorted) — its backing native sorted-set IS the printable Value.
fn printContent(rt: *Runtime, recv: Value) anyerror!Value {
    _ = rt;
    return setOf(recv);
}
fn storeSet(recv: Value, s: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(s));
}
fn isTreeSet(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == ts_descriptor;
}

fn allocWith(rt: *Runtime, s: Value) !Value {
    const td = ts_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(s), 0, 0, 0 });
}

/// `(java.util.TreeSet.)` — empty. `(TreeSet. coll)` — seed from a vector (conjSet
/// each element), a cljw sorted-set, or another TreeSet (share the RB-tree — it is
/// immutable, so a later add/remove forks its own version). A general seqable seeds
/// via `(TreeSet. (vec coll))` (Layer-2 seq realization is out of this surface's reach).
pub fn initTreeSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.TreeSet.", .expected = 1 });
    if (args.len == 0) return allocWith(rt, try sorted.emptySet(rt));
    switch (args[0].tag()) {
        .sorted_set => return allocWith(rt, args[0]),
        .host_instance => {
            if (!isTreeSet(args[0]))
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.TreeSet.", .expected = "vector, sorted-set, or TreeSet", .actual = @tagName(args[0].tag()) });
            return allocWith(rt, setOf(args[0]));
        },
        .vector => {
            // GC-ROOT: §C — the fresh set lives only as a Zig local across the conjSet
            // allocs (and the final alloc); publish it on an EvalFrame so a collect
            // mid-build cannot sweep it [ref: .dev/gc_rooting.md §C].
            var roots: [1]Value = .{try sorted.emptySet(rt)};
            var sp: u16 = 1;
            var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
            root_set.eval_frame_head = &frame;
            defer root_set.eval_frame_head = frame.parent;
            const n = vector_mod.count(args[0]);
            var i: u32 = 0;
            while (i < n) : (i += 1) roots[0] = try sorted.conjSet(rt, env, roots[0], vector_mod.nth(args[0], i), loc);
            return allocWith(rt, roots[0]);
        },
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.TreeSet.", .expected = "vector, sorted-set, or TreeSet", .actual = @tagName(args[0].tag()) }),
    }
}

/// `(.add ts x)` — add `x`; returns true iff the set CHANGED (JVM `Set.add`).
fn add(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".add", args, 2, loc);
    const had = try sorted.setContains(rt, env, setOf(args[0]), args[1], loc);
    if (!had) storeSet(args[0], try sorted.conjSet(rt, env, setOf(args[0]), args[1], loc));
    return Value.initBoolean(!had);
}

/// `(.remove ts x)` — remove `x`; returns true iff it was present (JVM `Set.remove`).
fn remove(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".remove", args, 2, loc);
    const had = try sorted.setContains(rt, env, setOf(args[0]), args[1], loc);
    if (had) storeSet(args[0], try sorted.disjSet(rt, env, setOf(args[0]), args[1], loc));
    return Value.initBoolean(had);
}

fn contains(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".contains", args, 2, loc);
    return Value.initBoolean(try sorted.setContains(rt, env, setOf(args[0]), args[1], loc));
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(sorted.count(setOf(args[0]))));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(sorted.count(setOf(args[0])) == 0);
}

/// `(.clear ts)` — drop all elements, return nil.
fn clear(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".clear", args, 1, loc);
    storeSet(args[0], try sorted.emptySet(rt));
    return Value.nil_val;
}

/// `(.addAll ts coll)` — add every element of a VECTOR `coll`, returning true iff
/// the set changed. A non-vector seqable goes via `(.addAll ts (vec coll))`.
fn addAll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".addAll", args, 2, loc);
    if (args[1].tag() != .vector)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".addAll", .expected = "vector (use (vec coll) for other seqables)", .actual = @tagName(args[1].tag()) });
    const before = sorted.count(setOf(args[0]));
    const n = vector_mod.count(args[1]);
    var i: u32 = 0;
    while (i < n) : (i += 1) storeSet(args[0], try sorted.conjSet(rt, env, setOf(args[0]), vector_mod.nth(args[1], i), loc));
    return Value.initBoolean(sorted.count(setOf(args[0])) != before);
}

/// `(.first ts)` — the least element (JVM `TreeSet.first` / `SortedSet.first`).
/// Empty raises (JVM throws NoSuchElementException; cljw's Kind differs, AD-007).
fn first(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".first", args, 1, loc);
    const s = try sorted.seq(rt, setOf(args[0]));
    if (s.isNil()) return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.TreeSet/first" });
    return list_mod.first(s);
}

/// `(.last ts)` — the greatest element. The sorted seq is already realized, so the
/// walk to its tail allocates nothing (no GC fabrication window).
fn last(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".last", args, 1, loc);
    var cur = try sorted.seq(rt, setOf(args[0]));
    if (cur.isNil()) return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.TreeSet/last" });
    while (true) {
        const nxt = list_mod.rest(cur);
        if (nxt.isNil() or list_mod.isEmpty(nxt)) return list_mod.first(cur);
        cur = nxt;
    }
}

/// `(.floor ts e)` — greatest element ≤ e, nil if none (JVM `NavigableSet.floor`).
fn floorFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".floor", args, 2, loc);
    return sorted.navKey(rt, env, setOf(args[0]), args[1], .floor, loc);
}
/// `(.ceiling ts e)` — least element ≥ e, nil if none (JVM `NavigableSet.ceiling`).
fn ceilingFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".ceiling", args, 2, loc);
    return sorted.navKey(rt, env, setOf(args[0]), args[1], .ceiling, loc);
}
/// `(.lower ts e)` — greatest element < e, nil if none (JVM `NavigableSet.lower`).
fn lowerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".lower", args, 2, loc);
    return sorted.navKey(rt, env, setOf(args[0]), args[1], .lower, loc);
}
/// `(.higher ts e)` — least element > e, nil if none (JVM `NavigableSet.higher`).
fn higherFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".higher", args, 2, loc);
    return sorted.navKey(rt, env, setOf(args[0]), args[1], .higher, loc);
}

/// `(Seqable -seq)` — a seq of the elements in SORTED order (clj `TreeSet` parity).
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    return sorted.seq(rt, setOf(args[0]));
}

/// `(IPersistentCollection -count)` — element count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(sorted.count(setOf(args[0]))));
}

/// GC-trace: mark the backing sorted-set Value (held as a raw u64 in state[0]).
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
    .{ .name = "<init>", .proto = "", .f = &initTreeSet },
    .{ .name = "add", .proto = "", .f = &add },
    .{ .name = "remove", .proto = "", .f = &remove },
    .{ .name = "contains", .proto = "", .f = &contains },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "clear", .proto = "", .f = &clear },
    .{ .name = "addAll", .proto = "", .f = &addAll },
    .{ .name = "first", .proto = "", .f = &first },
    .{ .name = "last", .proto = "", .f = &last },
    .{ .name = "floor", .proto = "", .f = &floorFn },
    .{ .name = "ceiling", .proto = "", .f = &ceilingFn },
    .{ .name = "lower", .proto = "", .f = &lowerFn },
    .{ .name = "higher", .proto = "", .f = &higherFn },
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
    // Associative -contains-key? so `(contains? ts k)` works like clj. `(get ts k)`
    // stays nil (clj's get on a java.util.Set returns nil) — no -lookup added.
    .{ .name = "-contains-key?", .proto = "Associative", .f = &contains },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    ts_descriptor = td;
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
    .cljw_ns = "cljw.java.util.TreeSet",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.TreeSet",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    // A java.util.TreeSet is a Set + SortedSet + NavigableSet + Collection +
    // Iterable (Collection extends Iterable). D-466 follow-up.
    .host_supertypes = &.{ "java.util.Set", "java.util.SortedSet", "java.util.NavigableSet", "java.util.Collection", "java.lang.Iterable" },
    .print_content = printContent,
    .parent = null,
    .meta = .nil_val,
};
