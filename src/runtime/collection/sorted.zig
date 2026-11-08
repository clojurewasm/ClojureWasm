// SPDX-License-Identifier: EPL-2.0
//! Sorted collections — persistent left-leaning red-black (LLRB) tree
//! (ADR-0057). `SortedMap` is the tree; `SortedSet` wraps a SortedMap
//! (element → element). Keys order by `compare.valueCompare` (default)
//! or a custom comparator (the `-by` ctors — cycle B). assoc/insert is
//! O(log n) path-copy with structural sharing (the persistent contract
//! the HAMT / vector trie honour); the chosen LLRB shape was taken over
//! a flat sorted array per ADR-0057's Devil's-advocate fork (F-002).
//!
//! Supports build (assoc/conj) + get / contains? / count / seq / keys /
//! vals + sorted-map/sorted-set + sorted?; functional LLRB delete
//! (dissoc / disj — Sedgewick moveRedLeft / moveRedRight / deleteMin);
//! custom `-by` comparators — a Clojure fn invoked per comparison via
//! `rt.vtable.callFn` (env threaded through every comparing op), Boolean
//! result = less-than predicate, numeric result = sign (mirrors Clojure
//! `AFunction.compare`); and subseq / rsubseq / rseq.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const root_set = @import("../gc/root_set.zig");
const compare_mod = @import("../compare.zig");
const equal = @import("../equal.zig");
const hash_mod = @import("../hash.zig");
const list_mod = @import("list.zig");
const map_mod = @import("map.zig");
const map_entry_mod = @import("map_entry.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;

const RED: u8 = 1;
const BLACK: u8 = 0;

/// LLRB interior node. `left`/`right` are `rb_node` Values or nil.
pub const RbNode = extern struct {
    header: HeapHeader,
    color: u8 = RED,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    key: Value,
    val: Value,
    left: Value = Value.nil_val,
    right: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(RbNode) >= 8);
        std.debug.assert(@offsetOf(RbNode, "header") == 0);
    }
};

/// Sorted map: tree root + count + (optional custom) comparator + meta.
pub const SortedMap = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    comparator: Value = Value.nil_val, // nil = default valueCompare; custom = cycle B
    root: Value = Value.nil_val, // rb_node or nil
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(SortedMap) >= 8);
        std.debug.assert(@offsetOf(SortedMap, "header") == 0);
    }
};

/// Sorted set: wraps a SortedMap (element → element), mirroring
/// PersistentHashSet → map.
pub const SortedSet = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    map: Value = Value.nil_val, // a `.sorted_map`
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(SortedSet) >= 8);
        std.debug.assert(@offsetOf(SortedSet, "header") == 0);
    }
};

inline fn isRed(v: Value) bool {
    return v.tag() == .rb_node and v.decodePtr(*const RbNode).color == RED;
}

fn newNode(rt: *Runtime, key: Value, val: Value, left: Value, right: Value, color: u8) !Value {
    const n = try rt.gc.alloc(RbNode);
    n.* = .{ .header = HeapHeader.init(.rb_node), .color = color, .key = key, .val = val, .left = left, .right = right };
    return Value.encodeHeapPtr(.rb_node, n);
}

/// Three-way key order. Default (nil comparator) = valueCompare; a custom
/// comparator (sorted-map-by) is a user fn invoked via `rt.vtable.callFn`.
/// Mirrors Clojure's `AFunction.compare`: a Boolean result is read as a
/// less-than predicate (`(c a b)` true → lt; else `(c b a)` true → gt;
/// else eq); a numeric result is read by its sign.
fn compareKeys(rt: *Runtime, env: *Env, comparator: Value, a: Value, b: Value, loc: SourceLocation) !std.math.Order {
    if (comparator.isNil()) return compare_mod.valueCompare(rt, a, b, loc);
    const vt = rt.vtable orelse return error.NoVTable;
    const r = try vt.callFn(rt, env, comparator, &.{ a, b }, loc);
    if (r == Value.true_val or r == Value.false_val) {
        if (r.isTruthy()) return .lt;
        const back = try vt.callFn(rt, env, comparator, &.{ b, a }, loc);
        return if (back.isTruthy()) .gt else .eq;
    }
    return compare_mod.valueCompare(rt, r, Value.initInteger(0), loc);
}

// --- functional LLRB rotations (all allocate fresh nodes — persistent) ---

fn rotateLeft(rt: *Runtime, h: Value) !Value {
    const hn = h.decodePtr(*const RbNode);
    const x = hn.right.decodePtr(*const RbNode);
    const new_h = try newNode(rt, hn.key, hn.val, hn.left, x.left, RED);
    return newNode(rt, x.key, x.val, new_h, x.right, hn.color);
}

fn rotateRight(rt: *Runtime, h: Value) !Value {
    const hn = h.decodePtr(*const RbNode);
    const x = hn.left.decodePtr(*const RbNode);
    const new_h = try newNode(rt, hn.key, hn.val, x.right, hn.right, RED);
    return newNode(rt, x.key, x.val, x.left, new_h, hn.color);
}

