// SPDX-License-Identifier: EPL-2.0
//! Arithmetic / comparison intrinsic fast path (ADR-0130).
//!
//! The bytecode VM and the TreeWalk backend both route a 2-arg call to a
//! canonical `clojure.core` arithmetic/comparison Var through
//! `fastBinaryFixnum` BEFORE the generic builtin dispatch. Sharing this single
//! function makes dual-backend parity (ADR-0036 / F-012) STRUCTURAL — there is
//! exactly one fast path, so the differential oracle cannot catch a
//! fast-path-vs-builtin divergence.
//!
//! `fastBinaryFixnum` fires ONLY when both operands are inline fixnums
//! (`.integer`); anything else (float / ratio / bigint / heap-Long / non-number)
//! returns `null`, and the caller falls back to the cached builtin Var via
//! `vt.callFn` — identical to the generic path, including the builtin's
//! arg-precise error translation (F-011). add/sub/mul delegate to the existing
//! `promote.*Promoting` (i64 `@addWithOverflow` → `wrapI64`, so an i48 overflow
//! becomes a heap-Long / BigInt per F-005 — never a silent wrap, never a float).
//! Comparisons are exact i48 (`.integer` is always in-range). The non-overflow
//! integer path allocates nothing → no GC safepoint, no rooting (the O-007
//! no-alloc-fast-path precedent; F-006).
//!
//! The compile-time recogniser (`opcodeFor`, gated on canonical-Var pointer
//! identity + the `core_arith_pristine` deopt flag) lands with the opcodes
//! themselves in a follow-up step; this module is the dispatch-side core.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const promote = @import("../../runtime/numeric/promote.zig");
const Opcode = @import("vm/opcode.zig").Opcode;
const env_mod = @import("../../runtime/env.zig");

/// The intrinsifiable binary operations (ADR-0130 + am1). `/` stays absent
/// (integer `/` yields a Ratio / divide-by-zero raise — no fixnum fast path).
/// `=` is INCLUDED but **fixnum-only**: two inline fixnums compare by integer
/// equality (unambiguous); every other operand pair defers to the builtin `=`
/// (which honours `(= 1 1.0)`→false, NaN, value-equality across types). `not=`
/// is left to the builtin (it is `(not (= …))`, rare in hot loops).
pub const ArithOp = enum { add, sub, mul, lt, le, gt, ge, eq };

/// Stable index into `Runtime.arith_vars` (the per-op cached canonical Var).
pub const arith_count = @typeInfo(ArithOp).@"enum".fields.len;

/// The `clojure.core` symbol each op resolves to (bootstrap caches these).
pub fn coreName(op: ArithOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .eq => "=",
    };
}

pub fn toOpcode(op: ArithOp) Opcode {
    return switch (op) {
        .add => .op_add,
        .sub => .op_sub,
        .mul => .op_mul,
        .lt => .op_lt,
        .le => .op_le,
        .gt => .op_gt,
        .ge => .op_ge,
        .eq => .op_eq,
    };
}

pub fn fromOpcode(op: Opcode) ?ArithOp {
    return switch (op) {
        .op_add => .add,
        .op_sub => .sub,
        .op_mul => .mul,
        .op_lt => .lt,
        .op_le => .le,
        .op_gt => .gt,
        .op_ge => .ge,
        .op_eq => .eq,
        else => null,
    };
}

/// D-386 (O-018): the `*_local_const` superinstruction variant of a plain arith
/// opcode (op_add → op_add_local_const). The compiler emits this when an
/// intrinsic call's args are `(local-ref, const-literal)`. `null` for a
/// non-arith opcode.
pub fn localConstVariant(op: Opcode) ?Opcode {
    return switch (op) {
        .op_add => .op_add_local_const,
        .op_sub => .op_sub_local_const,
        .op_mul => .op_mul_local_const,
        .op_lt => .op_lt_local_const,
        .op_le => .op_le_local_const,
        .op_gt => .op_gt_local_const,
        .op_ge => .op_ge_local_const,
        .op_eq => .op_eq_local_const,
        else => null,
    };
}

