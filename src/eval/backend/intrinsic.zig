// SPDX-License-Identifier: EPL-2.0
//! Arithmetic / comparison intrinsic fast path (ADR-0130).
//!
//! The bytecode VM and the TreeWalk backend both route a 2-arg call to a
//! canonical `clojure.core` arithmetic/comparison Var through
//! `fastBinaryNumber` BEFORE the generic builtin dispatch. Sharing this single
//! function makes dual-backend parity (ADR-0036 / F-012) STRUCTURAL — there is
//! exactly one fast path, so the differential oracle cannot catch a
//! fast-path-vs-builtin divergence.
//!
//! `fastBinaryNumber` fires ONLY for two inline fixnums (`.integer`), or a
//! `.float` paired with a float or fixnum; anything else (ratio / bigint /
//! big-decimal / heap-Long / non-number) returns `null`, and the caller falls
//! back to the cached builtin Var via `vt.callFn` — identical to the generic
//! path, including the builtin's arg-precise error translation (F-011). The
//! float arm computes exactly what the builtins do once either operand is a
//! double: `promote.{add,sub,mul}Promoting` and `math.pairwise` both convert
//! to f64 and apply the IEEE op (O-065). add/sub/mul compute the result inline
//! (`@add/sub/mulWithOverflow` on i64); a result outside the i48 fixnum window
//! (i64 overflow OR > i48) returns `null` so the slow builtin path produces the
//! heap-Long / BigInt per F-005 — never a silent wrap, never a float.
//! Comparisons are exact i48 (`.integer` is always in-range). The WHOLE fast
//! path allocates nothing (overflow defers to the builtin), so the VM hot arith
//! op needs no GC `op_top` sync (the O-007 no-alloc-fast-path precedent; F-006).
//!
//! The compile-time recogniser (`opcodeFor`, gated on canonical-Var pointer
//! identity + the `core_arith_pristine` deopt flag) lands with the opcodes
//! themselves in a follow-up step; this module is the dispatch-side core.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const nb = @import("../../runtime/value/nan_box.zig");
const Opcode = @import("vm/opcode.zig").Opcode;
const env_mod = @import("../../runtime/env.zig");
const map_mod = @import("../../runtime/collection/map.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const sub_vector_mod = @import("../../runtime/collection/sub_vector.zig");

/// The intrinsifiable binary operations (ADR-0130 + am1). `/` stays absent
/// (integer `/` yields a Ratio / divide-by-zero raise — no fixnum fast path).
/// `=`/`not=` are INCLUDED but **fixnum-only**: two inline fixnums compare by
/// integer (in)equality (unambiguous); every other operand pair defers to the
/// builtin `=` / the `.clj` `not=` Var (which honour `(= 1 1.0)`→false, NaN,
/// value-equality across types). `not=` (op_ne, O-031) was intrinsic'd once the
/// sieve measurement showed its `.clj` `(not (= a b))` call is hot (~260 ns) —
/// the "rare in hot loops" rationale predated the perf campaign.
pub const ArithOp = enum { add, sub, mul, lt, le, gt, ge, eq, mod, rem, quot, ne };

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
        .mod => "mod",
        .rem => "rem",
        .quot => "quot",
        .ne => "not=",
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
        .mod => .op_mod,
        .rem => .op_rem,
        .quot => .op_quot,
        .ne => .op_ne,
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
        .op_mod => .mod,
        .op_rem => .rem,
        .op_quot => .quot,
        .op_ne => .ne,
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
        .op_mod => .op_mod_local_const,
        .op_rem => .op_rem_local_const,
        .op_quot => .op_quot_local_const,
        .op_ne => .op_ne_local_const,
        else => null,
    };
}

/// D-386 (O-018): the `ArithOp` a `*_local_const` opcode computes (the VM
/// dispatch arm reuses `fastBinaryNumber`). `null` for a non-fused opcode.
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
        .op_mod_local_const => .mod,
        .op_rem_local_const => .rem,
        .op_quot_local_const => .quot,
        .op_ne_local_const => .ne,
        else => null,
    };
}