fn recolorFlip(rt: *Runtime, v: Value) !Value {
    const n = v.decodePtr(*const RbNode);
    return newNode(rt, n.key, n.val, n.left, n.right, if (n.color == RED) BLACK else RED);
}

fn flipColors(rt: *Runtime, h: Value) !Value {
    const hn = h.decodePtr(*const RbNode);
    const nl = try recolorFlip(rt, hn.left);
    const nr = try recolorFlip(rt, hn.right);
    return newNode(rt, hn.key, hn.val, nl, nr, if (hn.color == RED) BLACK else RED);
}

fn balance(rt: *Runtime, h: Value) !Value {
    var n = h;
    const hn = n.decodePtr(*const RbNode);
    if (isRed(hn.right) and !isRed(hn.left)) n = try rotateLeft(rt, n);
    const n2 = n.decodePtr(*const RbNode);
    if (isRed(n2.left) and isRed(n2.left.decodePtr(*const RbNode).left)) n = try rotateRight(rt, n);
    const n3 = n.decodePtr(*const RbNode);
    if (isRed(n3.left) and isRed(n3.right)) n = try flipColors(rt, n);
    return n;
}

const InsResult = struct { node: Value, added: bool };

fn insert(rt: *Runtime, env: *Env, comparator: Value, h: Value, key: Value, val: Value, loc: SourceLocation) !InsResult {
    if (h.tag() != .rb_node) {
        return .{ .node = try newNode(rt, key, val, Value.nil_val, Value.nil_val, RED), .added = true };
    }
    const hn = h.decodePtr(*const RbNode);
    // Descend first: every comparison (a custom comparator is user code) runs
    // before this level allocates, so nothing fresh is live across user code.
    const order = try compareKeys(rt, env, comparator, key, hn.key, loc);
    const sub: ?InsResult = switch (order) {
        .lt => try insert(rt, env, comparator, hn.left, key, val, loc),
        .gt => try insert(rt, env, comparator, hn.right, key, val, loc),
        .eq => null,
    };
    // ADR-0150: the rebuilt node and the balance rotations are pure-Zig
    // multi-alloc work holding `sub.node` and each fresh node in locals.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const built = switch (order) {
        .lt => try newNode(rt, hn.key, hn.val, sub.?.node, hn.right, hn.color),
        .gt => try newNode(rt, hn.key, hn.val, hn.left, sub.?.node, hn.color),
        .eq => try newNode(rt, hn.key, val, hn.left, hn.right, hn.color),
    };
    return .{ .node = try balance(rt, built), .added = if (sub) |s| s.added else false };
}

fn makeBlack(rt: *Runtime, root: Value) !Value {
    if (root.tag() != .rb_node) return root;
    const rn = root.decodePtr(*const RbNode);
    if (rn.color == BLACK) return root;
    return newNode(rt, rn.key, rn.val, rn.left, rn.right, BLACK);
}

// --- functional LLRB delete (Sedgewick deleteMin/moveRedLeft/moveRedRight) ---

inline fn leftOf(v: Value) Value {
    return if (v.tag() == .rb_node) v.decodePtr(*const RbNode).left else Value.nil_val;
}

/// Leftmost node of a non-empty subtree (the minimum key).
fn minNode(h: Value) Value {
    var cur = h;
    while (true) {
        const n = cur.decodePtr(*const RbNode);
        if (n.left.tag() != .rb_node) return cur;
        cur = n.left;
    }
}

/// Borrow a red from the right sibling so the left child can become red
/// (precondition for descending left during a delete).
fn moveRedLeft(rt: *Runtime, h: Value) !Value {
    var n = try flipColors(rt, h);
    const nn = n.decodePtr(*const RbNode);
    if (isRed(leftOf(nn.right))) {
        const nr = try rotateRight(rt, nn.right);
        n = try newNode(rt, nn.key, nn.val, nn.left, nr, nn.color);
        n = try rotateLeft(rt, n);
        n = try flipColors(rt, n);
    }
    return n;
}

/// Mirror of moveRedLeft for descending right.
fn moveRedRight(rt: *Runtime, h: Value) !Value {
    var n = try flipColors(rt, h);
    const nn = n.decodePtr(*const RbNode);
    if (isRed(leftOf(nn.left))) {
        n = try rotateRight(rt, n);
        n = try flipColors(rt, n);
    }
    return n;
}

/// Delete the minimum-key node; returns the rebalanced subtree (nil if it
/// became empty).
fn deleteMin(rt: *Runtime, h: Value) !Value {
    const hn = h.decodePtr(*const RbNode);
    if (hn.left.tag() != .rb_node) return Value.nil_val;
    var n = h;
    var nn = n.decodePtr(*const RbNode);
    if (!isRed(nn.left) and !isRed(leftOf(nn.left))) {
        n = try moveRedLeft(rt, n);
        nn = n.decodePtr(*const RbNode);
    }
    const new_left = try deleteMin(rt, nn.left);
    n = try newNode(rt, nn.key, nn.val, new_left, nn.right, nn.color);
    return balance(rt, n);
}

