//! Arithmetic + comparison primitives for the `rt/` namespace.
//!
//! Phase-2 surface (per ROADMAP §9.4 / 2.8): `+`, `-`, `*`, `=`,
//! `<`, `>`, `<=`, `>=`, plus `compare` for completeness.
//!
//! Numeric tower: Phase-2 deals with i48 (the NaN-boxing range) and
//! f64. Mixed-type calls widen to f64 — Clojure's contagion rule.
//! Integer overflow promotes to float automatically because
//! `Value.initInteger` falls back to `initFloat` outside the i48
//! window (see `runtime/value.zig`).
//!
//! Division (Ratio) and mod / rem ship in Phase 5+ alongside heap
//! support for Ratios.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const promote = @import("../../runtime/numeric/promote.zig");
const equal = @import("../../runtime/equal.zig");
const compare_mod = @import("../../runtime/compare.zig");
const random_mod = @import("../../runtime/random.zig");
const ratio_mod = @import("../../runtime/numeric/ratio.zig");
const big_int_mod = @import("../../runtime/numeric/big_int.zig");
const big_decimal_mod = @import("../../runtime/numeric/big_decimal.zig");
const parse_mod = @import("../../runtime/numeric/parse.zig");
const print_mod = @import("../../runtime/print.zig");
const string_mod = @import("../../runtime/collection/string.zig");

// --- numeric helpers ---

/// Convert any numeric Value to f64 (lossy for big_int / ratio /
/// big_decimal — Clojure float contagion). Caller must have
/// type-checked; a non-number returns 0.0. Shared by the comparison
/// f64 path and the `double`/`float` primitive (F-011).
fn toF64(v: Value) f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @floatFromInt(v.asInteger()),
        .char => @floatFromInt(v.asChar()),
        .big_int => big_int_mod.asManaged(v).toFloat(f64, .nearest_even)[0],
        .ratio => blk: {
            const r = v.decodePtr(*const ratio_mod.Ratio);
            break :blk r.numer.m.toFloat(f64, .nearest_even)[0] / r.denom.m.toFloat(f64, .nearest_even)[0];
        },
        .big_decimal => blk: {
            const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);
            const unscaled = bd.unscaled.m.toFloat(f64, .nearest_even)[0];
            break :blk unscaled * std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(bd.scale)));
        },
        else => 0.0, // caller has already type-checked
    };
}

fn ensureNumeric(args: []const Value, name: []const u8, loc: SourceLocation) !void {
    for (args) |v| {
        switch (v.tag()) {
            .integer, .float, .big_int, .ratio, .big_decimal => continue,
            else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(t) }),
        }
    }
}

// --- arithmetic ---

