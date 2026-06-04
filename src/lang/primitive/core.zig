//! Core predicate primitives for the `rt/` namespace.
//!
//! Phase-2 surface (per ROADMAP §9.4 / 2.9): `nil?`, `true?`,
//! `false?`, `identical?`. These are bit-level checks against the
//! NaN-boxed Value representation — no allocation, no vtable detour.
//!
//! `apply` and `type` need a heap-backed list and keyword-interning
//! through the runtime; they land in Phase 3+ once the analyser
//! handles those forms.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const higher_order = @import("higher_order.zig");
const tagged_literal_mod = @import("../../runtime/tagged_literal.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const string_mod = @import("../../runtime/collection/string.zig");
const equal_mod = @import("../../runtime/equal.zig");
const hash_mod = @import("../../runtime/hash.zig");
const sequence = @import("sequence.zig");
const list = @import("../../runtime/collection/list.zig");
const print_mod = @import("../../runtime/print.zig");
const charset_mod = @import("../../runtime/charset.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const class_name = @import("../../runtime/class_name.zig");
const host_class = @import("../../runtime/error/host_class.zig");
const driver = @import("../../eval/driver.zig");

/// `(__instance? 'Class x)` — row 7.12 cycle 1 Layer-2 primitive
/// backing the public `instance?` macro. The macro (registered in
/// `lang/macro_transforms.zig::expandInstanceQ`) auto-quotes the
/// Class argument so callers write `(instance? String x)` without an
/// explicit quote. Path A per the row 7.12 survey Q1 decision:
/// Symbol-based primitive-side lookup. Unknown class names raise
/// `class_name_unknown` (no silent-default-shift, per F-002 +
/// `provisional_marker.md` permanent-no-op-forbidden discipline).
/// Dispatches through `runtime/class_name.zig::isInstance` which
/// covers native tags + interface-shaped multi-tag sets + Throwable
/// hierarchy + user TypeDescriptor parent walk.
pub fn instanceQPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("instance?", args, 2, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "instance?",
            .expected = "symbol (class name)",
            .actual = @tagName(args[0].tag()),
        });
    }
    const class_sym = symbol_mod.asSymbol(args[0]).name;
    // class_name.isKnown covers native + interface + Throwable; user-
    // defined defrecord / deftype names live in `rt.types` and need
    // a separate check (row 7.13 cycle 1 — was the row 7.12 cycle 1
    // gap surfaced by `(instance? ZipLoc loc)` from clojure.zip).
    if (!class_name.isKnown(class_sym) and !rt.types.contains(class_sym))
        return error_catalog.raise(.class_name_unknown, loc, .{ .name = class_sym });
    return if (class_name.isInstance(args[1], class_sym)) .true_val else .false_val;
}

/// `(-class-isa? child parent)` — true iff both args are class values
/// (TypeDescriptor) and `child`'s class is `parent` or a subclass of it (the
/// host exception hierarchy via `host_class.isSubclassOf`). The class-hierarchy
/// arm of `isa?` (clj's `Class.isAssignableFrom` step); equality + the ad-hoc
/// `derive` hierarchy stay in the `.clj` `isa?`. Non-class args → false.
pub fn classIsaPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("-class-isa?", args, 2, loc);
    if (args[0].tag() != .type_descriptor or args[1].tag() != .type_descriptor)
        return .false_val;
    const child = td_mod.asTypeDescriptorRef(args[0]).fqcn orelse return .false_val;
    const parent = td_mod.asTypeDescriptorRef(args[1]).fqcn orelse return .false_val;
    if (std.mem.eql(u8, child, parent)) return .true_val;
    return if (host_class.isSubclassOf(host_class.normalizeClassName(child), host_class.normalizeClassName(parent)))
        .true_val
    else
        .false_val;
}

/// `(ifn? x)` — true iff `x` is callable (implements IFn): a fn / builtin /
/// multimethod / protocol-fn, OR a keyword / symbol / var / vector / map / set
/// (all invocable as lookups, clj parity). Spec: clojure.core/ifn?.
pub fn ifnQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ifn?", args, 1, loc);
    return switch (args[0].tag()) {
        .fn_val, .builtin_fn, .multi_fn, .protocol_fn, .keyword, .symbol, .var_ref, .vector, .array_map, .hash_map, .hash_set, .sorted_map, .sorted_set => .true_val,
        else => .false_val,
    };
}

/// `(thread-bound? & vars)` — true iff EVERY arg Var has an active thread
/// binding (a `binding` frame holds it). A non-Var arg raises (clj casts to
/// Var → ClassCastException). Spec: clojure.core/thread-bound?.
pub fn threadBoundQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 1)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "thread-bound?", .got = args.len, .min = 1 });
    for (args) |v| {
        if (v.tag() != .var_ref)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "thread-bound?", .expected = "var", .actual = @tagName(v.tag()) });
        if (env_mod.findBinding(v.decodePtr(*const env_mod.Var)) == null) return .false_val;
    }
    return .true_val;
}

/// `(bound? & vars)` — true iff EVERY arg Var has a value: an active thread
/// binding OR a root assigned via `(def x v)` (the `Var.bound` flag — a no-init
/// `(def x)` is NOT bound). A non-Var arg raises (clj casts). Spec:
/// clojure.core/bound?.
pub fn boundQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 1)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "bound?", .got = args.len, .min = 1 });
    for (args) |v| {
        if (v.tag() != .var_ref)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "bound?", .expected = "var", .actual = @tagName(v.tag()) });
        const var_ptr = v.decodePtr(*const env_mod.Var);
        if (env_mod.findBinding(var_ptr) == null and !var_ptr.bound) return .false_val;
    }
    return .true_val;
}

/// `(var? x)` — true iff `x` is a Var reference. Spec: clojure.core/var?.
pub fn varQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("var?", args, 1, loc);
    return if (args[0].tag() == .var_ref) .true_val else .false_val;
}

/// `(nil? x)` — true iff `x` is the singleton nil Value.
pub fn nilQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("nil?", args, 1, loc);
    return if (args[0].isNil()) .true_val else .false_val;
}

/// `(true? x)` — strict `true` test (NOT general truthiness — that's
/// `(if x ...)`'s job).
pub fn trueQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("true?", args, 1, loc);
    return if (args[0] == Value.true_val) .true_val else .false_val;
}

/// `(false? x)` — strict `false` test (the only false-tagged Value;
/// nil and other falsy values do **not** count).
pub fn falseQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("false?", args, 1, loc);
    return if (args[0] == Value.false_val) .true_val else .false_val;
}

/// `(identical? a b)` — bit equality on the underlying NaN-boxed u64.
/// Equivalent to Java `==` reference identity in Clojure JVM.
pub fn identicalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("identical?", args, 2, loc);
    return if (args[0] == args[1]) .true_val else .false_val;
}

/// `(string? x)` — true iff `x` is a String (clojure.core/string?).
pub fn stringQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("string?", args, 1, loc);
    return if (args[0].tag() == .string) .true_val else .false_val;
}

/// `(integer? x)` — true iff `x` is an integer (Long or BigInt;
/// matches clojure.core/integer? which excludes Ratio and
/// BigDecimal).
pub fn integerQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("integer?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .integer or t == .big_int) .true_val else .false_val;
}