/// Delete `key` from a non-empty subtree known to contain it; returns the
/// rebalanced subtree (nil if it became empty).
fn deleteNode(rt: *Runtime, env: *Env, comparator: Value, h: Value, key: Value, loc: SourceLocation) !Value {
    // GC-ROOT: C. `n` is a fresh node (moveRed*/rotate results) held across
    // comparisons that may run a user comparator, and `child` across the
    // parent's rebuild alloc. The pure restructuring steps are fabrication
    // regions (ADR-0150); the comparisons stay outside them.
    var roots = [_]Value{ h, .nil_val };
    var sp: u16 = 2;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    var n = h;
    if (try compareKeys(rt, env, comparator, key, n.decodePtr(*const RbNode).key, loc) == .lt) {
        var nn = n.decodePtr(*const RbNode);
        if (!isRed(nn.left) and !isRed(leftOf(nn.left))) {
            n = try fabricate(rt, moveRedLeft, n);
            roots[0] = n;
            nn = n.decodePtr(*const RbNode);
        }
        roots[1] = try deleteNode(rt, env, comparator, nn.left, key, loc);
        n = try newNode(rt, nn.key, nn.val, roots[1], nn.right, nn.color);
    } else {
        var nn = n.decodePtr(*const RbNode);
        if (isRed(nn.left)) {
            n = try fabricate(rt, rotateRight, n);
            roots[0] = n;
            nn = n.decodePtr(*const RbNode);
        }
        // Leaf with matching key (after the right-lean fix): drop it.
        if (try compareKeys(rt, env, comparator, key, nn.key, loc) == .eq and nn.right.tag() != .rb_node) {
            return Value.nil_val;
        }
        if (!isRed(nn.right) and !isRed(leftOf(nn.right))) {
            n = try fabricate(rt, moveRedRight, n);
            roots[0] = n;
            nn = n.decodePtr(*const RbNode);
        }
        if (try compareKeys(rt, env, comparator, key, nn.key, loc) == .eq) {
            // Replace with in-order successor (min of right subtree), then
            // delete that successor from the right subtree.
            const succ = minNode(nn.right).decodePtr(*const RbNode);
            roots[1] = try fabricate(rt, deleteMin, nn.right);
            n = try newNode(rt, succ.key, succ.val, nn.left, roots[1], nn.color);
        } else {
            roots[1] = try deleteNode(rt, env, comparator, nn.right, key, loc);
            n = try newNode(rt, nn.key, nn.val, nn.left, roots[1], nn.color);
        }
    }
    return fabricate(rt, balance, n);
}

/// Run a pure-Zig multi-alloc tree step (rotation, recolor, balance,
/// deleteMin) inside an ADR-0150 fabrication region: it holds fresh nodes in
/// locals across its own allocs and never calls user code.
fn fabricate(rt: *Runtime, comptime step: anytype, h: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return step(rt, h);
}

// --- SortedMap public API ---

pub fn emptyMap(rt: *Runtime) !Value {
    return emptyMapBy(rt, Value.nil_val);
}

/// Empty sorted-map ordered by a custom comparator (nil = default
/// valueCompare). The comparator is a Clojure fn Value invoked per
/// comparison via `compareKeys`.
pub fn emptyMapBy(rt: *Runtime, comparator: Value) !Value {
    const m = try rt.gc.alloc(SortedMap);
    m.* = .{ .header = HeapHeader.init(.sorted_map), .comparator = comparator };
    return Value.encodeHeapPtr(.sorted_map, m);
}

/// Metadata of a sorted map / sorted set (or nil).
pub fn metaOf(v: Value) Value {
    return switch (v.tag()) {
        .sorted_map => v.decodePtr(*const SortedMap).meta,
        .sorted_set => v.decodePtr(*const SortedSet).meta,
        else => Value.nil_val,
    };
}

/// `(with-meta s m)` on a sorted map / set — a shallow copy sharing the tree
/// (or inner map), meta replaced (clj PersistentTreeMap/TreeSet.withMeta).
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    switch (v.tag()) {
        .sorted_map => {
            const sm = v.decodePtr(*const SortedMap);
            const nm = try rt.gc.alloc(SortedMap);
            nm.* = .{ .header = HeapHeader.init(.sorted_map), .count = sm.count, .comparator = sm.comparator, .root = sm.root, .meta = m };
            return Value.encodeHeapPtr(.sorted_map, nm);
        },
        .sorted_set => {
            const ss = v.decodePtr(*const SortedSet);
            const ns = try rt.gc.alloc(SortedSet);
            ns.* = .{ .header = HeapHeader.init(.sorted_set), .count = ss.count, .map = ss.map, .meta = m };
            return Value.encodeHeapPtr(.sorted_set, ns);
        },
        else => unreachable,
    }
}

pub fn isSortedMap(v: Value) bool {
    return v.tag() == .sorted_map;
}