/// `(+ ...)` — 0 args → 0, 1 arg → identity, N args → fold via
/// `promote.addPromoting`. i48 overflow auto-promotes to BigInt
/// (per ROADMAP §9.7 / 5.10 + F-005); float is contagious.
pub fn plus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "+", loc);
    if (args.len == 0) return Value.initInteger(0);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.addPromoting(rt, acc, args[i]) catch |err| switch (err) {
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(- x ...)` — 1 arg negates; N args subtract from the first via
/// `promote.subPromoting`. 0 args is an error (matches Clojure).
pub fn minus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "-", loc);
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "-", .min = @as(usize, 1) });
    if (args.len == 1) {
        return promote.subPromoting(rt, Value.initInteger(0), args[0]) catch |err| switch (err) {
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.subPromoting(rt, acc, args[i]) catch |err| switch (err) {
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(* ...)` — 0 args → 1, 1 arg → identity, N args → fold via
/// `promote.mulPromoting`.
pub fn star(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "*", loc);
    if (args.len == 0) return Value.initInteger(1);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.mulPromoting(rt, acc, args[i]) catch |err| switch (err) {
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(+' ...)` — strict-integer addition. Raises on overflow rather
/// than promoting to BigInt. Mirrors JVM Clojure's `+'`.
pub fn plusStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "+'", loc);
    if (args.len == 0) return Value.initInteger(0);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.addStrict(rt, acc, args[i]) catch |err| switch (err) {
            error.IntegerOverflow => return error_catalog.raise(.integer_overflow, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(-' x ...)` — strict-integer subtraction.
pub fn minusStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "-'", loc);
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "-'", .min = @as(usize, 1) });
    if (args.len == 1) {
        return promote.subStrict(rt, Value.initInteger(0), args[0]) catch |err| switch (err) {
            error.IntegerOverflow => return error_catalog.raise(.integer_overflow, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.subStrict(rt, acc, args[i]) catch |err| switch (err) {
            error.IntegerOverflow => return error_catalog.raise(.integer_overflow, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(*' ...)` — strict-integer multiplication.
pub fn starStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "*'", loc);
    if (args.len == 0) return Value.initInteger(1);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.mulStrict(rt, acc, args[i]) catch |err| switch (err) {
            error.IntegerOverflow => return error_catalog.raise(.integer_overflow, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

/// `(/ ...)` — 1 arg returns `1/x` (matches Clojure); N args
/// divides the first by each subsequent. Integer / integer not
/// evenly divisible produces a Ratio; integer division by zero raises
/// divide_by_zero, but float division by zero yields IEEE ±Inf / NaN.
pub fn slash(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "/", loc);
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "/", .min = @as(usize, 1) });
    if (args.len == 1) {
        return promote.divPromoting(rt, Value.initInteger(1), args[0]) catch |err| switch (err) {
            error.DivideByZero => return error_catalog.raise(.divide_by_zero, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = promote.divPromoting(rt, acc, args[i]) catch |err| switch (err) {
            error.DivideByZero => return error_catalog.raise(.divide_by_zero, loc, .{}),
            error.NonTerminatingDecimal => return error_catalog.raise(.non_terminating_decimal, loc, .{}),
            else => return err,
        };
    }
    return acc;
}

// --- ratio accessors ---

/// `(numerator r)` — the numerator of a Ratio as an integer. JVM requires a
/// Ratio argument (a non-ratio raises), since only Ratio carries a numerator.
/// Matches clojure.core/numerator.
fn numerator(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("numerator", args, 1, loc);
    if (args[0].tag() != .ratio)
        return error_catalog.raise(.type_arg_not_ratio, loc, .{ .fn_name = "numerator", .actual = @tagName(args[0].tag()) });
    const r = args[0].decodePtr(*const ratio_mod.Ratio);
    return promote.wrapManaged(rt, r.numer.m);
}

/// `(denominator r)` — the denominator of a Ratio as an integer (always > 0,
/// per the Ratio sign-normalisation invariant). Matches clojure.core/denominator.
fn denominator(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("denominator", args, 1, loc);
    if (args[0].tag() != .ratio)
        return error_catalog.raise(.type_arg_not_ratio, loc, .{ .fn_name = "denominator", .actual = @tagName(args[0].tag()) });
    const r = args[0].decodePtr(*const ratio_mod.Ratio);
    return promote.wrapManaged(rt, r.denom.m);
}

/// `(rationalize x)` — convert to an exact rational. Integer / BigInt / Ratio
/// pass through; a float converts via its DECIMAL representation (so 0.1 →
/// 1/10, matching clojure.core/rationalize, not the exact binary fraction
/// 3602879701896397/36028797018963968). cw v1 floats render full-decimal
/// (no exponent), so the parse is just sign / integer / fractional digits:
/// numerator = the digits with the point removed, denominator = 10^(frac
/// digit count), then gcd-reduce. NaN / Inf raise.
fn rationalize(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("rationalize", args, 1, loc);
    const v = args[0];
    switch (v.tag()) {
        .integer, .big_int, .ratio => return v,
        .float => {},
        else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "rationalize", .actual = @tagName(t) }),
    }
    const f = v.asFloat();
    if (!std.math.isFinite(f))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "rationalize", .expected = "a finite number", .actual = "NaN or Infinity" });

    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "rationalize", .expected = "a float within decimal-render range", .actual = "out-of-range float" });

    // numerator digits = s with the '.' removed (sign retained); scale = the
    // number of fractional digits.
    var numbuf: [512]u8 = undefined;
    var nlen: usize = 0;
    var scale: usize = 0;
    if (std.mem.findScalar(u8, s, '.')) |dot| {
        @memcpy(numbuf[0..dot], s[0..dot]);
        nlen = dot;
        const frac = s[dot + 1 ..];
        @memcpy(numbuf[nlen .. nlen + frac.len], frac);
        nlen += frac.len;
        scale = frac.len;
    } else {
        @memcpy(numbuf[0..s.len], s);
        nlen = s.len;
    }

    var num_m = try big_int_mod.parseBase10(rt, numbuf[0..nlen]);
    defer num_m.deinit();
    if (scale == 0) return promote.wrapManaged(rt, &num_m);

    // denominator = 10^scale, written as "1" followed by `scale` zeros.
    var denbuf: [520]u8 = undefined;
    denbuf[0] = '1';
    @memset(denbuf[1 .. 1 + scale], '0');
    var den_m = try big_int_mod.parseBase10(rt, denbuf[0 .. 1 + scale]);
    defer den_m.deinit();

    if (try ratio_mod.allocFromManagedPair(rt, &num_m, &den_m)) |ratio_v| return ratio_v;
    return promote.wrapManaged(rt, &num_m);
}

// --- comparison ---

/// Run `pred` pairwise across `args`, short-circuiting on `false`.
/// Used by `<` / `>` / `<=` / `>=`.
/// True when `a` and `b` are in the SAME numeric category (int/big_int,
/// or ratio/ratio, or big_decimal/big_decimal) and neither is a float —
/// the pairs `compare.valueCompare` orders EXACTLY without hitting its
/// cross-category f64 fallback (which raises on big numbers). Mirrors
/// `compare.zig::numericOrder`'s same-category arms.
fn exactComparable(a: Value, b: Value) bool {
    const ta = a.tag();
    const tb = b.tag();
    const int_a = ta == .integer or ta == .big_int;
    const int_b = tb == .integer or tb == .big_int;
    if (int_a and int_b) return true;
    if (ta == .ratio and tb == .ratio) return true;
    if (ta == .big_decimal and tb == .big_decimal) return true;
    return false;
}

/// Pairwise numeric comparison for `< > <= >= ==`. Same-category big
/// numbers (BigInt / Ratio / BigDecimal — and plain int) compare EXACTLY
/// through the numeric tower (`opred` over `compare.valueCompare`); f64
/// would lose precision/sign (D-167). A float operand or a cross-category
/// pair takes the f64 path (`fpred` over `toF64`): float contagion +
/// correct IEEE NaN (every NaN comparison false, where a total Order maps
/// NaN to `.gt`). The exact cross-category combine ladder at huge
/// magnitude (e.g. Ratio vs Int) is the still-deferred D-014a tail — f64
/// there is a lossy approximation, not the old zeroing bug.
fn pairwise(
    rt: *Runtime,
    name: []const u8,
    args: []const Value,
    loc: SourceLocation,
    comptime fpred: fn (a: f64, b: f64) bool,
    comptime opred: fn (o: std.math.Order) bool,
) !Value {
    try ensureNumeric(args, name, loc);
    if (args.len < 2) return Value.true_val; // (< 1) and (<) are true in Clojure
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i - 1];
        const b = args[i];
        if (exactComparable(a, b)) {
            if (!opred(try compare_mod.valueCompare(rt, a, b, loc))) return Value.false_val;
        } else {
            if (!fpred(toF64(a), toF64(b))) return Value.false_val;
        }
    }
    return Value.true_val;
}

