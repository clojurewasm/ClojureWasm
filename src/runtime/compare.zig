// SPDX-License-Identifier: EPL-2.0
//! General 3-way comparison for `clojure.core/compare` (= `clojure.lang.Util.compare`).
//! ADR-0053. Sibling of `equal.zig` (kept separate: the numeric arm here
//! CROSSES the tower with no category gate — the opposite of `=`'s F-005
//! gate — so a shared "numeric arm" would be a maintainer hazard).
//!
//! `valueCompare(rt, a, b, loc)` returns `std.math.Order`. nil is lowest;
//! numbers compare by value across the tower; strings lexicographic;
//! bool false<true; char by codepoint; keyword/symbol by ns-then-name;
//! vectors length-first then element-wise. Mismatched / uncomparable
//! pairs (incl. lists — not Comparable in JVM) RAISE (compare is not
//! under `=`'s never-raise contract).
//!
//! Numeric scope (ADR-0053 D2): same-category exact via the existing
//! Order fns; the int/float reach via f64; exact cross-category
//! (ratio/decimal mixed, or big magnitudes beyond i64) is deferred to
//! the numeric combine ladder (D-014a family) and raises for now.

const std = @import("std");
const Order = std.math.Order;
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const string_mod = @import("collection/string.zig");
const vector = @import("collection/vector.zig");
const map_entry_mod = @import("collection/map_entry.zig");
const keyword = @import("keyword.zig");
const symbol = @import("symbol.zig");
const big_int = @import("numeric/big_int.zig");
const ratio = @import("numeric/ratio.zig");
const big_decimal = @import("numeric/big_decimal.zig");
const promote = @import("numeric/promote.zig");
const instant_value = @import("time/instant_value.zig");
const duration_value = @import("time/duration_value.zig");
const local_date_value = @import("time/local_date_value.zig");
const local_time_value = @import("time/local_time_value.zig");
const local_date_time_value = @import("time/local_date_time_value.zig");

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

fn raiseUncomparable(loc: SourceLocation, other: Value) anyerror {
    return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "compare", .actual = @tagName(other.tag()) });
}

/// Both values are in the `.integer` category (int and/or big_int).
fn intOrder(a: Value, b: Value) anyerror!Order {
    const ta = a.tag();
    const tb = b.tag();
    if (ta == .integer and tb == .integer)
        return std.math.order(a.asInteger(), b.asInteger());
    if (ta == .big_int and tb == .big_int)
        return big_int.compareManaged(big_int.asManaged(a), big_int.asManaged(b));
    // Mixed int <-> big_int: convert the big to i64 if it fits (the int
    // is i48, so this is exact); a magnitude beyond i64 is decided by the
    // big_int's sign (it is larger in absolute value than any i48 int).
    const big: Value = if (ta == .big_int) a else b;
    const small_i: i64 = if (ta == .integer) a.asInteger() else b.asInteger();
    const big_managed = big_int.asManaged(big);
    const big_vs_small: Order = if (big_managed.toInt(i64)) |bi|
        std.math.order(bi, small_i)
    else |_|
        (if (big_managed.toConst().positive) Order.gt else Order.lt);
    // big_vs_small is (big ? small); flip when `big` was the second arg.
    return if (ta == .big_int) big_vs_small else big_vs_small.invert();
}

fn numericOrder(rt: *Runtime, a: Value, b: Value, loc: SourceLocation) anyerror!Order {
    const ca = numCat(a);
    const cb = numCat(b);
    if (ca == cb) {
        return switch (ca) {
            .integer => intOrder(a, b),
            .floating => std.math.order(a.asFloat(), b.asFloat()),
            .ratio => try ratio.compareValue(rt, a, b),
            .decimal => try big_decimal.compareValue(rt, a, b),
            .none => unreachable,
        };
    }
    // Cross-category: the exact sign of the tower-promoting difference (the
    // D-014a combine ladder, now done exactly). Float contagion → f64 sign
    // (clj: `(compare 1N 1.0)`→0); a no-float mix (ratio/int/BigDecimal/BigInt)
    // compares EXACTLY. Replaces the old lossy f64 collapse that raised on any
    // ratio / BigDecimal / big-magnitude operand.
    _ = loc;
    return promote.orderNumeric(rt, a, b);
}

fn nsNameOrder(ns_a: ?[]const u8, name_a: []const u8, ns_b: ?[]const u8, name_b: []const u8) Order {
    // A nil namespace sorts before any non-nil namespace.
    if (ns_a == null and ns_b != null) return .lt;
    if (ns_a != null and ns_b == null) return .gt;
    if (ns_a) |na| {
        const o = std.mem.order(u8, na, ns_b.?);
        if (o != .eq) return o;
    }
    return std.mem.order(u8, name_a, name_b);
}

/// Vector-like length (a MapEntry is a 2-vector, D-209).
fn vecLikeCount(v: Value) u32 {
    return if (v.tag() == .map_entry) 2 else vector.count(v);
}

/// Vector-like positional access (a MapEntry: 0→key, 1→val).
fn vecLikeNth(v: Value, i: u32) Value {
    return if (v.tag() == .map_entry) map_entry_mod.nth(v, i) else vector.nth(v, @intCast(i));
}

