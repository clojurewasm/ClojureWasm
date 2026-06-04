// SPDX-License-Identifier: EPL-2.0
//! PersistentQueue — the immutable FIFO queue (ADR-0087), on the reserved
//! F-004 Group-A `.persistent_queue` slot (HeapTag 45). Okasaki batched
//! queue: a `front` cljw list (oldest element first) + a `rear` cljw vector
//! (newest elements, in conj order) + an O(1) `count` + meta. `conj` seeds
//! `front` on the first element then appends to `rear`; `peek`/`pop` work the
//! `front`; when `front` empties, `rear` migrates to `front`. `=`/hash route
//! through the shared Sequential paths (a queue is `=` to any Sequential with
//! equal elements — see `equal.zig`). Reached only via `conj`/`EMPTY` (no
//! reader literal), so dual-backend parity is automatic (ADR-0036).

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const list = @import("list.zig");
const vector = @import("vector.zig");
const type_descriptor = @import("../type_descriptor.zig");

/// A persistent FIFO queue. `front` is a `.list` (non-empty whenever
/// `count > 0`; `nil` only for EMPTY); `rear` is a `.vector` or `nil`.
pub const PersistentQueue = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    count: i64,
    front: Value,
    rear: Value,
    meta: Value,

    comptime {
        std.debug.assert(@alignOf(PersistentQueue) >= 8);
        std.debug.assert(@offsetOf(PersistentQueue, "header") == 0);
    }
};

fn make(rt: *Runtime, count_: i64, front: Value, rear: Value, meta: Value) !Value {
    const q = try rt.gc.alloc(PersistentQueue);
    q.* = .{ .header = HeapHeader.init(.persistent_queue), .count = count_, .front = front, .rear = rear, .meta = meta };
    return Value.encodeHeapPtr(.persistent_queue, q);
}

/// The process-lifetime EMPTY singleton (`clojure.lang.PersistentQueue/EMPTY`),
/// allocated once on `gc.infra` (never GC-swept), mirroring `list.emptyList`.
pub fn emptyQueue(rt: *Runtime) !Value {
    if (!rt.empty_queue.isNil()) return rt.empty_queue;
    const cell = try rt.gc.infra.create(PersistentQueue);
    cell.* = .{ .header = HeapHeader.init(.persistent_queue), .count = 0, .front = .nil_val, .rear = .nil_val, .meta = .nil_val };
    rt.empty_queue = Value.encodeHeapPtr(.persistent_queue, cell);
    return rt.empty_queue;
}

/// Release the EMPTY singleton (allocated on `gc.infra`). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitEmptyQueue(rt: *Runtime) void {
    if (rt.empty_queue.isNil()) return;
    rt.gc.infra.destroy(rt.empty_queue.decodePtr(*PersistentQueue));
    rt.empty_queue = .nil_val;
}

pub fn isQueue(v: Value) bool {
    return v.tag() == .persistent_queue;
}

/// O(1) element count.
pub fn count(v: Value) i64 {
    return v.decodePtr(*const PersistentQueue).count;
}

pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const PersistentQueue).meta;
}

/// The front list (oldest elements; `.list` or nil). For the equality/hash
/// cursor (equal.zig) — walk `front` then `rear`.
pub fn frontOf(v: Value) Value {
    return v.decodePtr(*const PersistentQueue).front;
}

/// The rear vector (newest elements; `.vector` or nil).
pub fn rearOf(v: Value) Value {
    return v.decodePtr(*const PersistentQueue).rear;
}

/// `(conj q x)` — append `x` to the rear (the first element seeds the front).
pub fn conj(rt: *Runtime, q: Value, x: Value) !Value {
    const pq = q.decodePtr(*const PersistentQueue);
    if (pq.count == 0) {
        const f = try list.consHeap(rt, x, try list.emptyList(rt));
        return make(rt, 1, f, .nil_val, pq.meta);
    }
    const new_rear = if (pq.rear.isNil())
        try vector.fromSlice(rt, &.{x})
    else
        try vector.conj(rt, pq.rear, x);
    return make(rt, pq.count + 1, pq.front, new_rear, pq.meta);
}

/// `(peek q)` — the oldest element (front of the queue), or nil when empty.
pub fn peek(q: Value) Value {
    const pq = q.decodePtr(*const PersistentQueue);
    if (pq.count == 0) return .nil_val;
    return list.first(pq.front);
}

/// `(pop q)` — drop the oldest element. Pop of empty returns the empty queue
/// (clj: no throw). When the front list empties, the rear migrates to front.
pub fn pop(rt: *Runtime, q: Value) !Value {
    const pq = q.decodePtr(*const PersistentQueue);
    if (pq.count == 0) return q;
    const f1 = list.rest(pq.front); // a list (possibly empty)
    if (list.isEmpty(f1)) {
        if (pq.rear.isNil())
            return make(rt, 0, try list.emptyList(rt), .nil_val, pq.meta);
        // front exhausted → rear becomes the new front
        return make(rt, pq.count - 1, try listFromVector(rt, pq.rear), .nil_val, pq.meta);
    }
    return make(rt, pq.count - 1, f1, pq.rear, pq.meta);
}