fn pLT(a: f64, b: f64) bool {
    return a < b;
}
fn pGT(a: f64, b: f64) bool {
    return a > b;
}
fn pLE(a: f64, b: f64) bool {
    return a <= b;
}
fn pGE(a: f64, b: f64) bool {
    return a >= b;
}
fn pEQ(a: f64, b: f64) bool {
    return a == b;
}
// Order-domain mirrors of the f64 predicates (the exact-comparison path).
fn oLT(o: std.math.Order) bool {
    return o == .lt;
}
fn oGT(o: std.math.Order) bool {
    return o == .gt;
}
fn oLE(o: std.math.Order) bool {
    return o != .gt;
}
fn oGE(o: std.math.Order) bool {
    return o != .lt;
}
fn oEQ(o: std.math.Order) bool {
    return o == .eq;
}

/// `(= ...)` — universal value equality (= `clojure.lang.Util.equiv`).
/// All args must equal the first (transitive). Never raises on type
/// mismatch — see `runtime/equal.zig` + ADR-0052.
pub fn equals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    if (args.len < 2) return Value.true_val; // (=) and (= x) are true
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (!try equal.valueEqual(rt, env, args[0], args[i])) return Value.false_val;
    }
    return Value.true_val;
}

/// `(== ...)` — numeric-tower equivalence (= `clojure.lang.Numbers.equiv`).
/// Numeric-only (raises on non-numbers); widens across categories, so
/// `(== 1 1.0)` → true (where `(= 1 1.0)` → false). ADR-0052.
pub fn equiv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return pairwise(rt, "==", args, loc, pEQ, oEQ);
}

pub fn lt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return pairwise(rt, "<", args, loc, pLT, oLT);
}
pub fn gt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return pairwise(rt, ">", args, loc, pGT, oGT);
}
pub fn le(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return pairwise(rt, "<=", args, loc, pLE, oLE);
}
pub fn ge(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return pairwise(rt, ">=", args, loc, pGE, oGE);
}

/// `(compare x y)` — general 3-way comparison returning -1 / 0 / 1
/// (= `clojure.lang.Util.compare`). See `runtime/compare.zig` + ADR-0053.
pub fn compare(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len != 2)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "compare", .got = args.len, .expected = @as(usize, 2) });
    const order = try compare_mod.valueCompare(rt, args[0], args[1], loc);
    const c: i64 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return Value.initInteger(c);
}

/// `(inc x)` — returns `(+ x 1)`. Matches clojure.core/inc.
/// Delegates to `plus` so all promotion rules (Long → BigInt
/// on overflow, Long → Float on contagion etc.) apply.
pub fn inc(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("inc", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(1) };
    return plus(rt, env, &pair, loc);
}

/// `(dec x)` — returns `(- x 1)`. Matches clojure.core/dec.
pub fn dec(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("dec", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(1) };
    return minus(rt, env, &pair, loc);
}

/// `(inc' x) ≡ (+' x 1)`. Strict variant: raises integer_overflow
/// instead of promoting Long to BigInt.
pub fn incStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("inc'", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(1) };
    return plusStrict(rt, env, &pair, loc);
}

/// `(dec' x) ≡ (-' x 1)`. Strict variant — see `inc'`.
pub fn decStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("dec'", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(1) };
    return minusStrict(rt, env, &pair, loc);
}

/// `(zero? x) ≡ (== x 0)`. Delegates to numeric `==` (not `=`) so that
/// `(zero? 0.0)` is true — `=` distinguishes Long 0 from Double 0.0
/// (clj parity), but `zero?` is a numeric test. Non-numbers throw, as
/// in clj. All numeric arms (Long / Float / BigInt / Ratio / BigDecimal).
pub fn zeroQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("zero?", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(0) };
    return equiv(rt, env, &pair, loc);
}

/// `(pos? x) ≡ (> x 0)`.
pub fn posQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("pos?", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(0) };
    return gt(rt, env, &pair, loc);
}

/// `(neg? x) ≡ (< x 0)`.
pub fn negQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("neg?", args, 1, loc);
    const pair = [_]Value{ args[0], Value.initInteger(0) };
    return lt(rt, env, &pair, loc);
}

/// `(odd? x)` — true iff `x` is an odd integer. Delegates to `parity`
/// (Long bottom-bit + BigInt least-significant-limb). Non-integer
/// raises `type_arg_not_integer` (matches JVM Clojure's
/// IllegalArgumentException narrowed to cw's catalog).
pub fn oddQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("odd?", args, 1, loc);
    return if (try parity(args[0], "odd?", loc)) .true_val else .false_val;
}

/// `(even? x)` — true iff `x` is an even integer. See `odd?`.
pub fn evenQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("even?", args, 1, loc);
    return if (try parity(args[0], "even?", loc)) .false_val else .true_val;
}

/// True iff integer `v` is odd. Long uses the bottom bit; BigInt reads
/// the least-significant limb's bit 0 (big.int is sign-magnitude, so
/// parity is sign-independent). Non-integer raises type_arg_not_integer.
fn parity(v: Value, name: []const u8, loc: SourceLocation) !bool {
    if (v.tag() == .big_int) {
        const m = big_int_mod.asManaged(v);
        return (m.limbs[0] & 1) != 0;
    }
    const n = try error_catalog.expectInteger(v, name, loc);
    return (n & 1) != 0;
}

/// `(abs x)` — clojure.core/abs (1.11+). Returns |x| for any
/// numeric. Implemented by `(if (neg? x) (- 0 x) x)` so the
/// existing numeric comparison + subtraction ladder applies
/// to every Tag (Long / Float / BigInt / Ratio / BigDecimal).
pub fn abs(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("abs", args, 1, loc);
    const zero = Value.initInteger(0);
    const lt_pair = [_]Value{ args[0], zero };
    const is_neg = try lt(rt, env, &lt_pair, loc);
    if (is_neg == Value.true_val) {
        const sub_pair = [_]Value{ zero, args[0] };
        return minus(rt, env, &sub_pair, loc);
    }
    return args[0];
}

