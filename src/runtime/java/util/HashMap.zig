// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.HashMap` — a mutable key→value map (D-425). The
//! other canonical commonly-used Java collection.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! DESIGN: rather than a `std.HashMap(Value, Value)` (which would need custom
//! cljw key-equality + hashing), the backing store is a cljw MAP **Value** held
//! in state[0] of a `.host_instance` (ADR-0106). `.put`/`.remove` assoc/dissoc
//! and write the new map back to state[0] (mutable-by-rebind over a persistent
//! map); `.get`/`.containsKey`/`.size` read it. This reuses cljw's hashing +
//! value-equality for free. The descriptor's `host_trace` marks the ONE map
//! Value each GC; no `host_finalise` (the map is a GC Value, not a raw pointer).
//! Seqability: a (Seqable -seq)+(IPersistentCollection -count) MethodEntry routes
//! `(seq hm)` (entries) / `(count hm)` / `(into {} hm)` through the generic
//! else-arm dispatch. Methods: <init> (empty) + put/get/containsKey/size/
//! isEmpty/remove. `(HashMap. map)` seeding + putAll/keySet/values are follow-up.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const map = @import("../../collection/map.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

fn mapOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}

fn setMap(recv: Value, m: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(m));
}

var hm_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// `(java.util.HashMap.)` — empty. `(HashMap. n)` int initial-capacity hint
/// (ignored → empty). `(HashMap. m)` seeds from a cljw map (persistent, so the
/// shared Value is safe — `.put` rebinds a new map, never mutating the source).
fn initHashMap(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.HashMap.", .expected = 1 });
    var initial = map.empty();
    if (args.len == 1) {
        switch (args[0].tag()) {
            .integer => {}, // capacity hint → empty
            // Seed from a cljw unsorted map (the `{…}` forms `.put`'s assoc
            // handles). A sorted_map would need a rebuild — left as a follow-up.
            .array_map, .hash_map => initial = args[0],
            else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.HashMap.", .expected = "int capacity or map", .actual = @tagName(args[0].tag()) }),
        }
    }
    const td = hm_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(initial), 0, 0, 0 });
}

/// `(.put hm k v)` — associate `k`→`v`, returning the PREVIOUS value for `k`
/// (nil if absent), JVM-faithful. No allocation between assoc and the state
/// write-back, so the new map is rooted immediately.
fn put(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".put", args, 3, loc);
    const m = mapOf(args[0]);
    const old: Value = if (try map.contains(m, args[1])) try map.get(m, args[1]) else .nil_val;
    const new = try map.assoc(rt, m, args[1], args[2]);
    setMap(args[0], new);
    return old;
}

/// `(.get hm k)` — the value for `k`, or nil (JVM null) if absent.
fn get(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".get", args, 2, loc);
    return map.get(mapOf(args[0]), args[1]);
}

fn containsKey(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".containsKey", args, 2, loc);
    return Value.initBoolean(try map.contains(mapOf(args[0]), args[1]));
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(map.count(mapOf(args[0]))));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(map.count(mapOf(args[0])) == 0);
}

/// `(.remove hm k)` — drop `k`, returning its previous value (nil if absent).
fn remove(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".remove", args, 2, loc);
    const m = mapOf(args[0]);
    const old: Value = if (try map.contains(m, args[1])) try map.get(m, args[1]) else .nil_val;
    const new = try map.dissoc(rt, m, args[1]);
    setMap(args[0], new);
    return old;
}

/// `(Seqable -seq)` — the entry seq of the backing map (empty → nil).
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    const m = mapOf(args[0]);
    if (map.count(m) == 0) return Value.nil_val;
    return map.seq(rt, m);
}

/// `(IPersistentCollection -count)` — entry count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(map.count(mapOf(args[0]))));
}

/// GC-trace: mark the single backing map Value held in state[0].
/// GC-ROOT: §H — a moving GC must RELOCATE state[0] [ref: .dev/gc_rooting.md §H].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const m: Value = @enumFromInt(state[0]);
    if (m.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct {
    name: []const u8,
    proto: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .proto = "", .f = &initHashMap },
    .{ .name = "put", .proto = "", .f = &put },
    .{ .name = "get", .proto = "", .f = &get },
    .{ .name = "containsKey", .proto = "", .f = &containsKey },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "remove", .proto = "", .f = &remove },
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    hm_descriptor = td;
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
    .cljw_ns = "cljw.java.util.HashMap",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.HashMap",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
