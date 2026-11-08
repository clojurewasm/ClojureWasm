// SPDX-License-Identifier: EPL-2.0
//! Collection-literal construction, shared by every site that builds one:
//! the analyzer's constant fold, the VM's literal and extend opcodes, and the
//! bytecode decoder of a collection constant (D-346). One construction means a
//! folded constant, a decoded constant and a per-evaluation build of the same
//! literal are equal by construction: a repeated map key keeps its last value,
//! a set collapses duplicates, and an array map keeps insertion order.
//!
//! GC contract: the caller keeps `items` rooted (operand stack, analysis
//! roots, a decoder frame). `build` roots the collection it grows; `extend`
//! grows the collection in a slot the caller has rooted.

const std = @import("std");
const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const root_set = @import("../gc/root_set.zig");
const vector_mod = @import("vector.zig");
const map_mod = @import("map.zig");
const set_mod = @import("set.zig");

pub const Kind = enum { vector, map, set };

/// Build a `kind` collection from `items`; a map's items are its flat
/// k0 v0 k1 v1 ... sequence (an even count).
pub fn build(rt: *Runtime, comptime kind: Kind, items: []const Value) !Value {
    switch (kind) {
        // PERF: one bulk build, not N conj steps of throwaway vectors [refs: O-040]
        .vector => return vector_mod.fromSlice(rt, items),
        .map => {
            std.debug.assert(items.len % 2 == 0);
            // PERF: one-alloc array map for a small simple-key literal [refs: O-026]
            // The naive form is the assoc fold below, which copies the
            // ArrayMap each step. Simple keys keep the dedup keyEq pure, so
            // no GC can run during the fill.
            if (items.len >= 2 and items.len <= 2 * map_mod.ARRAY_MAP_THRESHOLD and map_mod.allSimpleKeys(items))
                return map_mod.fromLiteralPairs(rt, items);
        },
        .set => {},
    }
    // GC-ROOT: the growing map or set, between the steps' allocations.
    var acc = [_]Value{if (kind == .map) map_mod.empty() else set_mod.empty()};
    var sp: u16 = acc.len;
    var frame: root_set.EvalFrame = .{ .stack = &acc, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    try extend(rt, kind, &acc[0], items);
    return acc[0];
}

/// Add `items` in order to the `kind` collection in `acc`. `acc` must point at
/// a GC-rooted slot: each step writes the grown collection back through it, so
/// the partial collection is never held only by a Zig local across an
/// allocation. The VM's stepped build of a large literal extends the collection
/// in its operand-stack slot this way.
///
/// `acc` holds a `kind` collection by contract (vector and set `conj` assert
/// it), so a map step never meets a non-map.
pub fn extend(rt: *Runtime, comptime kind: Kind, acc: *Value, items: []const Value) !void {
    switch (kind) {
        .vector => for (items) |x| {
            acc.* = try vector_mod.conj(rt, acc.*, x);
        },
        .map => {
            std.debug.assert(items.len % 2 == 0);
            var i: usize = 0;
            while (i < items.len) : (i += 2) acc.* = map_mod.assoc(rt, acc.*, items[i], items[i + 1]) catch |e| switch (e) {
                error.AssocOnNonMap => unreachable,
                else => |other| return other,
            };
        },
        .set => for (items) |x| {
            acc.* = set_mod.conj(rt, acc.*, x) catch |e| switch (e) {
                error.AssocOnNonMap => unreachable,
                else => |other| return other,
            };
        },
    }
}