/// Map the shared numeric-tower errors a quot/rem/mod helper can raise
/// onto user-facing catalog errors (F-011: one translation, three sites).
fn raiseTowerDivError(name: []const u8, err: anyerror, loc: SourceLocation) anyerror {
    _ = name;
    return switch (err) {
        error.DivideByZero => error_catalog.raise(.divide_by_zero, loc, .{}),
        error.NonTerminatingDecimal => error_catalog.raise(.non_terminating_decimal, loc, .{}),
        else => err,
    };
}

/// `(quot a b)` — truncating division toward zero, across the numeric
/// tower (Long / BigInt / Ratio / Float). Matches clojure.core/quot via
/// `promote.quotPromoting`. Divide-by-zero raises for every category.
pub fn quot(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("quot", args, 2, loc);
    try ensureNumeric(args, "quot", loc);
    return promote.quotPromoting(rt, args[0], args[1]) catch |err| raiseTowerDivError("quot on BigDecimal", err, loc);
}

/// `(rem a b)` — remainder with sign matching the dividend
/// (Java `%` semantics, NOT floor-mod). Matches clojure.core/rem across
/// the tower via `promote.remPromoting`.
pub fn rem(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("rem", args, 2, loc);
    try ensureNumeric(args, "rem", loc);
    return promote.remPromoting(rt, args[0], args[1]) catch |err| raiseTowerDivError("rem on BigDecimal", err, loc);
}

/// `(mod a b)` — floor-mod: result has the same sign as the
/// divisor. Matches clojure.core/mod across the tower via
/// `promote.modPromoting` (differs from `rem` by the sign-correction rule).
pub fn mod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("mod", args, 2, loc);
    try ensureNumeric(args, "mod", loc);
    return promote.modPromoting(rt, args[0], args[1]) catch |err| raiseTowerDivError("mod on BigDecimal", err, loc);
}

/// `(bit-and a b)` — bitwise AND on two integers.
pub fn bitAnd(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-and", args, 2, loc);
    const a = try error_catalog.expectI64(args[0], "bit-and", loc);
    const b = try error_catalog.expectI64(args[1], "bit-and", loc);
    return promote.wrapI64(rt, a & b);
}

/// `(bit-or a b)` — bitwise OR on two integers.
pub fn bitOr(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-or", args, 2, loc);
    const a = try error_catalog.expectI64(args[0], "bit-or", loc);
    const b = try error_catalog.expectI64(args[1], "bit-or", loc);
    return promote.wrapI64(rt, a | b);
}

/// `(bit-xor a b)` — bitwise XOR on two integers.
pub fn bitXor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-xor", args, 2, loc);
    const a = try error_catalog.expectI64(args[0], "bit-xor", loc);
    const b = try error_catalog.expectI64(args[1], "bit-xor", loc);
    return promote.wrapI64(rt, a ^ b);
}

/// `(bit-not x)` — bitwise NOT (logical complement) on an integer.
/// In Clojure / Java this is the two's-complement negation pattern
/// `~x = -x - 1`.
pub fn bitNot(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-not", args, 1, loc);
    const a = try error_catalog.expectI64(args[0], "bit-not", loc);
    return promote.wrapI64(rt, ~a);
}

/// `(bit-shift-left x n)` — shifts `x` left by `n` bits. JVM Clojure
/// uses only the low 6 bits of `n` (Java spec); cw v1 mirrors that
/// to preserve the JVM identity `(bit-shift-left x 64) ≡ x`. The full
/// i64 result rides `wrapI64` (a value past i48 stays a heap Long, D-165).
pub fn bitShiftLeft(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-shift-left", args, 2, loc);
    const x = try error_catalog.expectI64(args[0], "bit-shift-left", loc);
    const n = try error_catalog.expectI64(args[1], "bit-shift-left", loc);
    const sh: u6 = @intCast(n & 0x3F);
    return promote.wrapI64(rt, x << sh);
}

/// `(bit-shift-right x n)` — arithmetic right shift (sign-extending).
pub fn bitShiftRight(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bit-shift-right", args, 2, loc);
    const x = try error_catalog.expectI64(args[0], "bit-shift-right", loc);
    const n = try error_catalog.expectI64(args[1], "bit-shift-right", loc);
    const sh: u6 = @intCast(n & 0x3F);
    return promote.wrapI64(rt, x >> sh);
}

/// `(unsigned-bit-shift-right x n)` — logical right shift (zero-fill).
pub fn unsignedBitShiftRight(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("unsigned-bit-shift-right", args, 2, loc);
    const x = try error_catalog.expectI64(args[0], "unsigned-bit-shift-right", loc);
    const n = try error_catalog.expectI64(args[1], "unsigned-bit-shift-right", loc);
    const sh: u6 = @intCast(n & 0x3F);
    const ux: u64 = @bitCast(x);
    const r: u64 = ux >> sh;
    return promote.wrapI64(rt, @bitCast(r));
}

/// `(min x & more)` — minimum across one or more numerics.
/// Folds via the existing `<` ladder so all promotion rules
/// (Long / Float / BigInt / Ratio / BigDecimal) apply.
pub fn min(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0) return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "min", .min = @as(usize, 1) });
    var best = args[0];
    for (args[1..]) |a| {
        const pair = [_]Value{ a, best };
        const is_lt = try lt(rt, env, &pair, loc);
        if (is_lt == Value.true_val) best = a;
    }
    return best;
}

/// `(max x & more)` — maximum across one or more numerics.
pub fn max(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0) return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "max", .min = @as(usize, 1) });
    var best = args[0];
    for (args[1..]) |a| {
        const pair = [_]Value{ a, best };
        const is_gt = try gt(rt, env, &pair, loc);
        if (is_gt == Value.true_val) best = a;
    }
    return best;
}