/// `(number? x)` — true iff `x` is any numeric (Long / Float / BigInt
/// / Ratio / BigDecimal). Matches clojure.core/number?.
pub fn numberQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("number?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .integer or t == .float or t == .big_int or t == .ratio or t == .big_decimal) .true_val else .false_val;
}

/// `(symbol? x)` — true iff `x` is a Symbol Value.
pub fn symbolQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("symbol?", args, 1, loc);
    return if (args[0].tag() == .symbol) .true_val else .false_val;
}

/// `(keyword? x)` — true iff `x` is a Keyword Value.
pub fn keywordQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("keyword?", args, 1, loc);
    return if (args[0].tag() == .keyword) .true_val else .false_val;
}

/// `(vector? x)` — true iff `x` is a persistent Vector.
pub fn vectorQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("vector?", args, 1, loc);
    // A MapEntry IS-A vector (clj `MapEntry extends APersistentVector`,
    // D-209 / ADR-0078).
    const t = args[0].tag();
    return if (t == .vector or t == .map_entry) .true_val else .false_val;
}

/// Implements clojure.core/map-entry? — true only for a distinct MapEntry
/// (D-209 / ADR-0078): `(map-entry? (first {:a 1}))`→true, `(map-entry?
/// [1 2])`→false. The discriminator a 2-vector cannot provide.
pub fn mapEntryQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("map-entry?", args, 1, loc);
    return if (args[0].tag() == .map_entry) .true_val else .false_val;
}

/// `(list? x)` — true iff `x` is a persistent List
/// (NOT lazy-seq / cons / chunked-cons — those are `seq?` only).
pub fn listQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("list?", args, 1, loc);
    return if (args[0].tag() == .list) .true_val else .false_val;
}

/// `(map? x)` — true iff `x` is an array-map / hash-map / sorted-map.
pub fn mapQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("map?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .array_map or t == .hash_map or t == .sorted_map) .true_val else .false_val;
}

/// `(set? x)` — true iff `x` is a hash-set or sorted-set.
pub fn setQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("set?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .hash_set or t == .sorted_set) .true_val else .false_val;
}

/// Implements clojure.core/record?.
/// Spec: `(record? x)` returns true iff x is an instance of a
/// defrecord-declared type. cw v1 routes through `.typed_instance`
/// tag + `descriptor.kind == .defrecord` discrimination.
/// JVM reference: clojure.core/record? in clojure/core.clj — calls
/// `(instance? clojure.lang.IRecord x)`.
/// cw v1 tier: A (row 7.4 cycle 6).
pub fn recordQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("record?", args, 1, loc);
    if (args[0].tag() != .typed_instance) return .false_val;
    const inst = args[0].decodePtr(*const td_mod.TypedInstance);
    return if (inst.descriptor.kind == .defrecord) .true_val else .false_val;
}

/// `(fn? x)` — true iff `x` is callable as a function:
/// builtin_fn (NaN-box-immediate function pointer like `+`),
/// fn_val (user `(fn [...] ...)` closure), or multi_fn.
/// JVM Clojure's clojure.core/fn? tests `IFn` minus `Var` —
/// cw v1 mirrors the same intent at the Value.Tag layer.
pub fn fnQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("fn?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .builtin_fn or t == .fn_val or t == .multi_fn) .true_val else .false_val;
}

/// `(boolean? x)` — true iff `x` is one of the booleans `true` / `false`.
/// nil is NOT a boolean.
pub fn booleanQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("boolean?", args, 1, loc);
    return if (args[0] == Value.true_val or args[0] == Value.false_val) .true_val else .false_val;
}

/// `(char? x)` — true iff `x` is a Character (single Unicode codepoint).
pub fn charQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("char?", args, 1, loc);
    return if (args[0].tag() == .char) .true_val else .false_val;
}

/// `(float? x)` — true iff `x` is a double-precision float (IEEE-754
/// 64-bit). Matches clojure.core/float? (which on JVM returns true
/// for both Float and Double; cw v1 has only one float tag).
pub fn floatQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("float?", args, 1, loc);
    return if (args[0].tag() == .float) .true_val else .false_val;
}

/// `(ratio? x)` — true iff `x` is a Ratio (numer/denom pair of BigInts).
pub fn ratioQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ratio?", args, 1, loc);
    return if (args[0].tag() == .ratio) .true_val else .false_val;
}

/// `(decimal? x)` — true iff `x` is a BigDecimal. Matches
/// clojure.core/decimal?.
pub fn decimalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("decimal?", args, 1, loc);
    return if (args[0].tag() == .big_decimal) .true_val else .false_val;
}

/// `(NaN? x)` — true iff x is the float NaN. JVM `(NaN? ^double x)` coerces
/// its arg, so an integer is never-NaN (→ false) and a non-number is a type
/// error (the `(double x)` cast fails on JVM).
pub fn nanQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("NaN?", args, 1, loc);
    return switch (args[0].tag()) {
        .float => if (std.math.isNan(args[0].asFloat())) .true_val else .false_val,
        .integer => .false_val,
        else => |t| error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "NaN?", .actual = @tagName(t) }),
    };
}

/// `(infinite? x)` — true iff x is positive or negative float infinity.
/// Same coercion contract as `NaN?` (integer → false, non-number → error).
pub fn infiniteQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("infinite?", args, 1, loc);
    return switch (args[0].tag()) {
        .float => if (std.math.isInf(args[0].asFloat())) .true_val else .false_val,
        .integer => .false_val,
        else => |t| error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "infinite?", .actual = @tagName(t) }),
    };
}

/// `(some? x)` — true iff `x` is not nil. The non-nil counterpart of
/// `nil?`. Matches clojure.core/some?.
pub fn someQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("some?", args, 1, loc);
    return if (args[0].isNil()) .false_val else .true_val;
}

/// `(not x)` — Clojure truthiness inversion. Returns true when x is
/// nil or false; otherwise returns false. NOT a strict-true test
/// (see `false?` for that).
pub fn notFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("not", args, 1, loc);
    return if (args[0].isNil() or args[0] == Value.false_val) .true_val else .false_val;
}

/// `(coll? x)` — true iff `x` is any IPersistentCollection: list,
/// cons, lazy-seq, chunked-cons, vector, array-map, hash-map,
/// sorted-map, hash-set, sorted-set, persistent-queue, range,
/// string-seq, array-seq, map-entry. Matches clojure.core/coll?.
pub fn collQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("coll?", args, 1, loc);
    const t = args[0].tag();
    return switch (t) {
        .list, .cons, .lazy_seq, .chunked_cons, .vector, .array_map, .hash_map, .sorted_map, .hash_set, .sorted_set, .persistent_queue, .range, .string_seq, .array_seq, .map_entry => .true_val,
        else => .false_val,
    };
}

/// `(seq? x)` — true iff `x` implements ISeq: list, cons,
/// lazy-seq, chunked-cons, range, string-seq, array-seq.
/// vectors / maps / sets are NOT seqs in JVM Clojure
/// (they become a seq via `(seq coll)`).
pub fn seqQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("seq?", args, 1, loc);
    const t = args[0].tag();
    return switch (t) {
        .list, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq => .true_val,
        else => .false_val,
    };
}

