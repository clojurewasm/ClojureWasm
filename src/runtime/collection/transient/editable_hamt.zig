// SPDX-License-Identifier: EPL-2.0
//! Editable HAMT nodes for transient maps. A node with another owner is cloned
//! before mutation; persistent source maps therefore remain immutable.
const Runtime = @import("../../runtime.zig").Runtime;
const Value = @import("../../value/value.zig").Value;
const HeapHeader = @import("../../value/value.zig").HeapHeader;
const map = @import("../map.zig");
const equal = @import("../../equal.zig");
const Node = map.HamtMapNode;

fn bit(hash: u32, shift: u32) u32 {
    return @as(u32, 1) << @as(u5, @intCast((hash >> @intCast(shift)) & 31));
}
fn index(bitmap: u32, b: u32) u32 {
    return @popCount(bitmap & (b - 1));
}
fn nodeValue(node: *Node) Value {
    return Value.encodeHeapPtrRuntime(@enumFromInt(node.header.tag), node);
}
fn pair(rt: *Runtime, k1: Value, v1: Value, h1: u32, k2: Value, v2: Value, h2: u32, shift: u32, owner: usize) anyerror!*Node {
    if (shift > 30) {
        const bucket = try rt.gc.alloc(Node);
        bucket.* = .{ .header = HeapHeader.init(.hash_collision_map_node), .data_map = 3, .edit_owner = owner };
        bucket.slots[0] = k1;
        bucket.slots[1] = v1;
        bucket.slots[2] = k2;
        bucket.slots[3] = v2;
        return bucket;
    }
    const b1 = bit(h1, shift);
    const b2 = bit(h2, shift);
    const node = try rt.gc.alloc(Node);
    node.* = .{ .header = HeapHeader.init(.hamt_map_node), .edit_owner = owner };
    if (b1 == b2) {
        node.node_map = b1;
        node.slots[63] = nodeValue(try pair(rt, k1, v1, h1, k2, v2, h2, shift + 5, owner));
    } else {
        node.data_map = b1 | b2;
        const i = index(node.data_map, b1);
        const j = index(node.data_map, b2);
        node.slots[2 * i] = k1;
        node.slots[2 * i + 1] = v1;
        node.slots[2 * j] = k2;
        node.slots[2 * j + 1] = v2;
    }
    return node;
}
fn editable(rt: *Runtime, node: *Node, owner: usize) !*Node {
    if (node.edit_owner == owner) return node;
    const copy = try rt.gc.alloc(Node);
    copy.* = node.*;
    // A fresh header, as `map.copyHamtNode` does: never inherit the source
    // cell's GC mark, frozen flag or lock bits.
    copy.header = HeapHeader.init(@enumFromInt(node.header.tag));
    copy.edit_owner = owner;
    return copy;
}

const Result = struct { node: *Node, added: bool };
fn bucketPut(rt: *Runtime, source: *Node, k: Value, v: Value, owner: usize) anyerror!Result {
    const n: u32 = @popCount(source.data_map);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try equal.eqConsult(source.slots[2 * i], k)) {
            const node = try editable(rt, source, owner);
            node.slots[2 * i + 1] = v;
            return .{ .node = node, .added = false };
        }
    }
    if (source.node_map != 0) {
        const res = try bucketPut(rt, source.slots[63].decodePtr(*Node), k, v, owner);
        const node = try editable(rt, source, owner);
        node.slots[63] = nodeValue(res.node);
        return .{ .node = node, .added = res.added };
    }
    const node = try editable(rt, source, owner);
    if (n < 31) {
        node.slots[2 * n] = k;
        node.slots[2 * n + 1] = v;
        node.data_map = (node.data_map << 1) | 1;
    } else {
        const child = try rt.gc.alloc(Node);
        child.* = .{ .header = HeapHeader.init(.hash_collision_map_node), .data_map = 1, .edit_owner = owner };
        child.slots[0] = k;
        child.slots[1] = v;
        node.node_map = 1;
        node.slots[63] = nodeValue(child);
    }
    return .{ .node = node, .added = true };
}