/// `(int x)` / `(long x)` — coerce to a Long across the numeric tower.
/// A float / BigDecimal / Ratio truncates toward zero; a char yields its
/// codepoint; an integer / BigInt passes through its value. cw v1 has a
/// single Long type so `int` and `long` share this body (no i32 narrowing
/// — see the no-i32-type divergence). The exact-integer result rides
/// `promote.wrapI64` so a value beyond i48 stays exact (D-165). A value
/// outside i64 range raises (JVM's out-of-range coercion error).
pub fn intCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("int", args, 1, loc);
    const v = args[0];
    const i = promote.truncToI64(rt, v) catch |err| switch (err) {
        error.OutOfRange => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "int", .expected = "a value within Long range", .actual = "out-of-range number" }),
        error.NotANumber => return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "int", .actual = @tagName(v.tag()) }),
        else => return err,
    };
    return promote.wrapI64(rt, i);
}

/// Shared body for `byte` / `short`: truncate toward zero (like `int`), then
/// range-check; clj throws IllegalArgumentException on overflow. cljw has no
/// distinct Byte/Short types (F-005 / ADR-0059), so the result is an ordinary
/// integer in range — `(class (byte 5))` is Long, an accepted divergence.
fn coerceRanged(rt: *Runtime, args: []const Value, comptime name: []const u8, lo: i64, hi: i64, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(name, args, 1, loc);
    const v = args[0];
    const i = promote.truncToI64(rt, v) catch |err| switch (err) {
        error.OutOfRange => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "a value within " ++ name ++ " range", .actual = "out-of-range number" }),
        error.NotANumber => return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(v.tag()) }),
        else => return err,
    };
    if (i < lo or i > hi)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "a value within " ++ name ++ " range", .actual = "out-of-range number" });
    return promote.wrapI64(rt, i);
}

/// `(byte x)` — coerce to a byte-range integer (-128..127). cw v1 tier: A.
pub fn byteCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return coerceRanged(rt, args, "byte", -128, 127, loc);
}

/// `(short x)` — coerce to a short-range integer (-32768..32767). cw v1 tier: A.
pub fn shortCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return coerceRanged(rt, args, "short", -32768, 32767, loc);
}

/// `(bigint x)` — coerce to an arbitrary-precision integer (`…N`). A BigInt
/// passes through; any other number truncates toward zero (int / float / ratio
/// / BigDecimal — e.g. `(bigint 3.9)`→`3N`, `(bigint 1/2)`→`0N`). Beyond Long
/// range (a large float) or a string is not yet coerced (D-191): those need a
/// double→arbitrary-int path and a BigInt string parser respectively.
/// JVM reference: clojure.core/bigint. cw v1 tier: A (§A26 sweep).
pub fn bigintCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bigint", args, 1, loc);
    const v = args[0];
    // `(bigint x)` ALWAYS yields a genuine BigInt (D-165): a heap-Long
    // (`(bigint (parse-long "999…"))`) re-flags to `.bigint` so it prints
    // `…N` / class BigInt; an already-`.bigint` passes through.
    if (v.tag() == .big_int) {
        return if (big_int_mod.originOf(v) == .bigint) v else big_int_mod.allocFromManaged(rt, big_int_mod.asManaged(v), .bigint);
    }
    if (v.tag() == .string) {
        // `(bigint "999…")` → arbitrary-precision N. parseBase10 accepts
        // `[-+]?ddd` and rejects `.` / `e` / non-digits, matching clj's
        // NumberFormatException on those. (D-047-safe: no setString.)
        const s = string_mod.asString(v);
        var m = big_int_mod.parseBase10(rt, s) catch
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "bigint", .text = s });
        defer m.deinit();
        return big_int_mod.allocFromManaged(rt, &m, .bigint);
    }
    const i = promote.truncToI64(rt, v) catch |err| switch (err) {
        error.OutOfRange => {
            // A float beyond Long range → clj's `bigdec(d).toBigInteger()`
            // (truncate toward zero). The mantissa is ≤17 digits so the
            // BigDecimal path is D-047-safe (no ≥2^64 setString).
            if (v.tag() == .float) return bigintFromFloat(rt, v.asFloat(), loc);
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "bigint", .expected = "a finite number", .actual = "out-of-range number" });
        },
        error.NotANumber => return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "bigint", .actual = @tagName(v.tag()) }),
        else => return err,
    };
    return big_int_mod.allocFromI64(rt, i, .bigint);
}

/// A float beyond Long range coerced to a BigInt: render via `printFloat` (cw's
/// `Double.toString`), parse to a BigDecimal, then truncate toward zero. Mirrors
/// clj `(bigint d) = bigdec(d).toBigInteger()`. NaN / Inf raise (no integer).
fn bigintFromFloat(rt: *Runtime, f: f64, loc: SourceLocation) anyerror!Value {
    if (!std.math.isFinite(f))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "bigint", .expected = "a finite number", .actual = "infinite or NaN float" });
    var fbuf: [400]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&fbuf);
    print_mod.printFloat(&fw, f) catch
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "bigint", .expected = "a representable float", .actual = "unrenderable float" });
    const bd = (try parseDecimalToBigDec(rt, fw.buffered())) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "bigint", .expected = "a representable float", .actual = "unparseable float" });
    return bigdecTruncToBigInt(rt, bd);
}