/// `(sequential? x)` — true iff `x` implements Sequential
/// (order-preserving collection): list / vector / cons / lazy-seq /
/// chunked-cons / range / string-seq / array-seq /
/// persistent-queue. maps / sets are NOT sequential.
pub fn sequentialQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("sequential?", args, 1, loc);
    const t = args[0].tag();
    // A `deftype` carrying the `Sequential` marker (e.g. `Eduction`) is
    // sequential? true — same SSOT marker the printer consults (D-190/ADR-0068).
    if (t == .typed_instance) {
        const inst = args[0].decodePtr(*const td_mod.TypedInstance);
        return if (inst.descriptor.declaresProtocol("Sequential")) .true_val else .false_val;
    }
    return switch (t) {
        .list, .vector, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq, .persistent_queue, .map_entry => .true_val,
        else => .false_val,
    };
}

/// `(associative? x)` — true iff `x` implements Associative
/// (vector + maps). Matches clojure.core/associative?.
pub fn associativeQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("associative?", args, 1, loc);
    const t = args[0].tag();
    return switch (t) {
        .vector, .array_map, .hash_map, .sorted_map, .map_entry => .true_val,
        else => .false_val,
    };
}

/// `(identity x)` — returns `x` unchanged. Useful as a place-holder
/// function argument (e.g. `(map identity coll)`).
pub fn identity(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("identity", args, 1, loc);
    return args[0];
}

/// `(boolean x)` — Clojure truthiness coercion: returns true unless
/// x is nil or false. The dual of `not` (NOT a tag check — see
/// `boolean?` for that).
pub fn booleanFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("boolean", args, 1, loc);
    return if (args[0].isNil() or args[0] == Value.false_val) .false_val else .true_val;
}

/// `(pos-int? x)` — true iff x is a positive Long. BigInt arm is a
/// follow-up; today BigInt → false (transient).
pub fn posIntQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("pos-int?", args, 1, loc);
    if (args[0].tag() != .integer) return .false_val;
    return if (args[0].asInteger() > 0) .true_val else .false_val;
}

/// `(neg-int? x)` — true iff x is a negative Long.
pub fn negIntQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("neg-int?", args, 1, loc);
    if (args[0].tag() != .integer) return .false_val;
    return if (args[0].asInteger() < 0) .true_val else .false_val;
}

/// `(nat-int? x)` — true iff x is a non-negative Long (includes 0).
pub fn natIntQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("nat-int?", args, 1, loc);
    if (args[0].tag() != .integer) return .false_val;
    return if (args[0].asInteger() >= 0) .true_val else .false_val;
}

/// `(keyword s)` / `(keyword ns s)` — intern a keyword Value.
/// 1-arg: if `s` is already a keyword, return it (idempotent); if
/// `s` is a string, intern `(nil, s)`; if `s` is a symbol, intern
/// `(sym.ns, sym.name)` as a keyword. Other input types raise
/// `feature_not_supported`.
/// 2-arg: both must be strings; intern `(ns, name)`.
pub fn keywordFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 1) {
        const x = args[0];
        if (x.tag() == .keyword) return x;
        if (x.tag() == .string) {
            return keyword_mod.intern(rt, null, string_mod.asString(x));
        }
        if (x.tag() == .symbol) {
            const s = symbol_mod.asSymbol(x);
            return keyword_mod.intern(rt, s.ns, s.name);
        }
        if (x.isNil()) return .nil_val;
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "keyword conversion from non-string/non-keyword/non-symbol" });
    } else if (args.len == 2) {
        if (args[0].tag() != .string or args[1].tag() != .string)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "keyword (2-arg) requires both ns and name to be strings" });
        return keyword_mod.intern(rt, string_mod.asString(args[0]), string_mod.asString(args[1]));
    }
    return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "keyword", .got = args.len, .min = 1, .max = 2 });
}

/// `(find-keyword name)` / `(find-keyword ns name)` — return the keyword IF it
/// is ALREADY interned (i.e. has been used), else nil. Unlike `keyword`, never
/// creates one. JVM reference: clojure.core/find-keyword.
pub fn findKeywordFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 1) {
        const x = args[0];
        // An existing keyword Value is, by construction, already interned.
        if (x.tag() == .keyword) return x;
        if (x.tag() == .string) return keyword_mod.find(rt, null, string_mod.asString(x)) orelse .nil_val;
        if (x.tag() == .symbol) {
            const s = symbol_mod.asSymbol(x);
            return keyword_mod.find(rt, s.ns, s.name) orelse .nil_val;
        }
        if (x.isNil()) return .nil_val;
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "find-keyword from non-string/non-keyword/non-symbol" });
    } else if (args.len == 2) {
        if (args[0].tag() != .string or args[1].tag() != .string)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "find-keyword (2-arg) requires both ns and name to be strings" });
        return keyword_mod.find(rt, string_mod.asString(args[0]), string_mod.asString(args[1])) orelse .nil_val;
    }
    return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "find-keyword", .got = args.len, .min = 1, .max = 2 });
}

/// `(symbol s)` / `(symbol ns name)` — intern a Symbol Value
/// (ADR-0037, F-004 Group A slot 1). 1-arg: if `s` is already a
/// symbol, return it (idempotent); if `s` is a string, intern
/// `(nil, s)`; if `s` is a keyword, intern `(kw.ns, kw.name)` as a
/// symbol. Other input types raise `feature_not_supported`.
/// 2-arg: both must be strings; intern `(ns, name)`.
pub fn symbolFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 1) {
        const x = args[0];
        if (x.tag() == .symbol) return x;
        if (x.tag() == .string) {
            return symbol_mod.intern(rt, null, string_mod.asString(x));
        }
        if (x.tag() == .keyword) {
            const kw = keyword_mod.asKeyword(x);
            return symbol_mod.intern(rt, kw.ns, kw.name);
        }
        if (x.isNil()) return .nil_val;
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "symbol conversion from non-string/non-symbol/non-keyword" });
    } else if (args.len == 2) {
        if (args[0].tag() != .string or args[1].tag() != .string)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "symbol (2-arg) requires both ns and name to be strings" });
        return symbol_mod.intern(rt, string_mod.asString(args[0]), string_mod.asString(args[1]));
    }
    return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "symbol", .got = args.len, .min = 1, .max = 2 });
}

/// `(name x)` — return the string name component of a keyword,
/// symbol, or string. For keywords + symbols, drops any `ns/` part
/// (and keyword's `:` prefix). For strings, returns the string
/// itself (idempotent).
pub fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    const x = args[0];
    if (x.tag() == .string) return x;
    if (x.tag() == .keyword) {
        const kw = keyword_mod.asKeyword(x);
        return string_mod.alloc(rt, kw.name);
    }
    if (x.tag() == .symbol) {
        const s = symbol_mod.asSymbol(x);
        return string_mod.alloc(rt, s.name);
    }
    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "name on non-string/non-keyword/non-symbol" });
}

/// `(namespace x)` — the namespace string of a qualified keyword or symbol,
/// or nil when unqualified (`(namespace :foo)`→nil, `(namespace :a/b)`→"a").
/// A non-Named value (string, number, …) is a type error — JVM throws
/// ClassCastException because String is not `clojure.lang.Named`.
pub fn namespaceFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("namespace", args, 1, loc);
    const x = args[0];
    switch (x.tag()) {
        .keyword => {
            const kw = keyword_mod.asKeyword(x);
            return if (kw.ns) |ns| string_mod.alloc(rt, ns) else Value.nil_val;
        },
        .symbol => {
            const s = symbol_mod.asSymbol(x);
            return if (s.ns) |ns| string_mod.alloc(rt, ns) else Value.nil_val;
        },
        else => |t| return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "namespace", .expected = "a keyword or symbol", .actual = @tagName(t) }),
    }
}

