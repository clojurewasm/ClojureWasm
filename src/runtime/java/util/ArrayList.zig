// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.ArrayList` — a mutable, growable, indexed list
//! (D-425). The canonical commonly-used Java collection; appears in interop with
//! Java libraries that hand back / take a `List`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Stored as a `.host_instance` (ADR-0106) whose state[0] holds a `gc.infra`
//! pointer to a `std.ArrayList(Value)` — the StringBuilder backing-list pattern,
//! but holding live `Value`s, so the descriptor's `host_trace` marks every
//! element each GC (the Iterator/D-294 pattern; without it the elements would be
//! swept while the list still holds them). `host_finalise` frees the list.
//!
//! Seqability: a `(Seqable -seq)` + `(IPersistentCollection -count)` MethodEntry
//! on the descriptor makes `(seq al)` / `(count al)` / `(into [] al)` / `(vec al)`
//! work through the generic seq/count else-arm dispatch — no shared-code change.
//! Methods: `<init>` (empty / int-capacity-hint) + add / get / set / size /
//! isEmpty / contains. `(ArrayList. coll)` seeding + addAll/remove/indexOf are a
//! follow-up (note in D-425).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const list_mod = @import("../../collection/list.zig");
const vector_mod = @import("../../collection/vector.zig");
const equal = @import("../../equal.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");
const HeapHeader = @import("../../value/value.zig").HeapHeader;

const ValueList = std.ArrayList(Value);

var al_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn listOf(recv: Value) *ValueList {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// `(java.util.ArrayList.)` — empty. `(ArrayList. n)` — an int initial-capacity
/// hint (ignored; the buffer grows on demand). `(ArrayList. vec)` — seed from a
/// vector (the common literal form). Seeding from a general seqable (list / seq)
/// is a follow-up: the seq-realization machinery is Layer 2, not reachable from
/// this Layer-0 surface — use `(ArrayList. (vec coll))`.
fn initArrayList(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.ArrayList.", .expected = 1 });
    const lp = try rt.gc.infra.create(ValueList);
    lp.* = .empty;
    errdefer {
        lp.deinit(rt.gc.infra);
        rt.gc.infra.destroy(lp);
    }
    if (args.len == 1) {
        switch (args[0].tag()) {
            .integer => {}, // capacity hint
            .vector => {
                const n = vector_mod.count(args[0]);
                var i: u32 = 0;
                while (i < n) : (i += 1) try lp.append(rt.gc.infra, vector_mod.nth(args[0], i));
            },
            else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.ArrayList.", .expected = "int capacity or vector", .actual = @tagName(args[0].tag()) }),
        }
    }
    const td = al_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromPtr(lp), 0, 0, 0 });
}

/// `(.add al x)` — append `x`; returns true (JVM `List.add` returns boolean).
fn add(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".add", args, 2, loc);
    try listOf(args[0]).append(rt.gc.infra, args[1]);
    return Value.initBoolean(true);
}

/// `(.get al i)` — element at index `i`. Out-of-range raises (JVM throws
/// IndexOutOfBoundsException; cljw's Kind differs per AD-007).
fn get(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".get", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = ".get", .actual = @tagName(args[1].tag()) });
    const lp = listOf(args[0]);
    const i = args[1].asInteger();
    if (i < 0 or i >= lp.items.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.ArrayList/get" });
    return lp.items[@intCast(i)];
}

/// `(.set al i x)` — replace the element at `i`, returning the OLD value (JVM).
fn set(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".set", args, 3, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = ".set", .actual = @tagName(args[1].tag()) });
    const lp = listOf(args[0]);
    const i = args[1].asInteger();
    if (i < 0 or i >= lp.items.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.ArrayList/set" });
    const old = lp.items[@intCast(i)];
    lp.items[@intCast(i)] = args[2];
    return old;
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(listOf(args[0]).items.len));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(listOf(args[0]).items.len == 0);
}

fn contains(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".contains", args, 2, loc);
    for (listOf(args[0]).items) |e| {
        if (try equal.valueEqual(rt, env, e, args[1])) return Value.initBoolean(true);
    }
    return Value.initBoolean(false);
}

/// `(Seqable -seq)` — a cljw list of the elements (eager), so `(seq al)` /
/// `(into [] al)` / `(vec al)` work. Empty → nil (clj's `(seq empty)`).
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    const lp = listOf(args[0]);
    if (lp.items.len == 0) return Value.nil_val;
    var acc: Value = .nil_val;
    var i: usize = lp.items.len;
    while (i > 0) {
        i -= 1;
        acc = try list_mod.consHeap(rt, lp.items[i], acc);
    }
    return acc;
}

/// `(IPersistentCollection -count)` — O(1) element count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(listOf(args[0]).items.len));
}

/// GC-trace: mark every element Value in the backing list (the elements live in
/// a `gc.infra` buffer the field-walker can't see).
/// GC-ROOT: §H — a moving GC must RELOCATE each slot here, not just mark
/// [ref: .dev/gc_rooting.md §H].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const lp: *ValueList = @ptrFromInt(state[0]);
    for (lp.items) |e| {
        if (e.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const lp: *ValueList = @ptrFromInt(state[0]);
    lp.deinit(infra);
    infra.destroy(lp);
}

const MethodSpec = struct {
    name: []const u8,
    proto: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .proto = "", .f = &initArrayList },
    .{ .name = "add", .proto = "", .f = &add },
    .{ .name = "get", .proto = "", .f = &get },
    .{ .name = "set", .proto = "", .f = &set },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "contains", .proto = "", .f = &contains },
    // Seqable / IPersistentCollection so seq / count / into route here.
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    al_descriptor = td;
    td.host_trace = &traceState;
    td.host_finalise = &finaliseState;
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
    .cljw_ns = "cljw.java.util.ArrayList",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.ArrayList",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
