// SPDX-License-Identifier: EPL-2.0
//! Cross-type numeric dispatch + auto-promotion paths per F-005
//! and ROADMAP §9.7 / 5.10.
//!
//! Phase 5.10.a scope: Long ↔ BigInt promotion for `+ - *`. The
//! `/` integer/integer → Ratio path lives in `divPromoting` (Phase
//! 5.10.b); Ratio / BigDecimal cross-mixed cases land later as the
//! `(* 1/2 0.5)` kind of expressions become Clojure-reachable.
//!
//! Float-contagion follows JVM Clojure: any float operand makes the
//! result float (precision loss accepted). i48 overflow (cw v1's
//! immediate-Long boundary) silently promotes to BigInt — never to
//! float — matching the JVM behaviour for `+'` / `-'` / `*'` rather
//! than the unchecked `+` / `-` / `*` (Phase 5.10 ROADMAP text:
//! "Long overflow (i48 boundary) silently promotes to BigInt for
//! + / - / *"). The "raise on overflow" `+'` family lands at 5.10.c.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const big_int = @import("big_int.zig");
const nb = @import("../value/nan_box.zig");

const Managed = std.math.big.int.Managed;

fn inI48(x: i64) bool {
    return x >= nb.NB_I48_MIN and x <= nb.NB_I48_MAX;
}

fn toF64(rt: *Runtime, v: Value) f64 {
    if (v.isFloat()) return v.asFloat();
    if (v.isInt()) return @floatFromInt(@as(i64, v.asInteger()));
    if (v.tag() == .big_int) {
        // Lossy: BigInt → f64. Acceptable for float-contagious paths
        // where the user already opted into float semantics.
        return managedToF64(rt, big_int.asManaged(v));
    }
    return 0.0; // unreachable for caller that ran ensureNumeric
}

fn managedToF64(rt: *Runtime, m: *const Managed) f64 {
    // Best-effort conversion. For Phase 5.10.a, fall back to
    // toString + parseFloat. The lossy nature is a Clojure feature
    // (float-contagion semantics); Phase 17 may specialise.
    const s = m.toString(rt.gc.infra, 10, .lower) catch return 0.0;
    defer rt.gc.infra.free(s);
    return std.fmt.parseFloat(f64, s) catch 0.0;
}

/// Allocate a Managed on `rt.gc.infra` initialised from `v`. Caller
/// owns and must `deinit` the returned Managed.
fn coerceToManaged(rt: *Runtime, v: Value) !Managed {
    if (v.isInt()) {
        var m = try Managed.init(rt.gc.infra);
        errdefer m.deinit();
        try m.set(@as(i64, v.asInteger()));
        return m;
    }
    if (v.tag() == .big_int) {
        return try big_int.asManaged(v).cloneWithDifferentAllocator(rt.gc.infra);
    }
    return error.NotAnInteger;
}

/// Wrap an i64 result as a Value, choosing immediate-Long
/// (`Value.initInteger`) when it fits in i48, else BigInt.
fn wrapI64(rt: *Runtime, x: i64) !Value {
    if (inI48(x)) return Value.initInteger(x);
    var m = try Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.set(x);
    return try big_int.allocFromManaged(rt, &m);
}

/// `a + b` with auto-promotion. Both inputs MUST be numeric (caller
/// runs `ensureNumeric` first).
pub fn addPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) + toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const sum, const overflowed = @addWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, sum);
        // i64 overflow: must go to BigInt.
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocAddManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocAddManaged(rt, &am, &bm);
}

/// `a - b` with auto-promotion.
pub fn subPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) - toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const diff, const overflowed = @subWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, diff);
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocSubManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocSubManaged(rt, &am, &bm);
}

/// `a * b` with auto-promotion.
pub fn mulPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) * toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const prod, const overflowed = @mulWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, prod);
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocMulManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocMulManaged(rt, &am, &bm);
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() Fixture {
        var fix: Fixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *Fixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "addPromoting (small + small) stays Long" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try addPromoting(&fix.rt, Value.initInteger(7), Value.initInteger(5));
    try testing.expect(v.tag() == .integer);
    try testing.expectEqual(@as(i48, 12), v.asInteger());
}

test "mulPromoting (Long * Long) overflowing i48 promotes to BigInt" {
    var fix = Fixture.init();
    defer fix.deinit();

    // i48 max = 2^47 - 1 = 140737488355327. Multiply by 2 -> 2^48,
    // exceeds i48 range.
    const a = Value.initInteger((1 << 47) - 1);
    const v = try mulPromoting(&fix.rt, a, Value.initInteger(2));
    try testing.expect(v.tag() == .big_int);
}

test "addPromoting (i64 overflow) reaches BigInt arithmetic correctly" {
    var fix = Fixture.init();
    defer fix.deinit();

    // i48 max + i48 max = ~2^48, overflows i48 but fits in i64,
    // still promotes to BigInt because wrapI64 sees inI48 fail.
    const a = Value.initInteger((1 << 47) - 1);
    const v = try addPromoting(&fix.rt, a, a);
    try testing.expect(v.tag() == .big_int);
    // Result = 2 * (2^47 - 1) = 2^48 - 2 = 281474976710654
    try testing.expectEqual(@as(i64, 281474976710654), try big_int.asManaged(v).toInt(i64));
}

test "subPromoting (BigInt - Long) returns BigInt" {
    var fix = Fixture.init();
    defer fix.deinit();

    // Build a BigInt that fits in i64 but not i48 by promoting.
    const big_v = try mulPromoting(&fix.rt, Value.initInteger((1 << 47) - 1), Value.initInteger(2));
    try testing.expect(big_v.tag() == .big_int);

    const v = try subPromoting(&fix.rt, big_v, Value.initInteger(1));
    try testing.expect(v.tag() == .big_int);
    // (2^48 - 2) - 1 = 2^48 - 3
    try testing.expectEqual(@as(i64, (1 << 48) - 3), try big_int.asManaged(v).toInt(i64));
}

test "addPromoting (Long + Float) is float-contagious" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try addPromoting(&fix.rt, Value.initInteger(3), Value.initFloat(0.25));
    try testing.expect(v.isFloat());
    try testing.expectEqual(@as(f64, 3.25), v.asFloat());
}