/// Render `args` to `w`, space-separated. `readable` = `pr`-style
/// (every arg quoted via `printValue`, so top-level strings/chars get
/// their `"` / `\` escapes); `!readable` = `print`-style human form
/// (top-level strings emitted as raw bytes; nested strings inside a
/// printed collection still go through `printValue` and get quoted).
fn writeArgsSpaced(rt: *Runtime, env: *Env, w: *std.Io.Writer, args: []const Value, readable: bool) anyerror!void {
    // D-185: `print`/`println` (`!readable`) render strings/chars raw at EVERY
    // depth, not just the top level — thread the flag into `printValue`'s
    // collection recursion via `*print-readably*`. Restored after so a later
    // `pr-str` / result-print stays readable.
    const saved_readably = print_mod.print_readably;
    print_mod.print_readably = readable;
    defer print_mod.print_readably = saved_readably;
    for (args, 0..) |arg, i| {
        if (i > 0) try w.writeByte(' ');
        if (!readable and arg.tag() == .string) {
            try w.writeAll(string_mod.asString(arg));
        } else if (!readable and arg.tag() == .char) {
            // Raw (`print`/`println`/`str`) form of a char is the bare
            // character, not the readable `\X` literal (D-154).
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(arg.asChar(), &buf) catch 0;
            try w.writeAll(buf[0..n]);
        } else {
            // printResult realizes a lazy seq (else delegates to printValue),
            // so (str/prn/println (map …)) renders the seq, not #<lazy_seq>.
            try print_mod.printResult(rt, env, w, arg);
        }
    }
}

/// Emit `args` to the process stdout, space-separated. `readable` picks
/// `pr` (quoted) vs `print` (raw) form; `newline` appends a trailing `\n`.
/// Writes through the shared `rt.stdout` so println/print/prn interleave
/// with the runner's result-print on ONE offset-tracking writer (D-096);
/// a test-init Runtime with no shared writer falls back to a private one
/// (correct in isolation — nothing else competes for the fd).
fn emitToStdout(rt: *Runtime, env: *Env, args: []const Value, readable: bool, newline: bool) anyerror!Value {
    if (rt.stdout) |w| {
        try writeArgsSpaced(rt, env, w, args, readable);
        if (newline) try w.writeByte('\n');
        try w.flush();
    } else {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(rt.io, &stdout_buf);
        const w = &stdout_writer.interface;
        try writeArgsSpaced(rt, env, w, args, readable);
        if (newline) try w.writeByte('\n');
        try w.flush();
    }
    return .nil_val;
}

/// `(println & args)` — human form, space-separated, trailing newline.
pub fn printlnFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return emitToStdout(rt, env, args, false, true);
}

/// `(print & args)` — like `println` but WITHOUT the trailing newline.
pub fn printFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return emitToStdout(rt, env, args, false, false);
}

/// `(prn & args)` — readable (`pr`) form, space-separated, trailing
/// newline. Strings/chars are quoted (unlike `println`).
pub fn prnFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return emitToStdout(rt, env, args, true, true);
}

/// `(pr & args)` — readable (`pr`) form, space-separated, NO trailing
/// newline (the no-newline counterpart of `prn`; strings/chars quoted).
pub fn prFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return emitToStdout(rt, env, args, true, false);
}

/// `(newline)` — write a single newline to stdout. Spec: clojure.core/newline.
pub fn newlineFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("newline", args, 0, loc);
    return emitToStdout(rt, env, &.{}, false, true);
}

/// `(pr-str & args)` — render args in readable (`pr`) form,
/// space-separated, and return the result as a string (no stdout).
pub fn prStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try writeArgsSpaced(rt, env, &aw.writer, args, true);
    return try string_mod.alloc(rt, aw.writer.buffered());
}

/// `(print-str & args)` — like `pr-str` but human-readable (`print`) form
/// (strings unquoted, chars bare), space-separated, returned as a string
/// (no stdout). The `print`/`pr` distinction is the `readable` flag.
pub fn printStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try writeArgsSpaced(rt, env, &aw.writer, args, false);
    return try string_mod.alloc(rt, aw.writer.buffered());
}

/// `(str & args)` — variadic string concatenation. Each arg is
/// rendered human-readable (strings pass through unquoted; nil
/// renders as ""; everything else goes through `print.printValue`).
/// 0-arg form returns the empty string.
pub fn strFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    // Per-value str rendering lives in `print.writeStrValue` — the single
    // source shared with the `.toString` Object-method fallback (D-207 /
    // ADR-0076 C3). `str` is the multi-arg concatenation over it. Top-level
    // string / char (`\A`→"A", D-154) / regex (raw pattern) / uuid (bare
    // canonical, ADR-0074) render bare there; nested values keep readable form.
    for (args) |arg| try print_mod.writeStrValue(rt, env, &aw.writer, arg);
    return try string_mod.alloc(rt, aw.writer.buffered());
}

/// Render `f` with `prec` fractional digits. Zig's `{d:.N}` precision is a
/// comptime specifier, so dispatch the runtime precision over a fixed switch
/// (printf's common range); precision > 10 caps at the printf default 6.
fn writeFloatPrec(w: *std.Io.Writer, f: f64, prec: usize) !void {
    switch (prec) {
        0 => try w.print("{d:.0}", .{f}),
        1 => try w.print("{d:.1}", .{f}),
        2 => try w.print("{d:.2}", .{f}),
        3 => try w.print("{d:.3}", .{f}),
        4 => try w.print("{d:.4}", .{f}),
        5 => try w.print("{d:.5}", .{f}),
        6 => try w.print("{d:.6}", .{f}),
        7 => try w.print("{d:.7}", .{f}),
        8 => try w.print("{d:.8}", .{f}),
        9 => try w.print("{d:.9}", .{f}),
        10 => try w.print("{d:.10}", .{f}),
        else => try w.print("{d:.6}", .{f}),
    }
}