pub fn count(v: Value) u32 {
    return switch (v.tag()) {
        .sorted_map => v.decodePtr(*const SortedMap).count,
        .sorted_set => v.decodePtr(*const SortedSet).count,
        else => 0,
    };
}

/// Walk every `(key, value)` of a `.sorted_map` in ascending key order
/// (in-order RB-tree traversal), calling `cb(ctx, key, value)` per entry.
/// Pure (no `rt`/`env`, no allocation), mirroring `map.forEachEntry` so a
/// non-reentrant primitive can iterate any map kind uniformly.
pub fn forEachEntry(
    v: Value,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value, Value) anyerror!void,
) anyerror!void {
    try rbForEachEntry(v.decodePtr(*const SortedMap).root, ctx, cb);
}

fn rbForEachEntry(
    node: Value,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value, Value) anyerror!void,
) anyerror!void {
    if (node.tag() != .rb_node) return;
    const n = node.decodePtr(*const RbNode);
    try rbForEachEntry(n.left, ctx, cb);
    try cb(ctx, n.key, n.val);
    try rbForEachEntry(n.right, ctx, cb);
}

// --- rt-free value-path surface (equal.zig partners, D-460) ---
// The keyEqValue / valueHash path deliberately lacks rt/env (D-151), so a
// sorted collection used as a hash-map KEY / hash-set ELEMENT cannot go
// through the comparator-based contains/get above. These compare and hash
// STRUCTURALLY (equal.keyEqValue over the tree walk — the comparator is
// never invoked, so custom-comparator collections work as keys too);
// lookup is an O(n) linear walk, fine for the rare sorted-coll-as-key path.

/// Content hash of a `.sorted_map` matching `map.contentHash`'s formula
/// (order-independent `+%` fold of `map.entryHash`, then mixCollHash) so an
/// `=` sorted-map and hash-map / array-map land in one bucket.
pub fn contentHashMap(v: Value) u32 {
    var acc: u32 = 0;
    rbFoldHash(v.decodePtr(*const SortedMap).root, &acc, false);
    return hash_mod.mixCollHash(acc, count(v));
}

/// Content hash of a `.sorted_set` matching `set.contentHash` (keys-only
/// fold over the backing map).
pub fn contentHashSet(v: Value) u32 {
    const s = v.decodePtr(*const SortedSet);
    var acc: u32 = 0;
    rbFoldHash(s.map.decodePtr(*const SortedMap).root, &acc, true);
    return hash_mod.mixCollHash(acc, s.count);
}

fn rbFoldHash(node: Value, acc: *u32, comptime keys_only: bool) void {
    if (node.tag() != .rb_node) return;
    const n = node.decodePtr(*const RbNode);
    rbFoldHash(n.left, acc, keys_only);
    acc.* +%= if (keys_only) equal.valueHash(n.key) else map_mod.entryHash(n.key, n.val);
    rbFoldHash(n.right, acc, keys_only);
}

/// rt-free VALUE-based key lookup in a `.sorted_map` (linear walk with
/// `equal.keyEqValue`; the comparator is not consulted). Returns null when
/// the key is absent (a present nil VALUE returns nil, not null).
pub fn getByValue(m_val: Value, k: Value) ?Value {
    return rbGetByValue(m_val.decodePtr(*const SortedMap).root, k);
}

fn rbGetByValue(node: Value, k: Value) ?Value {
    if (node.tag() != .rb_node) return null;
    const n = node.decodePtr(*const RbNode);
    if (equal.keyEqValue(n.key, k)) return n.val;
    return rbGetByValue(n.left, k) orelse rbGetByValue(n.right, k);
}

/// rt-free VALUE-based membership in a `.sorted_set`.
pub fn setContainsByValue(s_val: Value, x: Value) bool {
    return getByValue(s_val.decodePtr(*const SortedSet).map, x) != null;
}

/// Walk every element of a `.sorted_set` in order (= the keys of its
/// backing sorted map). Pure, like `forEachEntry`.
pub fn forEachElem(
    s_val: Value,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value) anyerror!void,
) anyerror!void {
    const Wrap = struct {
        fn entry(c: @TypeOf(ctx), k: Value, _: Value) anyerror!void {
            try cb(c, k);
        }
    };
    try forEachEntry(s_val.decodePtr(*const SortedSet).map, ctx, Wrap.entry);
}

/// GC-ROOT: C. Every public sorted mutator roots its own operands for the
/// whole call. A custom comparator is user code that can collect mid-walk,
/// and callers fold (`sorted-map`, multi-key `assoc`/`dissoc`/`disj`,
/// `print`, TreeMap/TreeSet) with the accumulator in a Zig local. Collects
/// only happen inside these calls, so rooting the operand here roots the
/// caller's accumulator too.
const OperandRoots = struct {
    roots: [3]Value,
    sp: u16 = 3,
    frame: root_set.EvalFrame = undefined,

    fn push(self: *OperandRoots) void {
        self.frame = .{ .stack = &self.roots, .sp = &self.sp, .locals = &.{}, .parent = root_set.eval_frame_head };
        root_set.eval_frame_head = &self.frame;
    }

    fn pop(self: *OperandRoots) void {
        root_set.eval_frame_head = self.frame.parent;
    }
};