/// Truncate a BigDecimal toward zero into a BigInt. `value = unscaled·10^(−scale)`:
/// scale ≤ 0 multiplies by `10^(−scale)`, scale > 0 divides by `10^scale`
/// (`divTrunc` = round toward zero). Uses exact big-int `pow`/`mul`/`divTrunc`,
/// so it never touches the ≥2^64 `setString` D-047 path.
fn bigdecTruncToBigInt(rt: *Runtime, bd: Value) anyerror!Value {
    const infra = rt.gc.infra;
    const scale = big_decimal_mod.asScale(bd);
    var result = try big_decimal_mod.asUnscaled(bd).m.clone();
    defer result.deinit();
    if (scale != 0) {
        const exp: u32 = @intCast(@abs(scale));
        var ten = try std.math.big.int.Managed.initSet(infra, 10);
        defer ten.deinit();
        var pow10 = try std.math.big.int.Managed.init(infra);
        defer pow10.deinit();
        try pow10.pow(&ten, exp);
        if (scale < 0) {
            var prod = try std.math.big.int.Managed.init(infra);
            defer prod.deinit();
            try prod.mul(&result, &pow10);
            result.swap(&prod);
        } else {
            var q = try std.math.big.int.Managed.init(infra);
            defer q.deinit();
            var rmd = try std.math.big.int.Managed.init(infra);
            defer rmd.deinit();
            try q.divTrunc(&rmd, &result, &pow10);
            result.swap(&q);
        }
    }
    // `(bigint <large float>)` → a genuine BigInt (D-165).
    return big_int_mod.allocFromManaged(rt, &result, .bigint);
}

/// `(bigdec n/d)` — exact decimal of a Ratio, or ArithmeticException when the
/// expansion does not terminate (clj parity). A gcd-reduced `n/d` with `d > 0`
/// terminates iff `d = 2^a · 5^b`; then `scale = max(a, b)` and the unscaled
/// integer is `n · 5^(a−b)` (a ≥ b) or `n · 2^(b−a)` (b > a). A non-{2,5}
/// factor in `d` is non-terminating → `non_terminating_decimal`.
fn bigdecFromRatio(rt: *Runtime, v: Value, loc: SourceLocation) anyerror!Value {
    const r = v.decodePtr(*const ratio_mod.Ratio);
    return big_decimal_mod.allocFromRatioParts(rt, r.numer.m, r.denom.m) catch |err| switch (err) {
        error.NonTerminatingDecimal => error_catalog.raise(.non_terminating_decimal, loc, .{}),
        else => err,
    };
}

/// `(bigdec x)` — coerce to a BigDecimal (`…M`). A BigDecimal passes through;
/// an integer / BigInt becomes scale-0; a float reproduces JVM `(bigdec d)` =
/// `BigDecimal(Double.toString(d))` by rendering via `printFloat` (cw's
/// Double.toString, D-166) then parsing its plain-decimal form; a string parses
/// its plain-decimal form; a ratio yields its exact decimal (see
/// `bigdecFromRatio`). A scientific / >Long-unscaled float-string is deferred
/// (D-191). JVM reference: clojure.core/bigdec. cw v1 tier: A (§A26 sweep).
pub fn bigdecCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("bigdec", args, 1, loc);
    const v = args[0];
    switch (v.tag()) {
        .big_decimal => return v,
        .integer => return big_decimal_mod.allocFromI64Scale(rt, v.asInteger(), 0),
        .big_int => return big_decimal_mod.allocFromManagedScale(rt, big_int_mod.asManaged(v), 0),
        .float => {
            var fbuf: [400]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&fbuf);
            print_mod.printFloat(&fw, v.asFloat()) catch return bigdecDeferred(loc);
            return (try parseDecimalToBigDec(rt, fw.buffered())) orelse bigdecDeferred(loc);
        },
        .string => {
            // `(bigdec "1.50")` → `1.50M` (scale from the decimal point). A
            // scientific / >i64-unscaled / malformed string is a number-format
            // error (clj NumberFormatException). Ratio stays deferred (D-191).
            const s = string_mod.asString(v);
            return (try parseDecimalToBigDec(rt, s)) orelse
                error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "bigdec", .text = s });
        },
        .ratio => return bigdecFromRatio(rt, v, loc),
        else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "bigdec", .actual = @tagName(t) }),
    }
}

fn bigdecDeferred(loc: SourceLocation) anyerror {
    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "bigdec of a scientific/large float (D-191)" });
}

/// Parse a plain-decimal string (`[-]ddd[.ddd]`, no exponent) into a
/// BigDecimal: the digits (sans `.`) are the unscaled significand, the
/// fractional-digit count is the scale. Returns null for a scientific form or
/// a >Long unscaled (deferred to D-191).
/// Parse a plain-or-scientific decimal `[-]ddd[.ddd][eE][+-]ddd` into a
/// BigDecimal Value (arbitrary-precision unscaled, signed scale). Returns null
/// on malformed input (caller raises `number_format_invalid`). The unscaled
/// integer is the mantissa with the point removed; `scale = (#frac digits) −
/// exponent`, so `1.0E30` → unscaled 10, scale −29 — matching clj's
/// `BigDecimal(Double.toString d)`.
fn parseDecimalToBigDec(rt: *Runtime, s: []const u8) !?Value {
    var t = s;
    if (t.len == 0) return null;
    const sign_neg = t[0] == '-';
    if (t[0] == '-' or t[0] == '+') t = t[1..];
    if (t.len == 0) return null;

    // Split off an optional exponent.
    var mant = t;
    var exp: i64 = 0;
    if (std.mem.findScalar(u8, t, 'e') orelse std.mem.findScalar(u8, t, 'E')) |epos| {
        mant = t[0..epos];
        const exp_str = t[epos + 1 ..];
        if (exp_str.len == 0) return null;
        exp = std.fmt.parseInt(i64, exp_str, 10) catch return null;
    }
    if (mant.len == 0) return null;

    // Collect mantissa digits (drop the dot); count fractional digits.
    var digits: [512]u8 = undefined;
    var dlen: usize = 0;
    var frac: i64 = 0;
    var seen_dot = false;
    var any_digit = false;
    for (mant) |c| {
        if (c == '.') {
            if (seen_dot) return null;
            seen_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return null;
        if (dlen >= digits.len) return null; // pathologically wide — defer
        digits[dlen] = c;
        dlen += 1;
        any_digit = true;
        if (seen_dot) frac += 1;
    }
    if (!any_digit) return null;

    const scale_i64: i64 = frac - exp;
    if (scale_i64 > std.math.maxInt(i32) or scale_i64 < std.math.minInt(i32)) return null;

    var m = big_int_mod.parseBase10(rt, digits[0..dlen]) catch return null;
    defer m.deinit();
    if (sign_neg) m.negate();
    return try big_decimal_mod.allocFromManagedScale(rt, &m, @intCast(scale_i64));
}

/// `(char n)` — the character whose Unicode codepoint is the integer `n`
/// (0..0x10FFFF), or a char passed through.
pub fn charCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("char", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .char => v,
        .integer => blk: {
            const n = v.asInteger();
            if (n < 0 or n > 0x10FFFF)
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "char", .expected = "a codepoint in 0..0x10FFFF", .actual = "out-of-range integer" });
            break :blk Value.initChar(@intCast(n));
        },
        else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "char", .actual = @tagName(t) }),
    };
}