/// D-386 (O-019): the `*_locals` (local-LOCAL) superinstruction variant of a
/// plain arith opcode. `null` for a non-arith opcode.
pub fn localsVariant(op: Opcode) ?Opcode {
    return switch (op) {
        .op_add => .op_add_locals,
        .op_sub => .op_sub_locals,
        .op_mul => .op_mul_locals,
        .op_lt => .op_lt_locals,
        .op_le => .op_le_locals,
        .op_gt => .op_gt_locals,
        .op_ge => .op_ge_locals,
        .op_eq => .op_eq_locals,
        .op_mod => .op_mod_locals,
        .op_rem => .op_rem_locals,
        .op_quot => .op_quot_locals,
        .op_ne => .op_ne_locals,
        else => null,
    };
}

/// D-386 (O-019): the `ArithOp` a `*_locals` opcode computes. `null` otherwise.
pub fn fromLocalsOpcode(op: Opcode) ?ArithOp {
    return switch (op) {
        .op_add_locals => .add,
        .op_sub_locals => .sub,
        .op_mul_locals => .mul,
        .op_lt_locals => .lt,
        .op_le_locals => .le,
        .op_gt_locals => .gt,
        .op_ge_locals => .ge,
        .op_eq_locals => .eq,
        .op_mod_locals => .mod,
        .op_rem_locals => .rem,
        .op_quot_locals => .quot,
        .op_ne_locals => .ne,
        else => null,
    };
}

/// D-386 (O-021): the branch superinstruction for a comparison-fused op — the
/// NEGATED form (jump_if_false branches on FALSE): eq→ne, lt→ge, le→gt. `null`
/// for a non-comparison-fused op (add/sub/mul; gt/ge have no fused branch).
pub fn branchVariant(op: Opcode) ?Opcode {
    return switch (op) {
        .op_eq_local_const => .op_branch_ne_local_const,
        .op_lt_local_const => .op_branch_ge_local_const,
        .op_le_local_const => .op_branch_gt_local_const,
        .op_eq_locals => .op_branch_ne_locals,
        .op_lt_locals => .op_branch_ge_locals,
        .op_le_locals => .op_branch_gt_locals,
        else => null,
    };
}