pub fn assoc(rt: *Runtime, env: *Env, m_val: Value, key: Value, val: Value, loc: SourceLocation) !Value {
    var operands: OperandRoots = .{ .roots = .{ m_val, key, val } };
    operands.push();
    defer operands.pop();
    const m = m_val.decodePtr(*const SortedMap);
    const r = try insert(rt, env, m.comparator, m.root, key, val, loc);
    // ADR-0150: the new root is unrooted across makeBlack + the wrapper alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const black = try makeBlack(rt, r.node);
    const nm = try rt.gc.alloc(SortedMap);
    nm.* = .{
        .header = HeapHeader.init(.sorted_map),
        .count = if (r.added) m.count + 1 else m.count,
        .comparator = m.comparator,
        .root = black,
        .meta = m.meta,
    };
    return Value.encodeHeapPtr(.sorted_map, nm);
}

/// `entryAt`: the STORED entry for `key` (the tree's own key object, not
/// the probe), or null when absent. `get` / `contains` project it.
pub fn entryAt(rt: *Runtime, env: *Env, m_val: Value, key: Value, loc: SourceLocation) !?map_mod.Entry {
    const m = m_val.decodePtr(*const SortedMap);
    var h = m.root;
    while (h.tag() == .rb_node) {
        const hn = h.decodePtr(*const RbNode);
        switch (try compareKeys(rt, env, m.comparator, key, hn.key, loc)) {
            .lt => h = hn.left,
            .gt => h = hn.right,
            .eq => return .{ .key = hn.key, .val = hn.val },
        }
    }
    return null;
}

pub fn get(rt: *Runtime, env: *Env, m_val: Value, key: Value, loc: SourceLocation) !Value {
    return if (try entryAt(rt, env, m_val, key, loc)) |e| e.val else Value.nil_val;
}

pub fn contains(rt: *Runtime, env: *Env, m_val: Value, key: Value, loc: SourceLocation) !bool {
    return (try entryAt(rt, env, m_val, key, loc)) != null;
}

pub fn dissoc(rt: *Runtime, env: *Env, m_val: Value, key: Value, loc: SourceLocation) !Value {
    var operands: OperandRoots = .{ .roots = .{ m_val, key, .nil_val } };
    operands.push();
    defer operands.pop();
    const m = m_val.decodePtr(*const SortedMap);
    if (m.root.tag() != .rb_node) return m_val;
    if (!try contains(rt, env, m_val, key, loc)) return m_val; // absent → no-op (count stays)
    var root = m.root;
    const rn = root.decodePtr(*const RbNode);
    // Set the root red so the first borrow has a red to move down.
    if (!isRed(rn.left) and !isRed(rn.right)) {
        root = try newNode(rt, rn.key, rn.val, rn.left, rn.right, RED);
    }
    const deleted = try deleteNode(rt, env, m.comparator, root, key, loc);
    // ADR-0150: the new root is unrooted across makeBlack + the wrapper alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    root = try makeBlack(rt, deleted);
    const nm = try rt.gc.alloc(SortedMap);
    nm.* = .{
        .header = HeapHeader.init(.sorted_map),
        .count = m.count - 1,
        .comparator = m.comparator,
        .root = root,
        .meta = m.meta,
    };
    return Value.encodeHeapPtr(.sorted_map, nm);
}

// In-order walks: `.cons` cells are non-list ISeqs (as on the JVM).
// Prepending right→node→left yields ascending order at the front.
fn keysInto(rt: *Runtime, h: Value, acc: Value) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    var result = try keysInto(rt, hn.right, acc);
    result = try list_mod.consSeqHeap(rt, hn.key, result);
    return keysInto(rt, hn.left, result);
}

fn valsInto(rt: *Runtime, h: Value, acc: Value) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    var result = try valsInto(rt, hn.right, acc);
    result = try list_mod.consSeqHeap(rt, hn.val, result);
    return valsInto(rt, hn.left, result);
}

fn seqInto(rt: *Runtime, h: Value, acc: Value) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    var result = try seqInto(rt, hn.right, acc);
    // A map's seq yields MAP ENTRIES, not plain 2-vectors — `map.seq` already
    // does (`(map-entry? (first {:a 1}))` → true), and `key`/`val` require a
    // real entry. Building a vector here made the sorted path (sorted-map,
    // and java.util.TreeMap which delegates to it) the odd one out, so
    // `(map key (seq (java.util.TreeMap. …)))` threw. AD-032 promises a cljw
    // MapEntry for these seq-views; this is what makes that true.
    const pair = try map_entry_mod.make(rt, hn.key, hn.val);
    result = try list_mod.consSeqHeap(rt, pair, result);
    return seqInto(rt, hn.left, result);
}