// Collision buckets are rare and use the persistent insertion path below;
// ordinary branches only allocate when the node belongs to a different owner.
fn put(rt: *Runtime, source: *Node, k: Value, v: Value, h: u32, shift: u32, owner: usize) !Result {
    const b = bit(h, shift);
    if (source.data_map & b != 0) {
        const di = index(source.data_map, b);
        const old_key = source.slots[2 * di];
        if (try equal.eqConsult(old_key, k)) {
            const node = try editable(rt, source, owner);
            node.slots[2 * di + 1] = v;
            return .{ .node = node, .added = false };
        }
        const sub = try pair(rt, old_key, source.slots[2 * di + 1], try equal.hashConsult(old_key), k, v, h, shift + 5, owner);
        const node = try editable(rt, source, owner);
        const n: u32 = @popCount(node.data_map);
        var i = di;
        while (i + 1 < n) : (i += 1) {
            node.slots[2 * i] = node.slots[2 * (i + 1)];
            node.slots[2 * i + 1] = node.slots[2 * (i + 1) + 1];
        }
        node.slots[2 * (n - 1)] = Value.nil_val;
        node.slots[2 * (n - 1) + 1] = Value.nil_val;
        node.data_map &= ~b;
        const ni = index(node.node_map, b);
        var j: u32 = @popCount(node.node_map);
        while (j > ni) : (j -= 1) node.slots[63 - j] = node.slots[63 - (j - 1)];
        node.slots[63 - ni] = nodeValue(sub);
        node.node_map |= b;
        return .{ .node = node, .added = true };
    }
    if (source.node_map & b != 0) {
        const ni = index(source.node_map, b);
        const child_val = source.slots[63 - ni];
        if (child_val.tag() == .hash_collision_map_node) {
            const res = try bucketPut(rt, child_val.decodePtr(*Node), k, v, owner);
            const node = try editable(rt, source, owner);
            node.slots[63 - ni] = nodeValue(res.node);
            return .{ .node = node, .added = res.added };
        }
        const res = try put(rt, child_val.decodePtr(*Node), k, v, h, shift + 5, owner);
        const node = try editable(rt, source, owner);
        node.slots[63 - ni] = nodeValue(res.node);
        return .{ .node = node, .added = res.added };
    }
    const node = try editable(rt, source, owner);
    const di = index(node.data_map, b);
    var i: u32 = @popCount(node.data_map);
    while (i > di) : (i -= 1) {
        node.slots[2 * i] = node.slots[2 * (i - 1)];
        node.slots[2 * i + 1] = node.slots[2 * (i - 1) + 1];
    }
    node.slots[2 * di] = k;
    node.slots[2 * di + 1] = v;
    node.data_map |= b;
    return .{ .node = node, .added = true };
}

// Retire editable ownership before publishing a persistent map. Without this,
// a later transient allocated at the same address could edit the old map.
fn freezeNode(node: *Node, owner: usize) void {
    if (node.edit_owner != owner) return;
    node.edit_owner = 0;
    var i: u32 = 0;
    while (i < @popCount(node.node_map)) : (i += 1)
        freezeNode(node.slots[63 - i].decodePtr(*Node), owner);
}

pub fn freeze(overflow: Value, owner: usize) void {
    const wrapper = overflow.decodePtr(*map.PersistentHashMap);
    if (wrapper.root) |root| freezeNode(root, owner);
}

/// Mutate a transient's overflow map without minting a new persistent wrapper
/// and copying every HAMT ancestor for each assoc!. owner is its transient cell.
pub fn assoc(rt: *Runtime, overflow: Value, k: Value, v: Value, owner: usize) !void {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const wrapper = overflow.decodePtr(*map.PersistentHashMap);
    const result = try put(rt, wrapper.root.?, k, v, try equal.hashConsult(k), 0, owner);
    wrapper.root = result.node;
    if (result.added) wrapper.count += 1;
}
