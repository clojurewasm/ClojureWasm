// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.ArrayDeque` — a mutable double-ended queue.
//!
//! Backend: impl-only
//! Impl deps: vector
//! Clojure peer: none
//!
//! Backed by a cljw VECTOR Value in state[0] (the HashMap pattern), so the
//! descriptor's `host_trace` marks the one Value each GC and no `host_finalise`
//! is needed. The vector's TAIL is the deque's HEAD, keeping `push`/`pop`/`peek`
//! on the O(1) end.
//!
//! Methods: `<init>` (empty / capacity-hint / seed) + push/pop/peek/poll/
//! addFirst/addLast/removeFirst/removeLast/peekFirst/peekLast/size/isEmpty/
//! clear, plus (Seqable -seq) + (IPersistentCollection -count).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const vector_mod = @import("../../collection/vector.zig");
const list_mod = @import("../../collection/list.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

var ad_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn vecOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}

fn setVec(recv: Value, v: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(v));
}

/// `(java.util.ArrayDeque.)` — empty. `(ArrayDeque. n)` capacity hint (ignored).
/// `(ArrayDeque. coll)` seeds from a cljw vector, head-first.
fn initArrayDeque(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.ArrayDeque.", .expected = 1 });
    var initial = vector_mod.empty();
    if (args.len == 1) {
        switch (args[0].tag()) {
            .integer => {}, // capacity hint → empty
            .vector => initial = args[0],
            else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.ArrayDeque.", .expected = "int capacity or vector", .actual = @tagName(args[0].tag()) }),
        }
    }
    const td = ad_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(initial), 0, 0, 0 });
}

/// `(.push d x)` / `(.addFirst d x)` — put `x` at the head; returns nil.
fn push(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".push", args, 2, loc);
    setVec(args[0], try vector_mod.conj(rt, vecOf(args[0]), args[1]));
    return Value.nil_val;
}

/// `(.pop d)` — remove and return the head. Empty raises, JVM-faithful
/// (`NoSuchElementException`).
fn pop(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".pop", args, 1, loc);
    const v = vecOf(args[0]);
    const n = vector_mod.count(v);
    if (n == 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".pop", .expected = "a non-empty deque", .actual = "an empty deque" });
    const head = vector_mod.nth(v, n - 1);
    setVec(args[0], try vector_mod.pop(rt, v));
    return head;
}

/// `(.poll d)` / `(.pollFirst d)` — remove and return the head, or nil if empty.
fn poll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".poll", args, 1, loc);
    const v = vecOf(args[0]);
    const n = vector_mod.count(v);
    if (n == 0) return Value.nil_val;
    const head = vector_mod.nth(v, n - 1);
    setVec(args[0], try vector_mod.pop(rt, v));
    return head;
}

/// `(.peek d)` / `(.peekFirst d)` — the head without removing it, nil if empty.
fn peek(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".peek", args, 1, loc);
    const v = vecOf(args[0]);
    const n = vector_mod.count(v);
    return if (n == 0) Value.nil_val else vector_mod.nth(v, n - 1);
}

/// `(.peekLast d)` — the tail without removing it, nil if empty.
fn peekLast(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".peekLast", args, 1, loc);
    const v = vecOf(args[0]);
    return if (vector_mod.count(v) == 0) Value.nil_val else vector_mod.nth(v, 0);
}

/// `(.size d)` — element count.
fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(vector_mod.count(vecOf(args[0]))));
}

/// `(.isEmpty d)` — whether the deque holds no elements.
fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(vector_mod.count(vecOf(args[0])) == 0);
}

/// `(.clear d)` — drop every element; returns nil.
fn clear(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".clear", args, 1, loc);
    setVec(args[0], vector_mod.empty());
    return Value.nil_val;
}

/// `(seq d)` — head-first seq of the elements, nil when empty.
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    const v = vecOf(args[0]);
    const n = vector_mod.count(v);
    if (n == 0) return Value.nil_val;
    // The vector's tail is the deque's head, so consing front-to-back over the
    // vector in index order yields a head-first list.
    var acc = Value.nil_val;
    var i: u32 = 0;
    while (i < n) : (i += 1) acc = try list_mod.consHeap(rt, vector_mod.nth(v, i), acc);
    return acc;
}

/// `(count d)` — element count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(vector_mod.count(vecOf(args[0]))));
}

fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const v: Value = @enumFromInt(state[0]);
    if (v.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct {
    name: []const u8,
    proto: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .proto = "", .f = &initArrayDeque },
    .{ .name = "push", .proto = "", .f = &push },
    .{ .name = "addFirst", .proto = "", .f = &push },
    .{ .name = "pop", .proto = "", .f = &pop },
    .{ .name = "removeFirst", .proto = "", .f = &pop },
    .{ .name = "poll", .proto = "", .f = &poll },
    .{ .name = "pollFirst", .proto = "", .f = &poll },
    .{ .name = "peek", .proto = "", .f = &peek },
    .{ .name = "peekFirst", .proto = "", .f = &peek },
    .{ .name = "peekLast", .proto = "", .f = &peekLast },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "clear", .proto = "", .f = &clear },
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    ad_descriptor = td;
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
    .cljw_ns = "cljw.java.util.ArrayDeque",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.ArrayDeque",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .host_supertypes = &.{ "java.util.Deque", "java.util.Queue", "java.util.Collection" },
    .parent = null,
    .meta = .nil_val,
};