/// Compare two vector-like values (vector / MapEntry, any pairing)
/// length-first then element-wise — so `(compare (first {:a 1}) [:a 1])`→0
/// (D-209: a MapEntry compares as the 2-vector `[k v]`).
fn vecOrder(rt: *Runtime, a: Value, b: Value, loc: SourceLocation) anyerror!Order {
    const na = vecLikeCount(a);
    const nb = vecLikeCount(b);
    if (na != nb) return std.math.order(na, nb); // length-first
    var i: u32 = 0;
    while (i < na) : (i += 1) {
        const o = try valueCompare(rt, vecLikeNth(a, i), vecLikeNth(b, i), loc);
        if (o != .eq) return o;
    }
    return .eq;
}

/// 3-way order for a same-type java.time temporal pair (D-462), so `(compare …)`
/// + `(sort …)` work on temporal values. Sign-based (returns Order → -1/0/1 when
/// surfaced) like every other cljw `compare` arm — clj's field-difference
/// MAGNITUDE for LocalDate/LocalDateTime is AD-043. A cross-temporal-type or
/// non-temporal typed_instance (deftype/record) pair raises (clj: ClassCast).
/// Mirrors the equal.zig per-type arms.
fn temporalOrder(rt: *Runtime, a: Value, b: Value, loc: SourceLocation) anyerror!Order {
    if (instant_value.isInstant(rt, a) and instant_value.isInstant(rt, b)) {
        const o = std.math.order(instant_value.epochMsOf(a), instant_value.epochMsOf(b));
        return if (o != .eq) o else std.math.order(instant_value.nanosOf(a), instant_value.nanosOf(b));
    }
    if (duration_value.isDuration(rt, a) and duration_value.isDuration(rt, b)) {
        const o = std.math.order(duration_value.secondsOf(a), duration_value.secondsOf(b));
        return if (o != .eq) o else std.math.order(duration_value.nanosOf(a), duration_value.nanosOf(b));
    }
    if (local_date_value.isLocalDate(rt, a) and local_date_value.isLocalDate(rt, b)) {
        return std.math.order(local_date_value.epochDayOf(a), local_date_value.epochDayOf(b));
    }
    if (local_time_value.isLocalTime(rt, a) and local_time_value.isLocalTime(rt, b)) {
        return std.math.order(local_time_value.nanoOfDayOf(a), local_time_value.nanoOfDayOf(b));
    }
    if (local_date_time_value.isLocalDateTime(rt, a) and local_date_time_value.isLocalDateTime(rt, b)) {
        const o = std.math.order(local_date_time_value.epochDayOf(a), local_date_time_value.epochDayOf(b));
        return if (o != .eq) o else std.math.order(local_date_time_value.nanoOfDayOf(a), local_date_time_value.nanoOfDayOf(b));
    }
    return raiseUncomparable(loc, a);
}

/// `(compare a b)` semantics. See module docstring + ADR-0053.
pub fn valueCompare(rt: *Runtime, a: Value, b: Value, loc: SourceLocation) anyerror!Order {
    if (@intFromEnum(a) == @intFromEnum(b)) return .eq;

    const ta = a.tag();
    const tb = b.tag();

    // nil is lowest.
    if (ta == .nil) return .lt;
    if (tb == .nil) return .gt;

    // Numeric (both): crosses the tower (no category gate).
    if (numCat(a) != .none and numCat(b) != .none) return numericOrder(rt, a, b, loc);

    // Vector-like family (D-209): a MapEntry IS-A vector, so any
    // vector/map_entry pairing compares element-wise (`(compare (first {:a
    // 1}) [:a 1])`→0) — handled before the same-tag gate below.
    if ((ta == .vector or ta == .map_entry) and (tb == .vector or tb == .map_entry)) {
        return vecOrder(rt, a, b, loc);
    }

    // Beyond here a same-tag pairing is required; cross-type raises.
    if (ta != tb) return raiseUncomparable(loc, b);

    return switch (ta) {
        .string => std.mem.order(u8, string_mod.asString(a), string_mod.asString(b)),
        .boolean => if (a == Value.false_val) Order.lt else Order.gt, // false < true (identity caught equal)
        .char => std.math.order(a.asChar(), b.asChar()),
        .keyword => blk: {
            const ka = keyword.asKeyword(a);
            const kb = keyword.asKeyword(b);
            break :blk nsNameOrder(ka.ns, ka.name, kb.ns, kb.name);
        },
        .symbol => blk: {
            const sa = symbol.asSymbol(a);
            const sb = symbol.asSymbol(b);
            break :blk nsNameOrder(sa.ns, sa.name, sb.ns, sb.name);
        },
        // `.vector` (+ `.map_entry`) handled by the vector-like branch above.
        // java.time temporal values (D-462) compare by their fields.
        .typed_instance => try temporalOrder(rt, a, b, loc),
        // lists / maps / sets / fns etc. are not Comparable (JVM throws).
        else => raiseUncomparable(loc, a),
    };
}
