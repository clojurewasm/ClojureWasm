// SPDX-License-Identifier: EPL-2.0
//! Host-interop instance methods on the `.big_int` value (java.math.BigInteger).
//! Real number-theory / crypto Clojure reaches these via the dot form:
//! `(.gcd a b)` / `(.modPow …)` / `(.pow n e)` / `(.sqrt n)`. Installs on the
//! per-Runtime `.big_int` native descriptor — the same `receiverDescriptor` →
//! `method_table` path String / Keyword / BigDecimal / Ratio interop uses.
//! Mirrors `ratio_methods.zig` (native-tag instance methods, no static surface).
//!
//! Backend: impl-only
//! Impl deps: none (std.math.big.int)
//! Clojure peer: none (clojure.core arithmetic auto-promotes; these are the
//! Java BigInteger method surface, distinct from the core fns).
//!
//! Every result stays a BigInteger (`.bigint`), matching JVM (a BigInteger method
//! never collapses to a Long) — so `allocFromManaged(.bigint)`, NOT the
//! Long-collapsing `promote.wrapManaged`. `(str …)` is identical either way.
//! `modPow` / `isProbablePrime` / `bitLength` are D-514.

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const type_descriptor = @import("type_descriptor.zig");
const big_int = @import("numeric/big_int.zig");
const Managed = std.math.big.int.Managed;

fn requireBigInt(v: Value, name: []const u8, loc: SourceLocation) !void {
    if (v.tag() != .big_int)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(v.tag()) });
}

/// `(.abs n)` — absolute value (JVM `BigInteger.abs`).
fn absFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("abs", args, 1, loc);
    var m = try big_int.asManaged(args[0]).clone();
    defer m.deinit();
    m.abs();
    return big_int.allocFromManaged(rt, &m, .bigint);
}

/// `(.negate n)` — arithmetic negation (JVM `BigInteger.negate`).
fn negateFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("negate", args, 1, loc);
    var m = try big_int.asManaged(args[0]).clone();
    defer m.deinit();
    m.negate();
    return big_int.allocFromManaged(rt, &m, .bigint);
}

/// `(.signum n)` — -1 / 0 / 1 (JVM `BigInteger.signum`).
fn signumFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = rt;
    try error_catalog.checkArity("signum", args, 1, loc);
    return Value.initInteger(switch (big_int.asManaged(args[0]).toConst().orderAgainstScalar(0)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

/// `(.gcd a b)` — greatest common divisor, non-negative (JVM `BigInteger.gcd`).
fn gcdFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("gcd", args, 2, loc);
    try requireBigInt(args[1], "gcd", loc);
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.gcd(big_int.asManaged(args[0]), big_int.asManaged(args[1]));
    return big_int.allocFromManaged(rt, &r, .bigint);
}

/// `(.pow n e)` — `n^e`, e ≥ 0 (JVM `BigInteger.pow(int)`).
fn powFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("pow", args, 2, loc);
    if (!args[1].isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "pow", .actual = "non-integer exponent" });
    const e = args[1].asInteger();
    if (e < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "pow", .expected = "a non-negative exponent", .actual = "a negative exponent" });
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.pow(big_int.asManaged(args[0]), @intCast(e));
    return big_int.allocFromManaged(rt, &r, .bigint);
}

/// `(.mod n m)` — floor-mod, result in [0, m) for m > 0 (JVM `BigInteger.mod`).
fn modFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("mod", args, 2, loc);
    try requireBigInt(args[1], "mod", loc);
    if (big_int.asManaged(args[1]).toConst().orderAgainstScalar(0) != .gt)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "mod", .expected = "a positive modulus", .actual = "a non-positive modulus" });
    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try q.divFloor(&r, big_int.asManaged(args[0]), big_int.asManaged(args[1])); // r sign = divisor sign (≥0)
    return big_int.allocFromManaged(rt, &r, .bigint);
}

/// `(.sqrt n)` — floor integer square root, n ≥ 0 (JVM `BigInteger.sqrt`).
fn sqrtFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("sqrt", args, 1, loc);
    if (big_int.asManaged(args[0]).toConst().orderAgainstScalar(0) == .lt)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "sqrt", .expected = "a non-negative value", .actual = "a negative value" });
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.sqrt(big_int.asManaged(args[0]));
    return big_int.allocFromManaged(rt, &r, .bigint);
}

/// `out = base^exp mod m` (exp ≥ 0, m > 0) via square-and-multiply, all on
/// `infra` Managed temporaries. Shared by `.modPow` and Miller-Rabin
/// (`.isProbablePrime`). `out` must be an initialised Managed (overwritten).
fn modPowManaged(infra: std.mem.Allocator, out: *Managed, base_in: *const Managed, exp_in: *const Managed, m: *const Managed) !void {
    try out.set(1);
    var base = try Managed.init(infra);
    defer base.deinit();
    var e = try exp_in.clone();
    defer e.deinit();
    var two = try Managed.initSet(infra, 2);
    defer two.deinit();
    var prod = try Managed.init(infra);
    defer prod.deinit();
    var ehalf = try Managed.init(infra);
    defer ehalf.deinit();
    var ebit = try Managed.init(infra);
    defer ebit.deinit();
    var sq = try Managed.init(infra);
    defer sq.deinit();

    try sq.divFloor(&base, base_in, m); // base = base_in mod m ∈ [0,m)
    while (e.toConst().orderAgainstScalar(0) == .gt) {
        try ehalf.divFloor(&ebit, &e, &two); // ehalf = e/2, ebit = e%2
        if (!ebit.eqlZero()) {
            try prod.mul(out, &base);
            try sq.divFloor(out, &prod, m); // out = out·base mod m
        }
        try prod.mul(&base, &base);
        try sq.divFloor(&base, &prod, m); // base = base² mod m
        e.swap(&ehalf);
    }
    try prod.copy(out.toConst());
    try sq.divFloor(out, &prod, m); // final reduce (handles m = 1 → 0)
}