/// `(format fmt & args)` — printf-style string formatting. Supported
/// directives: `%[-][width][.prec]CONV` where CONV is `s` `d` `f` `x` plus
/// the no-arg `%%` / `%n`. `-` left-justifies; `width` is the min field
/// width (space-padded; the `0` zero-pad flag is not supported, so a leading
/// width zero just space-pads); `.prec` is the float fractional-digit count
/// (only for `%f`, default 6). Args are consumed left-to-right. Matches
/// clojure.core/format for the supported subset (the JVM delegates to
/// java.util.Formatter).
pub fn formatFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0 or args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "format", .actual = if (args.len == 0) "nil" else @tagName(args[0].tag()) });
    const fmt = string_mod.asString(args[0]);
    var ai: usize = 1;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const w = &aw.writer;

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try w.writeByte(fmt[i]);
            i += 1;
            continue;
        }
        i += 1; // past '%'
        if (i >= fmt.len) return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = "%" });

        // Optional argument index `N$` (Java spec position 1: before flags).
        // Non-destructive lookahead so it doesn't swallow a `%05d` width-`0`
        // flag: only commit when `<digits>$` actually matches. `explicit_idx`
        // is the 1-based format-arg number → `args[explicit_idx]`.
        var explicit_idx: ?usize = null;
        {
            var j = i;
            var n: usize = 0;
            var saw = false;
            while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {
                n = n * 10 + (fmt[j] - '0');
                saw = true;
            }
            if (saw and j < fmt.len and fmt[j] == '$') {
                explicit_idx = n;
                i = j + 1; // past the '$'
            }
        }

        // Flags, then min field width. `-` overrides `0` (Java semantics).
        // `+`/` `/`(` are sign flags and `,` is grouping — applied to `%d`.
        var left = false;
        var zero_pad = false;
        var plus = false; // '+': always show a sign
        var space = false; // ' ': leading space for non-negative
        var paren = false; // '(': render negatives in parentheses
        var group = false; // ',': locale grouping separators (every 3 digits)
        var alt = false; // '#': alternate form (0x/0X/0 radix prefix)
        flags: while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => left = true,
                '0' => zero_pad = true,
                '+' => plus = true,
                ' ' => space = true,
                '(' => paren = true,
                ',' => group = true,
                '#' => alt = true,
                else => break :flags,
            }
        }
        var width: usize = 0;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1)
            width = width * 10 + (fmt[i] - '0');

        // Optional precision `.N` (only meaningful for %f).
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var p: usize = 0;
            var saw_digit = false;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                p = p * 10 + (fmt[i] - '0');
                saw_digit = true;
            }
            if (!saw_digit) return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = "%." });
            prec = p;
        }
        if (i >= fmt.len) return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = "%" });
        const conv = fmt[i];
        i += 1;

        // %% / %n take no argument and ignore width.
        if (conv == '%') {
            try w.writeByte('%');
            continue;
        }
        if (conv == 'n') {
            try w.writeByte('\n');
            continue;
        }
        // Precision is valid for floats (fraction digits) and for %s/%S
        // (max chars — Java truncates). Other conversions reject it.
        if (prec != null and conv != 'f' and conv != 'e' and conv != 'E' and conv != 'g' and conv != 'G' and conv != 's' and conv != 'S')
            return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = "%." });

        // Resolve the argument source: an explicit `N$` index (1-based →
        // args[N]) or the auto-incrementing counter `ai`. Bounds-checked
        // once here; every consuming arm reads `args[src]`.
        const src = explicit_idx orelse ai;
        if (src >= args.len) return error_catalog.raise(.format_args_insufficient, loc, .{});

        // Render the conversion into a temp, then space-pad to `width` into w.
        var tmp: std.Io.Writer.Allocating = .init(rt.gpa);
        defer tmp.deinit();
        const tw = &tmp.writer;
        switch (conv) {
            // `%s`/`%S`: nil → "null" (Java Formatter), precision truncates to N
            // chars, `%S` upper-cases. Render the value, then trim/upcase.
            's', 'S' => {
                var stmp: std.Io.Writer.Allocating = .init(rt.gpa);
                defer stmp.deinit();
                if (args[src].tag() == .nil) {
                    try stmp.writer.writeAll("null");
                } else {
                    try writeArgsSpaced(rt, env, &stmp.writer, args[src .. src + 1], false);
                }
                var s = stmp.writer.buffered();
                if (prec) |p| if (p < s.len) {
                    s = s[0..p];
                };
                if (conv == 'S') {
                    for (s) |ch| try tw.writeByte(std.ascii.toUpper(ch));
                } else try tw.writeAll(s);
            },
            'd' => try writeDecimal(tw, try error_catalog.expectI64(args[src], "format", loc), group, plus, space, paren),
            // `%x`/`%X`/`%o`: Java renders the UNSIGNED 64-bit two's-complement
            // value (`%x -1` → "ffffffffffffffff"); `#` adds a 0x/0X/0 prefix.
            'x', 'X', 'o' => {
                const uv: u64 = @bitCast(try error_catalog.expectI64(args[src], "format", loc));
                if (alt) try tw.writeAll(switch (conv) {
                    'x' => "0x",
                    'X' => "0X",
                    else => "0",
                });
                switch (conv) {
                    'x' => try tw.print("{x}", .{uv}),
                    'X' => try tw.print("{X}", .{uv}),
                    else => try tw.print("{o}", .{uv}),
                }
            },
            'f' => {
                var ftmp: std.Io.Writer.Allocating = .init(rt.gpa);
                defer ftmp.deinit();
                try writeFloatPrec(&ftmp.writer, try error_catalog.expectNumber(args[src], "format", loc), prec orelse 6);
                try writeFloatFlagged(tw, ftmp.writer.buffered(), plus, space, paren, group);
            },
            'e', 'E' => {
                var ftmp: std.Io.Writer.Allocating = .init(rt.gpa);
                defer ftmp.deinit();
                try writeScientific(&ftmp.writer, try error_catalog.expectNumber(args[src], "format", loc), prec orelse 6, conv == 'E');
                try writeFloatFlagged(tw, ftmp.writer.buffered(), plus, space, paren, group);
            },
            'g', 'G' => {
                var ftmp: std.Io.Writer.Allocating = .init(rt.gpa);
                defer ftmp.deinit();
                try writeGeneral(&ftmp.writer, try error_catalog.expectNumber(args[src], "format", loc), prec orelse 6, conv == 'G');
                try writeFloatFlagged(tw, ftmp.writer.buffered(), plus, space, paren, group);
            },
            // `%h`/`%H`: hex of the value's hashCode, nil → "null". cljw's hash
            // differs from the JVM's (AD-009), so the hex value diverges from
            // clj — but it IS a valid lowercase/uppercase hex hashcode.
            'h', 'H' => {
                if (args[src].tag() == .nil) {
                    try tw.writeAll("null");
                } else {
                    const hv: u32 = equal_mod.valueHash(args[src]);
                    if (conv == 'H') try tw.print("{X}", .{hv}) else try tw.print("{x}", .{hv});
                }
            },
            // `%b`/`%B` boolean conversion (Java/clj): nil or false → "false",
            // any other value → "true" (logical-truth test, not a type check).
            'b', 'B' => {
                const truthy = args[src].isTruthy();
                try tw.writeAll(if (conv == 'B') (if (truthy) "TRUE" else "FALSE") else (if (truthy) "true" else "false"));
            },
            // `%c` character conversion: arg must be a char (clj rejects a Long
            // with IllegalFormatConversionException — cljw raises
            // type_arg_invalid, both error). Emits the codepoint as UTF-8.
            'c' => {
                if (args[src].tag() != .char)
                    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "format", .expected = "character for %c", .actual = @tagName(args[src].tag()) });
                var cbuf: [4]u8 = undefined;
                const cn = std.unicode.utf8Encode(args[src].asChar(), &cbuf) catch 0;
                try tw.writeAll(cbuf[0..cn]);
            },
            else => {
                const sb = [_]u8{ '%', conv };
                return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = sb[0..] });
            },
        }
        // Auto mode consumes one positional arg; an explicit `N$` index does
        // not advance the counter (Java semantics).
        if (explicit_idx == null) ai += 1;
        const rendered = tw.buffered();
        if (rendered.len >= width) {
            try w.writeAll(rendered);
        } else if (left) {
            try w.writeAll(rendered);
            for (0..width - rendered.len) |_| try w.writeByte(' ');
        } else if (zero_pad) {
            // Zero-pad: a leading sign (-, +, space) stays leftmost, zeros
            // fill the gap after it (Java: `%+05d` 42 → "+0042").
            const pad = width - rendered.len;
            const sign = rendered.len > 0 and (rendered[0] == '-' or rendered[0] == '+' or rendered[0] == ' ');
            if (sign) {
                try w.writeByte(rendered[0]);
                for (0..pad) |_| try w.writeByte('0');
                try w.writeAll(rendered[1..]);
            } else {
                for (0..pad) |_| try w.writeByte('0');
                try w.writeAll(rendered);
            }
        } else {
            for (0..width - rendered.len) |_| try w.writeByte(' ');
            try w.writeAll(rendered);
        }
    }
    return try string_mod.alloc(rt, w.buffered());
}