// ADR-0150: every tree walk below holds its partial list (and seq's fresh
// MapEntry) in Zig locals across the next consHeap alloc, so each public
// entry brackets the walk in a fabrication region (pure Zig, no eval).
pub fn keys(rt: *Runtime, v: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return switch (v.tag()) {
        .sorted_map => try keysInto(rt, v.decodePtr(*const SortedMap).root, Value.nil_val),
        .sorted_set => try keysInto(rt, mapOf(v).decodePtr(*const SortedMap).root, Value.nil_val),
        else => Value.nil_val,
    };
}

pub fn vals(rt: *Runtime, v: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return try valsInto(rt, v.decodePtr(*const SortedMap).root, Value.nil_val);
}

pub fn seq(rt: *Runtime, v: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return switch (v.tag()) {
        .sorted_map => try seqInto(rt, v.decodePtr(*const SortedMap).root, Value.nil_val),
        .sorted_set => try keysInto(rt, mapOf(v).decodePtr(*const SortedMap).root, Value.nil_val),
        else => Value.nil_val,
    };
}

// Descending walk: visit left→node→right and prepend, so the largest key
// (visited last) lands at the front (the mirror of seqInto's ascending walk).
fn rseqSetInto(rt: *Runtime, h: Value, acc: Value) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    var result = try rseqSetInto(rt, hn.left, acc);
    result = try list_mod.consSeqHeap(rt, hn.key, result);
    return rseqSetInto(rt, hn.right, result);
}

fn rseqMapInto(rt: *Runtime, h: Value, acc: Value) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    var result = try rseqMapInto(rt, hn.left, acc);
    // Map entries, not 2-vectors — same contract as `seqInto` above.
    const pair = try map_entry_mod.make(rt, hn.key, hn.val);
    result = try list_mod.consSeqHeap(rt, pair, result);
    return rseqMapInto(rt, hn.right, result);
}

/// Reverse seq: descending [k v] pairs (map) / descending elements (set).
pub fn rseq(rt: *Runtime, v: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return switch (v.tag()) {
        .sorted_map => try rseqMapInto(rt, v.decodePtr(*const SortedMap).root, Value.nil_val),
        .sorted_set => try rseqSetInto(rt, mapOf(v).decodePtr(*const SortedMap).root, Value.nil_val),
        else => Value.nil_val,
    };
}

// --- subseq / rsubseq (range queries) ---

/// Up to two `(test, key)` constraints; a node passes when ALL present
/// constraints hold. `(subseq sc test key)` sets one; the 5-arg form sets
/// both. `test` is a user fn (`<` / `<=` / `>` / `>=`) applied to
/// `(test (compare node-key bound) 0)` — mirrors Clojure's `mk-bound-fn`.
pub const Bound = struct {
    test1: ?Value = null,
    key1: Value = Value.nil_val,
    test2: ?Value = null,
    key2: Value = Value.nil_val,
};

fn applyTest(rt: *Runtime, env: *Env, test_fn: Value, order: std.math.Order, loc: SourceLocation) !bool {
    const cmp_int: i48 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    const vt = rt.vtable orelse return error.NoVTable;
    const r = try vt.callFn(rt, env, test_fn, &.{ Value.initInteger(cmp_int), Value.initInteger(0) }, loc);
    return r.isTruthy();
}

fn inRange(rt: *Runtime, env: *Env, comparator: Value, node_key: Value, b: Bound, loc: SourceLocation) !bool {
    if (b.test1) |t| {
        if (!try applyTest(rt, env, t, try compareKeys(rt, env, comparator, node_key, b.key1, loc), loc)) return false;
    }
    if (b.test2) |t| {
        if (!try applyTest(rt, env, t, try compareKeys(rt, env, comparator, node_key, b.key2, loc), loc)) return false;
    }
    return true;
}

// Visit order is the reverse of the desired output order (consHeap prepends):
// ascending output ⇒ visit right→node→left; descending ⇒ left→node→right.
fn subseqWalk(rt: *Runtime, env: *Env, is_map: bool, comparator: Value, h: Value, b: Bound, ascending: bool, acc: Value, loc: SourceLocation) !Value {
    if (h.tag() != .rb_node) return acc;
    const hn = h.decodePtr(*const RbNode);
    const first = if (ascending) hn.right else hn.left;
    const second = if (ascending) hn.left else hn.right;
    // GC-ROOT: C. The partial list crosses `inRange` (user test fns and
    // comparator) and the entry/cons allocs; the fresh entry crosses the cons.
    var roots = [_]Value{ acc, .nil_val };
    var sp: u16 = 2;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    roots[0] = try subseqWalk(rt, env, is_map, comparator, first, b, ascending, acc, loc);
    if (try inRange(rt, env, comparator, hn.key, b, loc)) {
        // Map entries, not 2-vectors, same contract as `seqInto`, so
        // `(key (first (subseq …)))` works like every other map seq.
        roots[1] = if (is_map) try map_entry_mod.make(rt, hn.key, hn.val) else hn.key;
        roots[0] = try list_mod.consSeqHeap(rt, roots[1], roots[0]);
    }
    return subseqWalk(rt, env, is_map, comparator, second, b, ascending, roots[0], loc);
}

