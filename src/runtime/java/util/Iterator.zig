// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Iterator` — a stateful cursor over a cljw seq
//! (ADR-0106 host_instance container). cljw collections are `Iterable` via
//! `(.iterator coll)` (wired in object_method.zig's universal fallback), which
//! mints one of these; `(.hasNext it)` / `(.next it)` then walk it. Landed to
//! unblock hiccup, whose `iterate!` drives output with the Java iterator API.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none.
//!
//! state[0] holds the current cursor seq as a `Value` (an `enum(u64)`), so the
//! descriptor registers a `host_trace` hook to mark it across a collect (the
//! first host type to store a live Value in `state`, per host_instance.zig's
//! D-294 note). `.next` advances the cursor in place. The receiver is coerced to
//! a concrete seq once via `clojure.core/seq`; thereafter the Seqable boundary's
//! `first` / `next` (`runtime/seqable.zig`) walk it.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const seqable = @import("../../seqable.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");
const root_set = @import("../../gc/root_set.zig");

var iter_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn cursorOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// Allocate an Iterator over `coll`, coercing it to a concrete seq first. Called
/// from object_method's `.iterator` fallback (the only producer — there is no
/// `(java.util.Iterator.)` ctor).
pub fn fromSeqable(rt: *Runtime, env: *Env, coll: Value, loc: SourceLocation) anyerror!Value {
    const core = env.findNs("clojure.core") orelse return error.NoVTable;
    const seq_var = core.resolve("seq") orelse return error.NoVTable;
    const vt = rt.vtable orelse return error.NoVTable;
    var roots = [_]Value{try vt.callFn(rt, env, seq_var.deref(), &.{coll}, loc)};
    var sp: u16 = 1;
    // GC-ROOT: A10 — the fresh cursor is not in the host trace until the
    // Iterator allocation completes [ref: .dev/gc_rooting.md §A].
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const td = iter_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(roots[0]), 0, 0, 0 });
}

/// `(.hasNext it)` — true while the cursor has not collapsed to nil.
fn hasNext(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("hasNext", args, 1, loc);
    return Value.initBoolean(cursorOf(args[0]).tag() != .nil);
}

/// `(.next it)` — return the head and advance the cursor in place.
fn next(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("next", args, 1, loc);
    const cursor = cursorOf(args[0]);
    if (cursor.tag() == .nil)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.Iterator/next" });
    var roots = [_]Value{try seqable.first(rt, env, cursor, loc)};
    var sp: u16 = 1;
    // GC-ROOT: A10 — a custom ISeq.first can allocate a head that its cursor
    // does not retain; next can collect it [ref: .dev/gc_rooting.md §A].
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const advanced = try seqable.next(rt, env, cursor, loc);
    host_instance.setState(args[0], 0, @intFromEnum(advanced));
    return roots[0];
}

/// GC-trace the cursor seq held in state[0]. Decode goes through `heapHeader`
/// (the G1 Value→header membrane), so an immediate cursor (nil / a realized
/// small seq) is correctly skipped and only a heap seq is marked.
/// GC-ROOT: §H — the cursor Value lives in a raw `u64` slot the field-walker
/// can't see; a future moving GC must RELOCATE here, not just mark [ref:
/// .dev/gc_rooting.md §H, debt D-318].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const cursor: Value = @enumFromInt(state[0]);
    if (cursor.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "hasNext", .f = &hasNext },
    .{ .name = "next", .f = &next },
};

fn initIterDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    iter_descriptor = td;
    td.host_trace = &traceState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.Iterator",
    .descriptor = &descriptor,
    .init = &initIterDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.Iterator",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