/// D-386 (O-021): for a branch superinstruction, the ORIGINAL comparison the VM
/// arm computes (then NEGATES — jump when the test is FALSE) + whether the 2nd
/// operand is a constant (vs a local). `null` for a non-branch opcode.
pub fn fromBranchOpcode(op: Opcode) ?struct { cmp: ArithOp, b_is_const: bool } {
    return switch (op) {
        .op_branch_ne_local_const => .{ .cmp = .eq, .b_is_const = true },
        .op_branch_ge_local_const => .{ .cmp = .lt, .b_is_const = true },
        .op_branch_gt_local_const => .{ .cmp = .le, .b_is_const = true },
        .op_branch_ne_locals => .{ .cmp = .eq, .b_is_const = false },
        .op_branch_ge_locals => .{ .cmp = .lt, .b_is_const = false },
        .op_branch_gt_locals => .{ .cmp = .le, .b_is_const = false },
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

// --- Unary inc/dec intrinsics (O-102) ---
//
// `(inc x)` / `(dec x)` were a generic op_get_var + op_call into the `inc`
// builtin, which re-enters `plus` with a 2-element slice: ~600 instructions
// per call against ~0 for the fused `(+ x 1)`. op_inc / op_dec run
// `fastUnary`; anything it declines defers to the cached Var, so the numeric
// tower, overflow promotion and errors stay the builtin's. Gated on
// `core_arith_pristine` like the binary family.

/// Index order MUST match `Runtime.unary_vars` (0=inc, 1=dec).
pub const UnaryOp = enum { inc, dec };

pub fn unaryCoreName(op: UnaryOp) []const u8 {
    return switch (op) {
        .inc => "inc",
        .dec => "dec",
    };
}

/// Compile-time recogniser for `inc`/`dec` (canonical Var pointer identity).
pub fn recognizeUnary(rt: *const Runtime, var_ptr: *const env_mod.Var) ?UnaryOp {
    for (rt.unary_vars, 0..) |cached, i| {
        const pv = cached orelse continue;
        if (@intFromPtr(pv) == @intFromPtr(var_ptr)) return @enumFromInt(i);
    }
    return null;
}

pub fn fromUnaryOpcode(op: Opcode) ?UnaryOp {
    return switch (op) {
        .op_inc => .inc,
        .op_dec => .dec,
        else => null,
    };
}

/// `(inc x)` / `(dec x)` fast path: an inline fixnum whose result stays in the
/// i48 window, or a float. `null` for everything else (heap Long, BigInt,
/// Ratio, BigDecimal, non-numbers, i48 edge) so the builtin handles it.
pub inline fn fastUnary(op: UnaryOp, a: Value) ?Value {
    const d: i64 = if (op == .inc) 1 else -1;
    if (a.tag() == .integer) {
        const res = @as(i64, a.asInteger()) + d;
        if (res < nb.NB_I48_MIN or res > nb.NB_I48_MAX) return null;
        return Value.initInteger(res);
    }
    if (a.tag() == .float) return Value.initFloat(a.asFloat() + @as(f64, @floatFromInt(d)));
    return null;
}

// --- Collection-accessor intrinsics (ADR-0130 extended; O-043) ---
//
// `op_get` (2-arg `(get coll k)`) and `op_nth` (3-arg `(nth coll i default)`)
// skip the `op_get_var` callee push + the generic `op_call` dispatch. The VM
// arm runs `fastGet` / `fastNth3` — a subset of the `get` / `nth` builtins that
// is PROVABLY EQUIVALENT for the cases it handles and returns `null` for every
// other case (so the VM defers to the cached builtin Var, identical to op_call).
// Like the arith family, the whole fast path allocates nothing, so the VM arm
// needs no GC `op_top` sync.

/// The intrinsifiable collection accessors. Index order MUST match
/// `Runtime.coll_vars` (0=get, 1=nth).
pub const CollOp = enum { get, nth };

pub const coll_count = @typeInfo(CollOp).@"enum".fields.len;

/// The `clojure.core` symbol each collection op resolves to (bootstrap caches).
pub fn collCoreName(op: CollOp) []const u8 {
    return switch (op) {
        .get => "get",
        .nth => "nth",
    };
}

pub fn collOpcode(op: CollOp) Opcode {
    return switch (op) {
        .get => .op_get,
        .nth => .op_nth,
    };
}

/// Compile-time recogniser for the collection accessors (pointer identity to a
/// cached canonical Var). A let-shadowed name is a `.local_ref` (never reaches
/// here); a later `alter-var-root` is handled by `core_coll_pristine`.
pub fn recognizeColl(rt: *const Runtime, var_ptr: *const env_mod.Var) ?CollOp {
    for (rt.coll_vars, 0..) |cached, i| {
        const pv = cached orelse continue;
        if (@intFromPtr(pv) == @intFromPtr(var_ptr)) return @enumFromInt(i);
    }
    return null;
}

/// 2-arg `(get coll k)` fast path. Handles the map + nil cases inline (the
/// destructure / map-read hot cases) EXACTLY as `getFn` does for a 2-arg call
/// (default = nil); returns `null` for every other collection kind so the VM
/// defers to the builtin (vector/set/string/transient/record/reify/…). Reads
/// only — allocates nothing.
pub fn fastGet(coll: Value, k: Value) !?Value {
    return switch (coll.tag()) {
        .nil => Value.nil_val,
        // PERF: `map_mod.get` already returns nil_val for an absent key — identical
        // to the 2-arg `(get coll k)` nil default — so the prior `contains`-then-`get`
        // pair scanned the map TWICE for the same result. One scan now (halves the
        // hot map-lookup work: `(get m :k)`, `:keys` destructure, gc_large_heap). [refs: O-048]
        .array_map, .hash_map => try map_mod.get(coll, k),
        else => null,
    };
}

/// 3-arg `(nth coll i default)` fast path. Handles the vector case inline
/// (destructure `(nth v i nil)`) EXACTLY as `nthFn`'s 3-arg vector arm: a
/// non-integer index defers (the builtin raises a type error even with a
/// default); an in-range index returns the element; out-of-range / negative
/// returns the default. Every non-vector collection defers. Reads only.
pub fn fastNth3(coll: Value, i_val: Value, default: Value) ?Value {
    const is_sub = coll.tag() == .sub_vector;
    if (coll.tag() != .vector and !is_sub) return null;
    if (i_val.tag() != .integer) return null;
    const idx = i_val.asInteger();
    if (idx < 0) return default;
    const n = if (is_sub) sub_vector_mod.count(coll) else vector_mod.count(coll);
    if (idx >= n) return default;
    return if (is_sub) sub_vector_mod.nth(coll, @intCast(idx)) else vector_mod.nth(coll, @intCast(idx));
}

/// 2-arg `(nth coll i)` fast path. Inlines an IN-RANGE vector index only —
/// every error case (OOB / negative / non-integer / non-vector / nil, which
/// 2-arg `nth` RAISES) returns `null` so the VM defers to the builtin for the
/// correct error (gc_alloc_rate's `(nth v 2)`). Reads only.
pub fn fastNth2(coll: Value, i_val: Value) ?Value {
    const is_sub = coll.tag() == .sub_vector;
    if (coll.tag() != .vector and !is_sub) return null;
    if (i_val.tag() != .integer) return null;
    const idx = i_val.asInteger();
    if (idx < 0) return null;
    const n = if (is_sub) sub_vector_mod.count(coll) else vector_mod.count(coll);
    if (idx >= n) return null;
    return if (is_sub) sub_vector_mod.nth(coll, @intCast(idx)) else vector_mod.nth(coll, @intCast(idx));
}

/// Binary arith/comparison fast path. Returns `null` unless the operands are
/// two inline fixnums or a float with a float/fixnum, so the caller defers
/// every other case (incl. all error cases) to the builtin.
// PERF: inline so the fixnum test and op switch fold into each VM arm; an
// out-of-line call (frame, canary, ?Value via memory) was ~20% of a loop [refs: O-101]
pub inline fn fastBinaryNumber(_: *Runtime, op: ArithOp, a: Value, b: Value) !?Value {
    if (a.tag() != .integer or b.tag() != .integer) return fastNonFixnum(op, a, b);
    return fastFixnum(op, a.asInteger(), b.asInteger());
}

/// Out of line so the fixnum dispatch in the VM's `stepOnce` keeps the shape it
/// had before the float arm existed.
// PERF: double arithmetic inline instead of the `+`/`*`/`<` builtin call (one is a float here) [refs: O-065]
noinline fn fastNonFixnum(op: ArithOp, a: Value, b: Value) ?Value {
    const at = a.tag();
    const bt = b.tag();
    if ((at == .float or at == .integer) and (bt == .float or bt == .integer)) return fastFloat(op, asF64(a), asF64(b));
    return null;
}

/// An inline fixnum or float as f64 (`promote.toF64` for these two tags).
fn asF64(v: Value) f64 {
    return if (v.tag() == .float) v.asFloat() else @floatFromInt(@as(i64, v.asInteger()));
}

/// The double arm: `initFloat` canonicalises a NaN result the way the builtins'
/// `initFloat` does. `=`/`not=` defer: clj `=` is false across categories
/// (`(= 1 1.0)`) and the builtin owns that rule. `mod`/`rem`/`quot` defer: their
/// float semantics (sign of zero, truncation) live in the builtin.
fn fastFloat(op: ArithOp, x: f64, y: f64) ?Value {
    return switch (op) {
        .add => Value.initFloat(x + y),
        .sub => Value.initFloat(x - y),
        .mul => Value.initFloat(x * y),
        .lt => Value.initBoolean(x < y),
        .le => Value.initBoolean(x <= y),
        .gt => Value.initBoolean(x > y),
        .ge => Value.initBoolean(x >= y),
        .eq, .ne, .mod, .rem, .quot => null,
    };
}

fn fastFixnum(op: ArithOp, ai: i64, bi: i64) ?Value {
    const res: i64, const ov: u1 = switch (op) {
        .add => @addWithOverflow(ai, bi),
        .sub => @subWithOverflow(ai, bi),
        .mul => @mulWithOverflow(ai, bi),
        .lt => return Value.initBoolean(ai < bi),
        .le => return Value.initBoolean(ai <= bi),
        .gt => return Value.initBoolean(ai > bi),
        .ge => return Value.initBoolean(ai >= bi),
        .eq => return Value.initBoolean(ai == bi),
        // `not=` (op_ne) — fixnum-only fast path; the non-(fixnum,fixnum) case
        // defers to the cached `not=` Var (.clj `(not (= a b))`, full value-equality
        // incl. `(not= 1 1.0)`→true). Mirrors `.eq`. [refs: O-031]
        .ne => return Value.initBoolean(ai != bi),
        // mod/rem/quot: fast path fires ONLY for a positive divisor (the hot case
        // — e.g. the sieve's `(mod x p)`, p prime > 0). Non-positive divisor defers
        // (`null`): bi==0 → the builtin raises divide_by_zero with the arg-precise
        // caret; bi<0 → the builtin computes the correct sign (avoids relying on
        // Zig `@mod`/`@rem` negative-denominator semantics AND the `@divTrunc(i48min,
        // -1)` i64-overflow corner — both excluded by bi>0). For bi>0 the mapping is
        // exact (clj `mod`=floored=@mod, `rem`=truncated=@rem, `quot`=trunc-div=
        // @divTrunc) and EVERY result fits i48 (|@mod|,|@rem| < bi ≤ i48max;
        // |@divTrunc| ≤ |ai| ≤ i48max), so the shared window check below is a no-op
        // safety net, never a defer, on this path.
        .mod => if (bi <= 0) return null else .{ @mod(ai, bi), 0 },
        .rem => if (bi <= 0) return null else .{ @rem(ai, bi), 0 },
        .quot => if (bi <= 0) return null else .{ @divTrunc(ai, bi), 0 },
    };
    // i64 overflow OR a result outside the i48 fixnum window → defer (null) to
    // the slow builtin path, which allocates the heap-Long / BigInt (D-165,
    // F-005). Keeping this fn ALLOC-FREE is what lets the VM hot arith path skip
    // the GC `op_top` sync under D-386 sub-step 2, and inlines past
    // `promote.*Promoting`'s float/ratio/bigdec type-dispatch on the hot case.
    // NB: `initInteger` returns a FLOAT out of i48 range, so the explicit window
    // check is required — a blind `initInteger(res)` would be wrong.
    if (ov != 0 or res < nb.NB_I48_MIN or res > nb.NB_I48_MAX) return null;
    return Value.initInteger(res);
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

test "fastBinaryNumber add/sub/mul on two fixnums" {
    var fix = Fixture.init();
    defer fix.deinit();
    const a = Value.initInteger(7);
    const b = Value.initInteger(5);
    try testing.expectEqual(@as(i48, 12), (try fastBinaryNumber(&fix.rt, .add, a, b)).?.asInteger());
    try testing.expectEqual(@as(i48, 2), (try fastBinaryNumber(&fix.rt, .sub, a, b)).?.asInteger());
    try testing.expectEqual(@as(i48, 35), (try fastBinaryNumber(&fix.rt, .mul, a, b)).?.asInteger());
}

test "fastBinaryNumber mul overflowing i48 defers (null) — slow path promotes" {
    var fix = Fixture.init();
    defer fix.deinit();
    const a = Value.initInteger((1 << 47) - 1); // i48 max
    // Overflowing i48 is no longer handled inline (the fast path is alloc-free);
    // it returns null so the slow builtin path produces the heap-Long / BigInt
    // (F-005). Observable `(* i48max 2)` → heap-Long is locked by the VM e2e +
    // diff oracle (TreeWalk already routes overflow through the builtin).
    try testing.expect((try fastBinaryNumber(&fix.rt, .mul, a, Value.initInteger(2))) == null);
}

test "fastBinaryNumber comparisons are exact" {
    var fix = Fixture.init();
    defer fix.deinit();
    const one = Value.initInteger(1);
    const two = Value.initInteger(2);
    try testing.expect((try fastBinaryNumber(&fix.rt, .lt, one, two)).? == Value.true_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .gt, one, two)).? == Value.false_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .le, two, two)).? == Value.true_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ge, one, two)).? == Value.false_val);
    // O-031: `=` / `not=` are mirror fixnum fast paths.
    try testing.expect((try fastBinaryNumber(&fix.rt, .eq, two, two)).? == Value.true_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ne, two, two)).? == Value.false_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ne, one, two)).? == Value.true_val);
}