/// `(subseq sc …)` / `(rsubseq sc …)` — entries whose key satisfies `b`,
/// in ascending (subseq) or descending (rsubseq) order. Empty → nil.
pub fn subseqRange(rt: *Runtime, env: *Env, coll: Value, ascending: bool, b: Bound, loc: SourceLocation) !Value {
    const is_map = coll.tag() == .sorted_map;
    const inner = if (is_map) coll else mapOf(coll);
    const m = inner.decodePtr(*const SortedMap);
    return subseqWalk(rt, env, is_map, m.comparator, m.root, b, ascending, Value.nil_val, loc);
}

/// Closest key to `target`: `.floor` = greatest ≤, `.ceiling` = least ≥,
/// `.lower` = greatest <, `.higher` = least > (nil if none). O(log n) RB-tree
/// descent using only the collection's comparator. For a `.sorted_set` the keys
/// ARE the elements. Backs java.util.TreeMap/TreeSet NavigableMap/Set navigation.
pub const NavKind = enum { floor, ceiling, lower, higher };
pub fn navKey(rt: *Runtime, env: *Env, coll: Value, target: Value, kind: NavKind, loc: SourceLocation) !Value {
    const is_set = coll.tag() == .sorted_set;
    const inner = if (is_set) mapOf(coll) else coll;
    const m = inner.decodePtr(*const SortedMap);
    const want_le = (kind == .floor or kind == .lower); // descend right toward the greatest satisfying key
    var best: Value = Value.nil_val;
    var node = m.root;
    while (node.tag() == .rb_node) {
        const hn = node.decodePtr(*const RbNode);
        const ord = try compareKeys(rt, env, m.comparator, hn.key, target, loc); // key vs target
        const satisfies = switch (kind) {
            .floor => ord != .gt, // key <= target
            .lower => ord == .lt, // key <  target
            .ceiling => ord != .lt, // key >= target
            .higher => ord == .gt, // key >  target
        };
        if (satisfies) {
            best = hn.key;
            node = if (want_le) hn.right else hn.left;
        } else {
            node = if (want_le) hn.left else hn.right;
        }
    }
    return best;
}

// --- SortedSet public API (wraps a SortedMap, element → element) ---

inline fn mapOf(set_val: Value) Value {
    return set_val.decodePtr(*const SortedSet).map;
}

pub fn emptySet(rt: *Runtime) !Value {
    return emptySetBy(rt, Value.nil_val);
}

/// Empty sorted-set ordered by a custom comparator (nil = default).
pub fn emptySetBy(rt: *Runtime, comparator: Value) !Value {
    // ADR-0150: `inner` is unrooted across the SortedSet alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const inner = try emptyMapBy(rt, comparator);
    const s = try rt.gc.alloc(SortedSet);
    s.* = .{ .header = HeapHeader.init(.sorted_set), .map = inner };
    return Value.encodeHeapPtr(.sorted_set, s);
}

pub fn isSortedSet(v: Value) bool {
    return v.tag() == .sorted_set;
}

pub fn conjSet(rt: *Runtime, env: *Env, set_val: Value, elem: Value, loc: SourceLocation) !Value {
    var operands: OperandRoots = .{ .roots = .{ set_val, elem, .nil_val } };
    operands.push();
    defer operands.pop();
    const s = set_val.decodePtr(*const SortedSet);
    const new_map = try assoc(rt, env, s.map, elem, elem, loc);
    // ADR-0150: `new_map` is unrooted across the SortedSet alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const ns = try rt.gc.alloc(SortedSet);
    ns.* = .{ .header = HeapHeader.init(.sorted_set), .count = new_map.decodePtr(*const SortedMap).count, .map = new_map, .meta = s.meta };
    return Value.encodeHeapPtr(.sorted_set, ns);
}

pub fn setContains(rt: *Runtime, env: *Env, set_val: Value, elem: Value, loc: SourceLocation) !bool {
    return contains(rt, env, mapOf(set_val), elem, loc);
}

/// The STORED element `=` to `elem` under the set's comparator, or null.
pub fn setGet(rt: *Runtime, env: *Env, set_val: Value, elem: Value, loc: SourceLocation) !?Value {
    return if (try entryAt(rt, env, mapOf(set_val), elem, loc)) |e| e.key else null;
}

pub fn disjSet(rt: *Runtime, env: *Env, set_val: Value, elem: Value, loc: SourceLocation) !Value {
    var operands: OperandRoots = .{ .roots = .{ set_val, elem, .nil_val } };
    operands.push();
    defer operands.pop();
    const s = set_val.decodePtr(*const SortedSet);
    const new_map = try dissoc(rt, env, s.map, elem, loc);
    // ADR-0150: `new_map` is unrooted across the SortedSet alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const ns = try rt.gc.alloc(SortedSet);
    ns.* = .{ .header = HeapHeader.init(.sorted_set), .count = new_map.decodePtr(*const SortedMap).count, .map = new_map, .meta = s.meta };
    return Value.encodeHeapPtr(.sorted_set, ns);
}