/// `(seq q)` — front ++ rear as a `.list`, or nil when empty.
pub fn seqOf(rt: *Runtime, q: Value) !Value {
    const pq = q.decodePtr(*const PersistentQueue);
    if (pq.count == 0) return .nil_val;
    var acc = try listFromVector(rt, pq.rear); // rear elements as a list tail
    var tmp: std.ArrayList(Value) = .empty;
    defer tmp.deinit(rt.gpa);
    var cur = pq.front;
    while (cur.tag() == .list and list.countOf(cur) > 0) {
        try tmp.append(rt.gpa, list.first(cur));
        cur = list.rest(cur);
    }
    var i = tmp.items.len;
    while (i > 0) {
        i -= 1;
        acc = try list.consHeap(rt, tmp.items[i], acc);
    }
    return acc;
}

/// `(with-meta q m)` — a queue sharing structure, with metadata `m`.
pub fn withMeta(rt: *Runtime, q: Value, m: Value) !Value {
    const pq = q.decodePtr(*const PersistentQueue);
    return make(rt, pq.count, pq.front, pq.rear, m);
}

/// Build a `.list` from a vector's elements in index order (nth 0 first).
fn listFromVector(rt: *Runtime, vec: Value) !Value {
    if (vec.isNil()) return list.emptyList(rt);
    var acc = try list.emptyList(rt);
    var i = vector.count(vec);
    while (i > 0) {
        i -= 1;
        acc = try list.consHeap(rt, vector.nth(vec, i), acc);
    }
    return acc;
}

/// Per-tag trace fn: mark front / rear / meta so they survive GC.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const q: *PersistentQueue = @ptrCast(@alignCast(header));
    if (q.front.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (q.rear.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (q.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register the trace fn at `.persistent_queue`. Called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.persistent_queue, &traceGc);
}

// --- Java-surface descriptor (for `clojure.lang.PersistentQueue/EMPTY`) ---

const pq_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "EMPTY", .value = .{ .singleton = .empty_queue } },
};

/// Module-static descriptor; `registerType` heap-copies it into `rt.types`
/// (so `rt.deinit`'s uniform gpa-free over `types` holds). fqcn matches the
/// `cljw.<head>` form `resolveJavaSurface` derives from `clojure.lang.
/// PersistentQueue`, so `clojure.lang.PersistentQueue/EMPTY` resolves.
const descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.clojure.lang.PersistentQueue",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &pq_static_fields,
    .parent = null,
    .meta = .nil_val,
};

/// Register the PersistentQueue surface descriptor into `rt.types` (heap-copy
/// so deinit's uniform free holds), mirroring `_host_api.installAll`. Called
/// once from `lang/primitive.zig`. Idempotent.
pub fn registerType(rt: *Runtime) !void {
    const gop = try rt.types.getOrPut(descriptor.fqcn.?);
    if (gop.found_existing) return;
    const td = try rt.gpa.create(type_descriptor.TypeDescriptor);
    td.* = descriptor;
    td.fqcn = try rt.gpa.dupe(u8, descriptor.fqcn.?);
    gop.key_ptr.* = try rt.gpa.dupe(u8, descriptor.fqcn.?);
    gop.value_ptr.* = td;
}

// --- tests ---

const testing = std.testing;

test "PersistentQueue conj/peek/pop/seq/count FIFO" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const e = try emptyQueue(&rt);
    try testing.expectEqual(@as(i64, 0), count(e));
    try testing.expect(peek(e).isNil());

    const q3 = try conj(&rt, try conj(&rt, try conj(&rt, e, Value.initInteger(1)), Value.initInteger(2)), Value.initInteger(3));
    try testing.expectEqual(@as(i64, 3), count(q3));
    try testing.expectEqual(@as(i48, 1), peek(q3).asInteger()); // oldest first

    const q2 = try pop(&rt, q3);
    try testing.expectEqual(@as(i64, 2), count(q2));
    try testing.expectEqual(@as(i48, 2), peek(q2).asInteger());

    // seq is FIFO order 1 2 3
    const s = try seqOf(&rt, q3);
    try testing.expectEqual(@as(i48, 1), list.first(s).asInteger());
    try testing.expectEqual(@as(i48, 2), list.first(list.rest(s)).asInteger());
    try testing.expectEqual(@as(i48, 3), list.first(list.rest(list.rest(s))).asInteger());

    // pop to empty
    const q1 = try pop(&rt, q2);
    const q0 = try pop(&rt, q1);
    try testing.expectEqual(@as(i64, 0), count(q0));
    try testing.expect((try seqOf(&rt, q0)).isNil());
    // pop of empty is a no-op
    try testing.expectEqual(@as(i64, 0), count(try pop(&rt, q0)));
}