/// Render an i48 in `%d` form with the sign + grouping flags. `group` inserts
/// `,` every 3 digits; `paren` wraps negatives as `(123)`; `plus`/`space`
/// prefix a non-negative with `+`/` `. The width / zero-pad step in `formatFn`
/// then pads the result (its sign-leftmost rule keeps `-`/`+`/` ` outermost).
fn writeDecimal(tw: *std.Io.Writer, n: i64, group: bool, plus: bool, space: bool, paren: bool) !void {
    const neg = n < 0;
    // i64-MIN-safe magnitude via two's-complement negate on the bit pattern.
    const mag: u64 = if (neg) (~@as(u64, @bitCast(n)) +% 1) else @as(u64, @bitCast(n));
    var dbuf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&dbuf, "{d}", .{mag}) catch unreachable;

    if (neg) {
        try tw.writeByte(if (paren) '(' else '-');
    } else if (plus) {
        try tw.writeByte('+');
    } else if (space) {
        try tw.writeByte(' ');
    }

    if (group) {
        // Emit the leading 1-3 digit run, then `,`-separated triplets.
        const head = if (digits.len % 3 == 0) 3 else digits.len % 3;
        try tw.writeAll(digits[0..head]);
        var idx: usize = head;
        while (idx < digits.len) : (idx += 3) {
            try tw.writeByte(',');
            try tw.writeAll(digits[idx .. idx + 3]);
        }
    } else {
        try tw.writeAll(digits);
    }

    if (neg and paren) try tw.writeByte(')');
}

/// Apply the sign / grouping flags to an already-rendered float string `s`
/// (which carries its own leading '-' for negatives). `+`/' ' prefix a
/// non-negative; '(' wraps a negative as "(1.23)"; ',' groups the integer
/// part with thousands separators. Mirrors Java Formatter float-flag rules;
/// the width / zero-pad step in `formatFn` then pads the result.
fn writeFloatFlagged(tw: *std.Io.Writer, s: []const u8, plus: bool, space: bool, paren: bool, group: bool) !void {
    const neg = s.len > 0 and s[0] == '-';
    const body = if (neg) s[1..] else s;
    if (neg and paren) {
        try tw.writeByte('(');
    } else if (neg) {
        try tw.writeByte('-');
    } else if (plus) {
        try tw.writeByte('+');
    } else if (space) {
        try tw.writeByte(' ');
    }
    if (group) {
        // Group only the integer part (up to '.', 'e', or 'E').
        var int_end: usize = body.len;
        for (body, 0..) |c, idx| {
            if (c == '.' or c == 'e' or c == 'E') {
                int_end = idx;
                break;
            }
        }
        const intp = body[0..int_end];
        const head = if (intp.len > 0 and intp.len % 3 == 0) 3 else intp.len % 3;
        try tw.writeAll(intp[0..head]);
        var idx: usize = head;
        while (idx < intp.len) : (idx += 3) {
            try tw.writeByte(',');
            try tw.writeAll(intp[idx .. idx + 3]);
        }
        try tw.writeAll(body[int_end..]);
    } else {
        try tw.writeAll(body);
    }
    if (neg and paren) try tw.writeByte(')');
}

/// Render `f` in `%e` scientific form (`[-]d.dddddde±dd`). Zig's `{e:.N}`
/// produces the mantissa + exponent; this normalises the exponent to Java's
/// shape: an explicit `+`/`-` sign and at least two digits (`1.234568e+04`).
/// `upper` selects `E`. Precision is comptime in Zig's `print`, so it is
/// dispatched over the printf-common range (mirrors `writeFloatPrec`).
fn writeScientific(w: *std.Io.Writer, f: f64, prec: usize, upper: bool) !void {
    var buf: [64]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    try sciRaw(&fbs, f, prec);
    const zig = fbs.buffered();
    const epos = std.mem.findScalar(u8, zig, 'e') orelse std.mem.findScalar(u8, zig, 'E') orelse {
        try w.writeAll(zig);
        return;
    };
    try w.writeAll(zig[0..epos]);
    try w.writeByte(if (upper) 'E' else 'e');
    const exp = parseSciExp(zig[epos + 1 ..]);
    try w.writeByte(if (exp < 0) '-' else '+');
    var ebuf: [16]u8 = undefined;
    const edigits = std.fmt.bufPrint(&ebuf, "{d}", .{@abs(exp)}) catch unreachable;
    if (edigits.len < 2) try w.writeByte('0');
    try w.writeAll(edigits);
}

/// Zig's `{e:.N}` with a runtime precision dispatched over the printf-common
/// range (precision is comptime in Zig's `print`). Shared by `writeScientific`
/// (output) and `writeGeneral` (exponent probe).
fn sciRaw(fbs: *std.Io.Writer, f: f64, prec: usize) !void {
    switch (prec) {
        0 => try fbs.print("{e:.0}", .{f}),
        1 => try fbs.print("{e:.1}", .{f}),
        2 => try fbs.print("{e:.2}", .{f}),
        3 => try fbs.print("{e:.3}", .{f}),
        4 => try fbs.print("{e:.4}", .{f}),
        5 => try fbs.print("{e:.5}", .{f}),
        6 => try fbs.print("{e:.6}", .{f}),
        7 => try fbs.print("{e:.7}", .{f}),
        8 => try fbs.print("{e:.8}", .{f}),
        9 => try fbs.print("{e:.9}", .{f}),
        10 => try fbs.print("{e:.10}", .{f}),
        else => try fbs.print("{e:.6}", .{f}),
    }
}

/// Parse the signed exponent from the tail after `e` in a `{e}` rendering
/// (`"+04"` / `"-4"` / `"7"` → 4 / -4 / 7).
fn parseSciExp(tail: []const u8) i32 {
    var s = tail;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    const mag = std.fmt.parseInt(i32, s, 10) catch 0;
    return if (neg) -mag else mag;
}

/// Render `f` in `%g` general form: round to `prec` significant figures
/// (default 6, 0 → 1), then use fixed notation when the rounded exponent is in
/// `-4 ≤ exp < prec` else scientific — Java's rule. Unlike C, Java keeps
/// trailing zeros, which `writeFloatPrec`/`writeScientific` already do.
fn writeGeneral(w: *std.Io.Writer, f: f64, prec: usize, upper: bool) !void {
    const p: usize = if (prec == 0) 1 else prec;
    var buf: [64]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    try sciRaw(&fbs, f, p - 1);
    const sci = fbs.buffered();
    const epos = std.mem.findScalar(u8, sci, 'e') orelse {
        try w.writeAll(sci);
        return;
    };
    const exp = parseSciExp(sci[epos + 1 ..]);
    const pi: i32 = @intCast(p);
    if (exp >= -4 and exp < pi) {
        // Fixed: `p` sig figs at exponent `exp` = `p-1-exp` fractional digits.
        try writeFloatPrec(w, f, @intCast(pi - 1 - exp));
    } else {
        try writeScientific(w, f, p - 1, upper);
    }
}