// --- GC traces ---

pub fn traceRbNode(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const n: *RbNode = @ptrCast(@alignCast(header));
    if (n.key.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (n.val.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (n.left.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (n.right.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn traceSortedMap(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const m: *SortedMap = @ptrCast(@alignCast(header));
    if (m.comparator.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (m.root.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (m.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn traceSortedSet(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const s: *SortedSet = @ptrCast(@alignCast(header));
    if (s.map.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (s.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.rb_node, &traceRbNode);
    tag_ops.registerTrace(.sorted_map, &traceSortedMap);
    tag_ops.registerTrace(.sorted_set, &traceSortedSet);
}

// --- tests ---

const testing = std.testing;

test "SortedMap assoc keeps key order + get + count + dup-replace" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var env = try Env.init(&rt);
    defer env.deinit();

    const noloc: SourceLocation = .{};
    var m = try emptyMap(&rt);
    // insert 0..49 in a shuffled-ish order (i*17 mod 50 is a permutation)
    var i: i48 = 0;
    while (i < 50) : (i += 1) {
        const k = @mod(i * 17, 50);
        m = try assoc(&rt, &env, m, Value.initInteger(k), Value.initInteger(k * 10), noloc);
    }
    try testing.expectEqual(@as(u32, 50), count(m));
    // every key reads back
    i = 0;
    while (i < 50) : (i += 1) {
        try testing.expectEqual(@as(i48, i * 10), (try get(&rt, &env, m, Value.initInteger(i), noloc)).asInteger());
    }
    // dup key replaces, count unchanged
    m = try assoc(&rt, &env, m, Value.initInteger(7), Value.initInteger(-1), noloc);
    try testing.expectEqual(@as(u32, 50), count(m));
    try testing.expectEqual(@as(i48, -1), (try get(&rt, &env, m, Value.initInteger(7), noloc)).asInteger());
    try testing.expect(!try contains(&rt, &env, m, Value.initInteger(999), noloc));
}

/// Recursively verify the LLRB invariants and return the subtree's black
/// height. A buggy delete typically passes membership smoke tests but
/// violates one of these (the strong canary). Asserts: BST order,
/// left-leaning (no red right link), no two consecutive red links,
/// equal black height on both sides.
fn checkInvariants(h: Value) !usize {
    if (h.tag() != .rb_node) return 1; // null links are black
    const hn = h.decodePtr(*const RbNode);
    // left-lean: a red right link is forbidden
    try testing.expect(!isRed(hn.right));
    // no two consecutive reds
    if (isRed(h)) try testing.expect(!isRed(hn.left) and !isRed(hn.right));
    // BST order against immediate children
    if (hn.left.tag() == .rb_node) {
        try testing.expect(hn.left.decodePtr(*const RbNode).key.asInteger() < hn.key.asInteger());
    }
    if (hn.right.tag() == .rb_node) {
        try testing.expect(hn.right.decodePtr(*const RbNode).key.asInteger() > hn.key.asInteger());
    }
    const lh = try checkInvariants(hn.left);
    const rh = try checkInvariants(hn.right);
    try testing.expectEqual(lh, rh); // equal black height
    return lh + @as(usize, if (hn.color == BLACK) 1 else 0);
}

test "SortedMap delete: remove half, invariants + membership hold" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var env = try Env.init(&rt);
    defer env.deinit();

    const noloc: SourceLocation = .{};
    var m = try emptyMap(&rt);
    // build with shuffled insert order (i*17 mod 50 is a permutation)
    var i: i48 = 0;
    while (i < 50) : (i += 1) {
        const k = @mod(i * 17, 50);
        m = try assoc(&rt, &env, m, Value.initInteger(k), Value.initInteger(k * 10), noloc);
    }
    // delete every even key
    i = 0;
    while (i < 50) : (i += 2) {
        m = try dissoc(&rt, &env, m, Value.initInteger(i), noloc);
    }
    try testing.expectEqual(@as(u32, 25), count(m));
    _ = try checkInvariants(m.decodePtr(*const SortedMap).root);
    i = 0;
    while (i < 50) : (i += 1) {
        const present = try contains(&rt, &env, m, Value.initInteger(i), noloc);
        try testing.expectEqual(@mod(i, 2) == 1, present); // only odds survive
    }
    // deleting an absent key is a no-op (count unchanged)
    m = try dissoc(&rt, &env, m, Value.initInteger(0), noloc);
    try testing.expectEqual(@as(u32, 25), count(m));
    // delete all remaining → empty
    i = 1;
    while (i < 50) : (i += 2) {
        m = try dissoc(&rt, &env, m, Value.initInteger(i), noloc);
    }
    try testing.expectEqual(@as(u32, 0), count(m));
    try testing.expect(m.decodePtr(*const SortedMap).root.isNil());
}