/// `(num x)` — coerce to a Number: identity for any numeric Value, type
/// error otherwise. Matches clojure.core/num (a Number cast on the JVM).
fn numCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("num", args, 1, loc);
    try ensureNumeric(args, "num", loc);
    return args[0];
}

/// `(double x)` / `(float x)` — coerce any number to a float (cw v1 has one
/// f64 float type, so both map to it). Matches clojure.core/double + /float.
/// Covers the whole numeric tower: integer / char (exact), big_int / ratio /
/// big_decimal (lossy, round-to-nearest — float-contagion is a Clojure
/// feature). Non-number is a type error.
fn floatCoerce(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("double", args, 1, loc);
    const v = args[0];
    switch (v.tag()) {
        .float, .integer, .char, .big_int, .ratio, .big_decimal => {},
        else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "double", .actual = @tagName(t) }),
    }
    return Value.initFloat(toF64(v)); // shared converter (F-011)
}

// --- string parsers (clojure.core 1.11) ---

/// `(parse-long s)` — parse a base-10 long from string `s`; `nil` if `s` is
/// not a valid long. A non-string argument is a type error (JVM parse-long
/// takes a CharSequence). The result collapses to a Long (i48) or BigInt.
fn parseLong(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("parse-long", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "parse-long", .actual = @tagName(args[0].tag()) });
    // Shared neutral leaf (F-011 DRY): same acceptance as Integer/parseInt
    // and Long/parseLong, so `(parse-long "1_000")` is nil like real clj
    // (Zig's bare parseInt would accept the `_` separator).
    const i = parse_mod.parseSigned(i64, string_mod.asString(args[0]), 10) catch return .nil_val;
    var m = try std.math.big.int.Managed.initSet(rt.gc.infra, i);
    defer m.deinit();
    return promote.wrapManaged(rt, &m);
}

/// `(parse-double s)` — parse a double from string `s`; `nil` if not valid.
fn parseDouble(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("parse-double", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "parse-double", .actual = @tagName(args[0].tag()) });
    // Shared neutral leaf (F-011 DRY): trims whitespace + rejects `_` like
    // Java Double.parseDouble, so `(parse-double " 3.14 ")` is 3.14 as in
    // real clj (Zig's bare parseFloat would reject the surrounding space).
    const f = parse_mod.parseFloat(string_mod.asString(args[0])) catch return .nil_val;
    return Value.initFloat(f);
}

/// `(parse-boolean s)` — `true` / `false` for the exact strings "true" /
/// "false"; `nil` for any other string. Non-string argument is a type error.
fn parseBoolean(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("parse-boolean", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "parse-boolean", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    if (std.mem.eql(u8, s, "true")) return .true_val;
    if (std.mem.eql(u8, s, "false")) return .false_val;
    return .nil_val;
}

/// `(rand-int n)` — a uniform random integer in [0, n). `n <= 0` → 0
/// (matches `(int (rand n))` for the degenerate cases). Uses the lazily-
/// seeded process PRNG (`runtime/random.zig`); non-deterministic by design.
pub fn randInt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("rand-int", args, 1, loc);
    const n = try error_catalog.expectInteger(args[0], "rand-int", loc);
    if (n <= 0) return Value.initInteger(0);
    const bound: i32 = if (n > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(n);
    return Value.initInteger(random_mod.nextIntBound(rt.io, bound));
}

/// `(rand)` — a uniform random double in [0, 1). `(rand n)` — in [0, n).
pub fn randFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "rand", .got = args.len, .min = 0, .max = 1 });
    const d = random_mod.nextDouble(rt.io);
    if (args.len == 1) {
        const scale: f64 = switch (args[0].tag()) {
            .float => args[0].asFloat(),
            .integer => @floatFromInt(args[0].asInteger()),
            else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "rand", .actual = @tagName(t) }),
        };
        return Value.initFloat(d * scale);
    }
    return Value.initFloat(d);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "+", .f = &plus },
    .{ .name = "-", .f = &minus },
    .{ .name = "*", .f = &star },
    .{ .name = "/", .f = &slash },
    .{ .name = "numerator", .f = &numerator },
    .{ .name = "denominator", .f = &denominator },
    .{ .name = "rationalize", .f = &rationalize },
    .{ .name = "+'", .f = &plusStrict },
    .{ .name = "-'", .f = &minusStrict },
    .{ .name = "*'", .f = &starStrict },
    .{ .name = "=", .f = &equals },
    .{ .name = "==", .f = &equiv },
    .{ .name = "<", .f = &lt },
    .{ .name = ">", .f = &gt },
    .{ .name = "<=", .f = &le },
    .{ .name = ">=", .f = &ge },
    .{ .name = "compare", .f = &compare },
    .{ .name = "inc", .f = &inc },
    .{ .name = "dec", .f = &dec },
    .{ .name = "inc'", .f = &incStrict },
    .{ .name = "dec'", .f = &decStrict },
    .{ .name = "zero?", .f = &zeroQ },
    .{ .name = "pos?", .f = &posQ },
    .{ .name = "neg?", .f = &negQ },
    .{ .name = "odd?", .f = &oddQ },
    .{ .name = "even?", .f = &evenQ },
    .{ .name = "abs", .f = &abs },
    .{ .name = "quot", .f = &quot },
    .{ .name = "rem", .f = &rem },
    .{ .name = "mod", .f = &mod },
    .{ .name = "bit-and", .f = &bitAnd },
    .{ .name = "bit-or", .f = &bitOr },
    .{ .name = "bit-xor", .f = &bitXor },
    .{ .name = "bit-not", .f = &bitNot },
    .{ .name = "bit-shift-left", .f = &bitShiftLeft },
    .{ .name = "bit-shift-right", .f = &bitShiftRight },
    .{ .name = "unsigned-bit-shift-right", .f = &unsignedBitShiftRight },
    .{ .name = "min", .f = &min },
    .{ .name = "max", .f = &max },
    .{ .name = "int", .f = &intCoerce },
    .{ .name = "byte", .f = &byteCoerce },
    .{ .name = "short", .f = &shortCoerce },
    // long ≡ int in cw v1 (a single i64 integer type — no 32-bit int).
    .{ .name = "long", .f = &intCoerce },
    .{ .name = "bigint", .f = &bigintCoerce },
    .{ .name = "bigdec", .f = &bigdecCoerce },
    .{ .name = "num", .f = &numCoerce },
    .{ .name = "double", .f = &floatCoerce },
    .{ .name = "float", .f = &floatCoerce },
    .{ .name = "char", .f = &charCoerce },
    .{ .name = "parse-long", .f = &parseLong },
    .{ .name = "parse-double", .f = &parseDouble },
    .{ .name = "parse-boolean", .f = &parseBoolean },
    .{ .name = "rand-int", .f = &randInt },
    .{ .name = "rand", .f = &randFn },
};