test "fastBinaryNumber float arm: a double with a double or fixnum computes in f64 (O-065)" {
    var fix = Fixture.init();
    defer fix.deinit();
    const i = Value.initInteger(3);
    const f = Value.initFloat(1.5);
    // clj: (+ 3 1.5)=4.5 (- 1.5 3)=-1.5 (* 1.5 3)=4.5 (* 1.5 1.5)=2.25
    try testing.expectEqual(@as(f64, 4.5), (try fastBinaryNumber(&fix.rt, .add, i, f)).?.asFloat());
    try testing.expectEqual(@as(f64, -1.5), (try fastBinaryNumber(&fix.rt, .sub, f, i)).?.asFloat());
    try testing.expectEqual(@as(f64, 4.5), (try fastBinaryNumber(&fix.rt, .mul, f, i)).?.asFloat());
    try testing.expectEqual(@as(f64, 2.25), (try fastBinaryNumber(&fix.rt, .mul, f, f)).?.asFloat());
    // A double result stays a double even when integral: (+ 1.5 1.5)=3.0.
    try testing.expect((try fastBinaryNumber(&fix.rt, .add, f, f)).?.isFloat());
    // clj: (< 1.5 3)=true (>= 1.5 3)=false (<= 3 3.0)=true
    try testing.expect((try fastBinaryNumber(&fix.rt, .lt, f, i)).? == Value.true_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ge, f, i)).? == Value.false_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .le, i, Value.initFloat(3.0))).? == Value.true_val);
    // NaN: every ordering is false, arithmetic yields the canonical NaN.
    const nan = Value.initFloat(std.math.nan(f64));
    try testing.expect((try fastBinaryNumber(&fix.rt, .lt, nan, i)).? == Value.false_val);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ge, nan, i)).? == Value.false_val);
    try testing.expect(std.math.isNan((try fastBinaryNumber(&fix.rt, .add, nan, f)).?.asFloat()));
}