/// `(.modPow n exp m)` — `n^exp mod m`, exp ≥ 0, m > 0 (JVM `BigInteger.modPow`).
/// (Negative exp = modular inverse — D-514.)
fn modPowFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("modPow", args, 3, loc);
    try requireBigInt(args[1], "modPow", loc);
    try requireBigInt(args[2], "modPow", loc);
    if (big_int.asManaged(args[2]).toConst().orderAgainstScalar(0) != .gt)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "modPow", .expected = "a positive modulus", .actual = "a non-positive modulus" });
    if (!big_int.asManaged(args[1]).toConst().positive)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "modPow", .expected = "a non-negative exponent", .actual = "a negative exponent" });
    var out = try Managed.init(rt.gc.infra);
    defer out.deinit();
    try modPowManaged(rt.gc.infra, &out, big_int.asManaged(args[0]), big_int.asManaged(args[1]), big_int.asManaged(args[2]));
    return big_int.allocFromManaged(rt, &out, .bigint);
}

/// `(.isProbablePrime n certainty)` — deterministic Miller-Rabin with the fixed
/// witness set {2,3,…,37}, which is EXACT for n < 3.3·10²⁴ and a strong
/// probable-prime test beyond (JVM `BigInteger.isProbablePrime`; cljw ignores
/// `certainty` — the deterministic witnesses are stronger than a round count and
/// avoid hidden randomness). Negative / 0 / 1 → false.
fn isProbablePrimeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isProbablePrime", args, 2, loc);
    const infra = rt.gc.infra;
    const nm = big_int.asManaged(args[0]);
    const ord2 = nm.toConst().orderAgainstScalar(2);
    if (ord2 == .lt) return Value.initBoolean(false); // n < 2
    if (ord2 == .eq or nm.toConst().orderAgainstScalar(3) == .eq) return Value.initBoolean(true); // 2 or 3

    var two = try Managed.initSet(infra, 2);
    defer two.deinit();
    var one = try Managed.initSet(infra, 1);
    defer one.deinit();
    var q = try Managed.init(infra);
    defer q.deinit();
    var rem = try Managed.init(infra);
    defer rem.deinit();
    try q.divFloor(&rem, nm, &two);
    if (rem.eqlZero()) return Value.initBoolean(false); // even, n > 3

    // n − 1 = 2^s · d  (d odd)
    var nminus1 = try nm.clone();
    defer nminus1.deinit();
    try nminus1.sub(&nminus1, &one);
    var d = try nminus1.clone();
    defer d.deinit();
    var s: usize = 0;
    while (true) {
        try q.divFloor(&rem, &d, &two);
        if (!rem.eqlZero()) break;
        d.swap(&q);
        s += 1;
    }

    var a = try Managed.init(infra);
    defer a.deinit();
    var x = try Managed.init(infra);
    defer x.deinit();
    var prod = try Managed.init(infra);
    defer prod.deinit();
    const witnesses = [_]u32{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (witnesses) |w| {
        try a.set(w);
        if (a.order(nm.*) != .lt) continue; // witness must be < n (small n)
        try modPowManaged(infra, &x, &a, &d, nm); // x = a^d mod n
        if (x.toConst().orderAgainstScalar(1) == .eq or x.order(nminus1) == .eq) continue;
        var composite = true;
        var i: usize = 0;
        while (i + 1 < s) : (i += 1) {
            try prod.mul(&x, &x);
            try q.divFloor(&x, &prod, nm); // x = x² mod n
            if (x.order(nminus1) == .eq) {
                composite = false;
                break;
            }
        }
        if (composite) return Value.initBoolean(false);
    }
    return Value.initBoolean(true);
}

/// `(.bitLength n)` — minimal two's-complement bit count excl. sign (JVM
/// `BigInteger.bitLength`): `bits(|n|)` for n ≥ 0, `bits(|n|-1)` for n < 0.
fn bitLengthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bitLength", args, 1, loc);
    const m = big_int.asManaged(args[0]);
    if (m.toConst().positive) // n ≥ 0 (std treats 0 as positive; bitCountAbs(0)=0)
        return Value.initInteger(@intCast(m.toConst().bitCountAbs()));
    var absm = try m.clone();
    defer absm.deinit();
    absm.abs();
    var one = try Managed.initSet(rt.gc.infra, 1);
    defer one.deinit();
    try absm.sub(&absm, &one); // |n| - 1
    return Value.initInteger(@intCast(absm.toConst().bitCountAbs()));
}

/// Populate the per-Runtime `.big_int` native descriptor's method table.
/// Idempotent. Called at runtime init alongside the other native installers.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.big_int);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "abs", &absFn },
        .{ "negate", &negateFn },
        .{ "signum", &signumFn },
        .{ "gcd", &gcdFn },
        .{ "pow", &powFn },
        .{ "mod", &modFn },
        .{ "sqrt", &sqrtFn },
        .{ "modPow", &modPowFn },
        .{ "bitLength", &bitLengthFn },
        .{ "isProbablePrime", &isProbablePrimeFn },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}