/// D-386 (O-018): the `ArithOp` a `*_local_const` opcode computes (the VM
/// dispatch arm reuses `fastBinaryFixnum`). `null` for a non-fused opcode.
pub fn fromLocalConstOpcode(op: Opcode) ?ArithOp {
    return switch (op) {
        .op_add_local_const => .add,
        .op_sub_local_const => .sub,
        .op_mul_local_const => .mul,
        .op_lt_local_const => .lt,
        .op_le_local_const => .le,
        .op_gt_local_const => .gt,
        .op_ge_local_const => .ge,
        .op_eq_local_const => .eq,
        else => null,
    };
}

/// Compile-time recogniser: if `var_ptr` is a cached canonical arith Var, return
/// the opcode to emit. Pointer identity — a let-shadowed name is a `.local_ref`
/// (never reaches here); the runtime `core_arith_pristine` flag handles a later
/// `alter-var-root` on a core arith Var.
pub fn recognize(rt: *const Runtime, var_ptr: *const env_mod.Var) ?Opcode {
    for (rt.arith_vars, 0..) |cached, i| {
        const pv = cached orelse continue;
        if (@intFromPtr(pv) == @intFromPtr(var_ptr)) {
            return toOpcode(@enumFromInt(i));
        }
    }
    return null;
}

/// Fixnum fast path. Returns `null` unless BOTH operands are inline fixnums, so
/// the caller defers every other case (incl. all error cases) to the builtin.
pub fn fastBinaryFixnum(rt: *Runtime, op: ArithOp, a: Value, b: Value) !?Value {
    if (a.tag() != .integer or b.tag() != .integer) return null;
    return switch (op) {
        .add => try promote.addPromoting(rt, a, b),
        .sub => try promote.subPromoting(rt, a, b),
        .mul => try promote.mulPromoting(rt, a, b),
        .lt => Value.initBoolean(a.asInteger() < b.asInteger()),
        .le => Value.initBoolean(a.asInteger() <= b.asInteger()),
        .gt => Value.initBoolean(a.asInteger() > b.asInteger()),
        .ge => Value.initBoolean(a.asInteger() >= b.asInteger()),
        .eq => Value.initBoolean(a.asInteger() == b.asInteger()),
    };
}

// --- tests ------------------------------------------------------------------

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

test "fastBinaryFixnum add/sub/mul on two fixnums" {
    var fix = Fixture.init();
    defer fix.deinit();
    const a = Value.initInteger(7);
    const b = Value.initInteger(5);
    try testing.expectEqual(@as(i48, 12), (try fastBinaryFixnum(&fix.rt, .add, a, b)).?.asInteger());
    try testing.expectEqual(@as(i48, 2), (try fastBinaryFixnum(&fix.rt, .sub, a, b)).?.asInteger());
    try testing.expectEqual(@as(i48, 35), (try fastBinaryFixnum(&fix.rt, .mul, a, b)).?.asInteger());
}

test "fastBinaryFixnum mul overflowing i48 promotes (F-005), not a float" {
    var fix = Fixture.init();
    defer fix.deinit();
    const a = Value.initInteger((1 << 47) - 1); // i48 max
    const v = (try fastBinaryFixnum(&fix.rt, .mul, a, Value.initInteger(2))).?;
    try testing.expect(v.tag() == .big_int); // heap-Long / BigInt, never .float
}

test "fastBinaryFixnum comparisons are exact" {
    var fix = Fixture.init();
    defer fix.deinit();
    const one = Value.initInteger(1);
    const two = Value.initInteger(2);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .lt, one, two)).? == Value.true_val);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .gt, one, two)).? == Value.false_val);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .le, two, two)).? == Value.true_val);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .ge, one, two)).? == Value.false_val);
}

test "fastBinaryFixnum defers (null) when an operand is not an inline fixnum" {
    var fix = Fixture.init();
    defer fix.deinit();
    const i = Value.initInteger(3);
    const f = Value.initFloat(1.5);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .add, i, f)) == null);
    try testing.expect((try fastBinaryFixnum(&fix.rt, .add, f, i)) == null);
}
