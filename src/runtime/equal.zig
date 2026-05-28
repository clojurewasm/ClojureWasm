// SPDX-License-Identifier: EPL-2.0
//! Universal value equality for `clojure.core/=` (= `clojure.lang.Util.equiv`).
//! ADR-0052.
//!
//! `valueEqual(rt, a, b)` is by-value across nil / bool / number / char /
//! keyword / symbol / string, structural for sequentials (vector / list,
//! cross-type) and array-maps / sets, and **numeric category-gated per
//! F-005** (`(= 1 1.0)` → false; `==` in `math.zig` is the widening
//! numeric-tower comparator). It NEVER raises on a type mismatch
//! (different/unhandled value → false); only real errors (OOM, a
//! collection accessor) propagate via the error union.
//!
//! Scope (ADR-0052 D2/D3): sequential cursor covers vector + list (the
//! literal-constructible sequentials); range / array_seq / lazy_seq
//! sequential equality is deferred (env / lazy-realization dependency).
//! Map / set key matching rides the existing bit-pattern `keyEq`, so
//! collection-keyed lookup is correct only for by-identity keys
//! (keyword / int / symbol) — structural collection keys await D-092.
//! Cross-category `==` (e.g. `(== 1N 1.0)`) awaits the numeric combine
//! ladder (D-014a family); `=` never needs it (category gate → false).

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const string_mod = @import("collection/string.zig");
const vector = @import("collection/vector.zig");
const list = @import("collection/list.zig");
const map = @import("collection/map.zig");
const set = @import("collection/set.zig");
const big_int = @import("numeric/big_int.zig");
const ratio = @import("numeric/ratio.zig");
const big_decimal = @import("numeric/big_decimal.zig");

const NumCat = enum { integer, floating, ratio, decimal, none };

fn numCat(v: Value) NumCat {
    return switch (v.tag()) {
        .integer, .big_int => .integer,
        .float => .floating,
        .ratio => .ratio,
        .big_decimal => .decimal,
        else => .none,
    };
}

fn isSequential(v: Value) bool {
    const t = v.tag();
    return t == .vector or t == .list;
}

fn seqLen(v: Value) u32 {
    return switch (v.tag()) {
        .vector => vector.count(v),
        .list => list.countOf(v),
        else => 0,
    };
}

/// A tagged element cursor over a vector (index) or list (first/rest),
/// so the two can be compared element-wise regardless of concrete type.
const Cursor = union(enum) {
    vec: struct { v: Value, i: u32, n: u32 },
    lst: Value,

    fn init(v: Value) Cursor {
        return switch (v.tag()) {
            .vector => .{ .vec = .{ .v = v, .i = 0, .n = vector.count(v) } },
            else => .{ .lst = v },
        };
    }

    fn next(self: *Cursor) ?Value {
        switch (self.*) {
            .vec => |*s| {
                if (s.i >= s.n) return null;
                const e = vector.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .lst => |*node| {
                if (node.tag() != .list or list.countOf(node.*) == 0) return null;
                const e = list.first(node.*);
                node.* = list.rest(node.*);
                return e;
            },
        }
    }
};

/// Within-category integer equality. Handles int↔int, big_int↔big_int,
/// and the int↔big_int cross-representation (`(= 1 1N)` → true) via
/// `Managed.toInt` (a big_int too large to fit an i48 int → false).
fn intEqual(a: Value, b: Value) bool {
    const ta = a.tag();
    const tb = b.tag();
    if (ta == .integer and tb == .integer) return a.asInteger() == b.asInteger();
    if (ta == .big_int and tb == .big_int)
        return big_int.compareManaged(big_int.asManaged(a), big_int.asManaged(b)) == .eq;
    // Mixed int / big_int.
    const small: Value = if (ta == .integer) a else b;
    const big: Value = if (ta == .big_int) a else b;
    const as_i = big_int.asManaged(big).toInt(i64) catch return false;
    return as_i == @as(i64, small.asInteger());
}

fn seqEqual(rt: *Runtime, a: Value, b: Value) anyerror!bool {
    if (seqLen(a) != seqLen(b)) return false;
    var ca = Cursor.init(a);
    var cb = Cursor.init(b);
    while (true) {
        const ea = ca.next();
        const eb = cb.next();
        if (ea == null and eb == null) return true;
        if (ea == null or eb == null) return false;
        if (!try valueEqual(rt, ea.?, eb.?)) return false;
    }
}

fn mapEqual(rt: *Runtime, a: Value, b: Value) anyerror!bool {
    if (map.count(a) != map.count(b)) return false;
    var ks = try map.keys(rt, a);
    while (ks.tag() == .list and list.countOf(ks) > 0) {
        const k = list.first(ks);
        if (!try map.contains(b, k)) return false;
        if (!try valueEqual(rt, try map.get(a, k), try map.get(b, k))) return false;
        ks = list.rest(ks);
    }
    return true;
}

fn setEqual(rt: *Runtime, a: Value, b: Value) anyerror!bool {
    if (set.count(a) != set.count(b)) return false;
    var es = try set.seq(rt, a);
    while (es.tag() == .list and list.countOf(es) > 0) {
        if (!try set.contains(b, list.first(es))) return false;
        es = list.rest(es);
    }
    return true;
}

/// `(= a b)` semantics. See module docstring + ADR-0052.
pub fn valueEqual(rt: *Runtime, a: Value, b: Value) anyerror!bool {
    // 1. Identity fast path: nil / bool / int / char / builtin_fn /
    //    interned keyword·symbol / pointer-identical heap.
    if (@intFromEnum(a) == @intFromEnum(b)) return true;

    // 2. Numeric arm, category-gated (F-005).
    const ca = numCat(a);
    const cb = numCat(b);
    if (ca != .none or cb != .none) {
        if (ca != cb) return false; // cross-category (incl. number vs non-number) → false
        return switch (ca) {
            .integer => intEqual(a, b),
            .floating => a.asFloat() == b.asFloat(),
            .ratio => (try ratio.compareValue(rt, a, b)) == .eq,
            .decimal => (try big_decimal.compareValue(rt, a, b)) == .eq,
            .none => unreachable,
        };
    }

    // 3. Sequential cross-type (vector / list).
    if (isSequential(a) and isSequential(b)) return seqEqual(rt, a, b);

    // 4. Same-tag content arms; any other tag pairing → false.
    const ta = a.tag();
    if (ta != b.tag()) return false;
    // keyword / symbol are interned, so equal ones already hit the
    // identity fast path above; a non-bit-identical pair is unequal.
    return switch (ta) {
        .string => std.mem.eql(u8, string_mod.asString(a), string_mod.asString(b)),
        .array_map, .hash_map => mapEqual(rt, a, b),
        .hash_set => setEqual(rt, a, b),
        else => false,
    };
}