test "fastBinaryNumber defers (null) for equality, division family and non-numbers" {
    var fix = Fixture.init();
    defer fix.deinit();
    const i = Value.initInteger(3);
    const f = Value.initFloat(3.0);
    // (= 3 3.0) is false in clj; the builtin owns cross-category equality.
    try testing.expect((try fastBinaryNumber(&fix.rt, .eq, i, f)) == null);
    try testing.expect((try fastBinaryNumber(&fix.rt, .ne, f, f)) == null);
    try testing.expect((try fastBinaryNumber(&fix.rt, .quot, f, i)) == null);
    // A non-number operand defers so the builtin raises its arg-precise error.
    try testing.expect((try fastBinaryNumber(&fix.rt, .add, f, Value.nil_val)) == null);
    try testing.expect((try fastBinaryNumber(&fix.rt, .lt, Value.true_val, i)) == null);
}

test "fastBinaryNumber mod/rem/quot positive-divisor fast path matches clj" {
    var fix = Fixture.init();
    defer fix.deinit();
    const Case = struct { a: i48, b: i48, mod: i48, rem: i48, quot: i48 };
    // clj oracle (positive divisor only — the fast-path domain):
    //   (mod -7 3)=2 (rem -7 3)=-1 (quot -7 3)=-2 ; (quot 100 7)=14 ; (mod 0 5)=0
    const cases = [_]Case{
        .{ .a = -7, .b = 3, .mod = 2, .rem = -1, .quot = -2 },
        .{ .a = 7, .b = 3, .mod = 1, .rem = 1, .quot = 2 },
        .{ .a = 100, .b = 7, .mod = 2, .rem = 2, .quot = 14 },
        .{ .a = 0, .b = 5, .mod = 0, .rem = 0, .quot = 0 },
    };
    for (cases) |c| {
        const a = Value.initInteger(c.a);
        const b = Value.initInteger(c.b);
        try testing.expectEqual(c.mod, (try fastBinaryNumber(&fix.rt, .mod, a, b)).?.asInteger());
        try testing.expectEqual(c.rem, (try fastBinaryNumber(&fix.rt, .rem, a, b)).?.asInteger());
        try testing.expectEqual(c.quot, (try fastBinaryNumber(&fix.rt, .quot, a, b)).?.asInteger());
    }
}

test "fastBinaryNumber mod/rem/quot defer (null) on non-positive divisor + non-fixnum" {
    var fix = Fixture.init();
    defer fix.deinit();
    const seven = Value.initInteger(7);
    // divide-by-zero → null (builtin raises divide_by_zero with the arg caret)
    try testing.expect((try fastBinaryNumber(&fix.rt, .mod, seven, Value.initInteger(0)) == null));
    try testing.expect((try fastBinaryNumber(&fix.rt, .rem, seven, Value.initInteger(0)) == null));
    try testing.expect((try fastBinaryNumber(&fix.rt, .quot, seven, Value.initInteger(0)) == null));
    // negative divisor → null (builtin computes the correct sign; avoids the
    // @divTrunc(i48min,-1) i64-overflow corner + Zig negative-denominator semantics)
    try testing.expect((try fastBinaryNumber(&fix.rt, .mod, seven, Value.initInteger(-3)) == null));
    try testing.expect((try fastBinaryNumber(&fix.rt, .quot, Value.initInteger((-1) << 47), Value.initInteger(-1)) == null));
    // non-fixnum operand → null
    try testing.expect((try fastBinaryNumber(&fix.rt, .mod, seven, Value.initFloat(2.0)) == null));
}