/// Register the math primitives into `rt_ns`.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "plus identity / nullary / multi-arg integer / float contagion" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 0), (try plus(&fix.rt, &fix.env, &.{}, .{})).asInteger());
    try testing.expectEqual(@as(i48, 6), (try plus(&fix.rt, &fix.env, &.{
        Value.initInteger(1),
        Value.initInteger(2),
        Value.initInteger(3),
    }, .{})).asInteger());
    try testing.expectApproxEqAbs(@as(f64, 3.5), (try plus(&fix.rt, &fix.env, &.{
        Value.initFloat(1.5),
        Value.initInteger(2),
    }, .{})).asFloat(), 1e-9);
}

test "minus: negation with one arg, subtraction with N" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, -5), (try minus(&fix.rt, &fix.env, &.{
        Value.initInteger(5),
    }, .{})).asInteger());
    try testing.expectEqual(@as(i48, 4), (try minus(&fix.rt, &fix.env, &.{
        Value.initInteger(10),
        Value.initInteger(3),
        Value.initInteger(3),
    }, .{})).asInteger());
    try testing.expectError(error.ArityError, minus(&fix.rt, &fix.env, &.{}, .{}));
}

test "star: nullary 1, multi-arg product" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 1), (try star(&fix.rt, &fix.env, &.{}, .{})).asInteger());
    try testing.expectEqual(@as(i48, 24), (try star(&fix.rt, &fix.env, &.{
        Value.initInteger(2),
        Value.initInteger(3),
        Value.initInteger(4),
    }, .{})).asInteger());
}

test "equals / lt / gt / le / ge — numeric pairwise" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const ones = [_]Value{ Value.initInteger(1), Value.initInteger(1) };
    try testing.expectEqual(Value.true_val, try equals(&fix.rt, &fix.env, &ones, .{}));

    const ascending = [_]Value{
        Value.initInteger(1),
        Value.initInteger(2),
        Value.initInteger(3),
    };
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &ascending, .{}));
    try testing.expectEqual(Value.true_val, try le(&fix.rt, &fix.env, &ascending, .{}));
    try testing.expectEqual(Value.false_val, try gt(&fix.rt, &fix.env, &ascending, .{}));

    const equal_run = [_]Value{
        Value.initInteger(2),
        Value.initInteger(2),
        Value.initInteger(2),
    };
    try testing.expectEqual(Value.true_val, try le(&fix.rt, &fix.env, &equal_run, .{}));
    try testing.expectEqual(Value.true_val, try ge(&fix.rt, &fix.env, &equal_run, .{}));
    try testing.expectEqual(Value.false_val, try lt(&fix.rt, &fix.env, &equal_run, .{}));

    // Trivial arities: (<) / (< 1) are true in Clojure.
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &.{}, .{}));
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &.{Value.initInteger(1)}, .{}));
}

test "compare returns -1 / 0 / 1" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const cases = [_]struct {
        a: i48,
        b: i48,
        want: i48,
    }{
        .{ .a = 1, .b = 2, .want = -1 },
        .{ .a = 2, .b = 2, .want = 0 },
        .{ .a = 3, .b = 2, .want = 1 },
    };
    for (cases) |c| {
        const args = [_]Value{ Value.initInteger(c.a), Value.initInteger(c.b) };
        try testing.expectEqual(c.want, (try compare(&fix.rt, &fix.env, &args, .{})).asInteger());
    }
}

test "non-numeric arg yields TypeError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const args = [_]Value{ Value.initInteger(1), .nil_val };
    try testing.expectError(error.TypeError, plus(&fix.rt, &fix.env, &args, .{}));
}

test "register installs every entry under rt/" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const rt_ns = fix.env.findNs("rt").?;
    try register(&fix.env, rt_ns);
    inline for (ENTRIES) |it| {
        try testing.expect(rt_ns.resolve(it.name) != null);
    }
}