/// `(subs s start)` / `(subs s start end)` — substring slice over
/// codepoint indices (ADR-0014: cw v1 strings are UTF-8 internally
/// but `count` and `subs` operate on codepoints). Returns a new
/// heap String. Raises on negative bounds or out-of-range.
pub fn subsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "subs", .got = args.len, .min = 2, .max = 3 });
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "subs", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "subs", .actual = @tagName(args[1].tag()) });
    const s = string_mod.asString(args[0]);
    const start_i = args[1].asInteger();
    if (start_i < 0)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "subs with negative start index" });
    const start: usize = @intCast(start_i);
    var end: usize = std.math.maxInt(usize);
    if (args.len == 3) {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "subs", .actual = @tagName(args[2].tag()) });
        const end_i = args[2].asInteger();
        if (end_i < start_i)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "subs with end < start" });
        end = @intCast(end_i);
    }
    const slice = charset_mod.substring(s, start, end) catch {
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "subs on invalid UTF-8 boundary" });
    };
    return string_mod.alloc(rt, slice);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

/// `(hash x)` — content hash, the `=`/hash contract partner
/// (`equal.valueHash`, also the HAMT key hash). Returned as a signed
/// 32-bit int (JVM `hash` is a 32-bit `int`); cljw's value is internally
/// consistent but not bit-identical to the JVM Murmur output.
/// `(eval form)` — evaluate a runtime data Value as code (ADR-0058 / D-197).
/// Delegates to `driver.evalValue` (valueToForm → analyze → evalForm), which
/// dispatches to the active backend, so eval is backend-neutral. A top-level
/// form has no enclosing locals; the transient arena holds the reconstructed
/// form + node and is freed after (the result Value is GC-allocated, survives).
pub fn evalFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("eval", args, 1, loc);
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    // A fresh top-level locals frame (the eval'd form's own `let*` / macro
    // expansions index into it), sized like the runner's top-level frame.
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    return driver.evalValue(rt, env, &locals, arena.allocator(), args[0], loc);
}

pub fn hashFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("hash", args, 1, loc);
    return Value.initInteger(@as(i32, @bitCast(equal_mod.valueHash(args[0]))));
}

/// `(mix-collection-hash hash-basis count)` — the Murmur3 collection-hash
/// finaliser (clojure.core, used by custom hashers). Both args are 32-bit
/// ints; the result is a 32-bit int.
pub fn mixCollectionHashFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("mix-collection-hash", args, 2, loc);
    const basis: u32 = @bitCast(@as(i32, @truncate(try error_catalog.expectInteger(args[0], "mix-collection-hash", loc))));
    const cnt: u32 = @bitCast(@as(i32, @truncate(try error_catalog.expectInteger(args[1], "mix-collection-hash", loc))));
    return Value.initInteger(@as(i32, @bitCast(hash_mod.mixCollHash(basis, cnt))));
}

/// `(hash-ordered-coll coll)` / `(hash-unordered-coll coll)` — clojure.core
/// collection-hash combinators (used by custom collection `hashCode`/`hasheq`).
/// Computed with cljw's internal 32-bit-wrapping Murmur algorithm (not Clojure
/// arithmetic, which auto-promotes per F-005). Iterate the coll's seq, hashing
/// each element via the same `valueHash` the HAMT uses.
fn collHash(rt: *Runtime, env: *Env, name: []const u8, args: []const Value, loc: SourceLocation, ordered: bool) anyerror!Value {
    try error_catalog.checkArity(name, args, 1, loc);
    var h: u32 = if (ordered) 1 else 0;
    var n: u32 = 0;
    var cur = try sequence.seqFn(rt, env, args[0..1], loc);
    while (cur.tag() == .list and list.countOf(cur) > 0) {
        const eh = equal_mod.valueHash(list.first(cur));
        h = if (ordered) h *% 31 +% eh else h +% eh;
        n +%= 1;
        cur = list.rest(cur);
    }
    return Value.initInteger(@as(i32, @bitCast(hash_mod.mixCollHash(h, n))));
}

pub fn hashOrderedCollFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return collHash(rt, env, "hash-ordered-coll", args, loc, true);
}

pub fn hashUnorderedCollFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return collHash(rt, env, "hash-unordered-coll", args, loc, false);
}

/// `(gensym)` / `(gensym prefix)` — a fresh unguessable symbol
/// `<prefix><n>` (default prefix `G__`). Uses the runtime gensym counter
/// directly (the `__auto__`-suffixed `rt.gensym` is the syntax-quote `x#`
/// form, a different surface).
pub fn gensymFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "gensym", .got = args.len, .min = 0, .max = 1 });
    var prefix: []const u8 = "G__";
    if (args.len == 1) {
        const p = args[0];
        prefix = switch (p.tag()) {
            .string => string_mod.asString(p),
            .symbol => symbol_mod.asSymbol(p).name,
            else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "gensym", .expected = "string or symbol prefix", .actual = @tagName(p.tag()) }),
        };
    }
    const n = rt.gensym_counter;
    rt.gensym_counter += 1;
    const name = try std.fmt.allocPrint(rt.gc.infra, "{s}{d}", .{ prefix, n });
    defer rt.gc.infra.free(name);
    return symbol_mod.intern(rt, null, name);
}

/// `(rt/__resolve sym)` — the Var that `sym` resolves to, as a `.var_ref`
/// Value. A qualified `ns/name` symbol consults that namespace; an
/// unqualified name the current namespace (own mappings, then refers).
/// nil when the symbol — or its named namespace — does not resolve. The
/// `.clj` `resolve` wraps this; the var_ref derefs to the Var's value and
/// prints `#'ns/name`.
pub fn resolvePrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("__resolve", args, 1, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__resolve",
            .expected = "symbol",
            .actual = @tagName(args[0].tag()),
        });
    }
    const sym = symbol_mod.asSymbol(args[0]);
    const ns: *env_mod.Namespace = if (sym.ns) |ns_name|
        (env.findNs(ns_name) orelse return Value.nil_val)
    else
        (env.current_ns orelse return Value.nil_val);
    const var_ptr = ns.resolve(sym.name) orelse return Value.nil_val;
    return Value.encodeHeapPtr(.var_ref, var_ptr);
}

/// `(alter-var-root v f & args)` — atomically set Var `v`'s root to
/// `(apply f current-root args)` and return the new root. `v` is a `.var_ref`
/// (from `#'name` / `var`). The root is the same mutable cell `def` writes, so
/// this is the foundation `with-redefs` builds on. Single-threaded: no CAS loop.
pub fn alterVarRootFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "alter-var-root", .got = args.len, .min = 2 });
    if (args[0].tag() != .var_ref)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "alter-var-root", .expected = "var", .actual = @tagName(args[0].tag()) });
    const v: *env_mod.Var = @constCast(args[0].decodePtr(*const env_mod.Var));
    const call_args = try rt.gpa.alloc(Value, args.len - 1);
    defer rt.gpa.free(call_args);
    call_args[0] = v.deref();
    @memcpy(call_args[1..], args[2..]);
    const newroot = try higher_order.invokeCallable(rt, env, args[1], call_args, loc);
    v.setRoot(newroot);
    return newroot;
}

/// `(var-get v)` — return Var `v`'s current value (thread binding if bound,
/// else root). `v` is a `.var_ref`. Mirrors `deref` on a var.
pub fn varGetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("var-get", args, 1, loc);
    if (args[0].tag() != .var_ref)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "var-get", .expected = "var", .actual = @tagName(args[0].tag()) });
    return args[0].decodePtr(*const env_mod.Var).deref();
}

/// `(var-set v val)` — set Var `v`'s CURRENT THREAD BINDING to `val` and
/// return `val`. `v` must be thread-bound (per clj: throws otherwise — root
/// is `def`/`alter-var-root`'s job). Powers `with-local-vars` + binding-scoped
/// mutation.
pub fn varSetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("var-set", args, 2, loc);
    if (args[0].tag() != .var_ref)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "var-set", .expected = "var", .actual = @tagName(args[0].tag()) });
    const v: *const env_mod.Var = args[0].decodePtr(*const env_mod.Var);
    if (!env_mod.setBinding(v, args[1])) {
        const full = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ v.ns.name, v.name });
        defer rt.gpa.free(full);
        return error_catalog.raise(.var_set_not_bound, loc, .{ .@"var" = full });
    }
    return args[1];
}

const ENTRIES = [_]Entry{
    .{ .name = "hash", .f = &hashFn },
    .{ .name = "mix-collection-hash", .f = &mixCollectionHashFn },
    .{ .name = "hash-ordered-coll", .f = &hashOrderedCollFn },
    .{ .name = "hash-unordered-coll", .f = &hashUnorderedCollFn },
    .{ .name = "var-get", .f = &varGetFn },
    .{ .name = "var-set", .f = &varSetFn },
    .{ .name = "eval", .f = &evalFn },
    .{ .name = "gensym", .f = &gensymFn },
    .{ .name = "__resolve", .f = &resolvePrim },
    .{ .name = "alter-var-root", .f = &alterVarRootFn },
    .{ .name = "__instance?", .f = &instanceQPrim },
    .{ .name = "-class-isa?", .f = &classIsaPrim },
    .{ .name = "ifn?", .f = &ifnQ },
    .{ .name = "var?", .f = &varQ },
    .{ .name = "thread-bound?", .f = &threadBoundQ },
    .{ .name = "bound?", .f = &boundQ },
    .{ .name = "nil?", .f = &nilQ },
    .{ .name = "true?", .f = &trueQ },
    .{ .name = "false?", .f = &falseQ },
    .{ .name = "identical?", .f = &identicalQ },
    .{ .name = "string?", .f = &stringQ },
    .{ .name = "integer?", .f = &integerQ },
    // int? and double? are exact aliases: cw v1 has a single integer tag and
    // a single float tag, so int? ≡ integer? and double? ≡ float?.
    .{ .name = "int?", .f = &integerQ },
    .{ .name = "double?", .f = &floatQ },
    .{ .name = "NaN?", .f = &nanQ },
    .{ .name = "infinite?", .f = &infiniteQ },
    .{ .name = "number?", .f = &numberQ },
    .{ .name = "symbol?", .f = &symbolQ },
    .{ .name = "keyword?", .f = &keywordQ },
    .{ .name = "vector?", .f = &vectorQ },
    .{ .name = "map-entry?", .f = &mapEntryQ },
    .{ .name = "list?", .f = &listQ },
    .{ .name = "map?", .f = &mapQ },
    .{ .name = "set?", .f = &setQ },
    .{ .name = "record?", .f = &recordQ },
    .{ .name = "fn?", .f = &fnQ },
    .{ .name = "boolean?", .f = &booleanQ },
    .{ .name = "char?", .f = &charQ },
    .{ .name = "float?", .f = &floatQ },
    .{ .name = "ratio?", .f = &ratioQ },
    .{ .name = "decimal?", .f = &decimalQ },
    .{ .name = "some?", .f = &someQ },
    .{ .name = "not", .f = &notFn },
    .{ .name = "coll?", .f = &collQ },
    .{ .name = "seq?", .f = &seqQ },
    .{ .name = "sequential?", .f = &sequentialQ },
    .{ .name = "associative?", .f = &associativeQ },
    .{ .name = "identity", .f = &identity },
    .{ .name = "boolean", .f = &booleanFn },
    .{ .name = "pos-int?", .f = &posIntQ },
    .{ .name = "neg-int?", .f = &negIntQ },
    .{ .name = "nat-int?", .f = &natIntQ },
    .{ .name = "keyword", .f = &keywordFn },
    .{ .name = "find-keyword", .f = &findKeywordFn },
    .{ .name = "symbol", .f = &symbolFn },
    .{ .name = "name", .f = &nameFn },
    .{ .name = "namespace", .f = &namespaceFn },
    .{ .name = "println", .f = &printlnFn },
    .{ .name = "print", .f = &printFn },
    .{ .name = "prn", .f = &prnFn },
    .{ .name = "pr", .f = &prFn },
    .{ .name = "newline", .f = &newlineFn },
    .{ .name = "pr-str", .f = &prStrFn },
    .{ .name = "print-str", .f = &printStrFn },
    .{ .name = "str", .f = &strFn },
    .{ .name = "format", .f = &formatFn },
    .{ .name = "subs", .f = &subsFn },
    .{ .name = "tagged-literal", .f = &taggedLiteralFn },
    .{ .name = "tagged-literal?", .f = &taggedLiteralQFn },
};

/// `(tagged-literal tag form)` — construct a TaggedLiteral value (ADR-0075).
/// `tag` must be a symbol; `form` is any value.
pub fn taggedLiteralFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("tagged-literal", args, 2, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "tagged-literal",
            .expected = "symbol",
            .actual = @tagName(args[0].tag()),
        });
    }
    return try tagged_literal_mod.alloc(rt, args[0], args[1]);
}

/// `(tagged-literal? x)` — true iff `x` is a TaggedLiteral.
pub fn taggedLiteralQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("tagged-literal?", args, 1, loc);
    return if (args[0].tag() == .tagged_literal) Value.true_val else Value.false_val;
}

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

test "nil? distinguishes nil from false / 0 / true" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try nilQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{Value.initInteger(0)}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
}

test "true? is strict true (not Clojure truthiness)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try trueQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
    // Truthy values like 1 / "x" / :foo are NOT true?.
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{Value.initInteger(1)}, .{}));
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
}

test "false? is strict false (nil is NOT false?)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try falseQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try falseQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
    try testing.expectEqual(Value.false_val, try falseQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
}

test "identical? on bit-equal Values is true; differing Values false" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const equal = [_]Value{ Value.initInteger(7), Value.initInteger(7) };
    try testing.expectEqual(Value.true_val, try identicalQ(&fix.rt, &fix.env, &equal, .{}));

    const different = [_]Value{ Value.initInteger(7), Value.initInteger(8) };
    try testing.expectEqual(Value.false_val, try identicalQ(&fix.rt, &fix.env, &different, .{}));
}

test "predicates reject wrong arity" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(error.ArityError, nilQ(&fix.rt, &fix.env, &.{}, .{}));
    try testing.expectError(error.ArityError, identicalQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
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
