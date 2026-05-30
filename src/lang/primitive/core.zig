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
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const string_mod = @import("../../runtime/collection/string.zig");
const print_mod = @import("../../runtime/print.zig");
const charset_mod = @import("../../runtime/charset.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const class_name = @import("../../runtime/class_name.zig");

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
    return if (args[0].tag() == .vector) .true_val else .false_val;
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
    return switch (t) {
        .list, .vector, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq, .persistent_queue => .true_val,
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
        .vector, .array_map, .hash_map, .sorted_map => .true_val,
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

/// Render `args` to `w`, space-separated. `readable` = `pr`-style
/// (every arg quoted via `printValue`, so top-level strings/chars get
/// their `"` / `\` escapes); `!readable` = `print`-style human form
/// (top-level strings emitted as raw bytes; nested strings inside a
/// printed collection still go through `printValue` and get quoted).
fn writeArgsSpaced(rt: *Runtime, env: *Env, w: *std.Io.Writer, args: []const Value, readable: bool) anyerror!void {
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

/// `(pr-str & args)` — render args in readable (`pr`) form,
/// space-separated, and return the result as a string (no stdout).
pub fn prStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = loc;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try writeArgsSpaced(rt, env, &aw.writer, args, true);
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
    for (args) |arg| {
        switch (arg.tag()) {
            .nil => {},
            .string => try aw.writer.writeAll(string_mod.asString(arg)),
            .char => {
                // `(str \A)` → "A": the bare char, not the readable `\A`
                // literal (D-154).
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(arg.asChar(), &buf) catch 0;
                try aw.writer.writeAll(buf[0..n]);
            },
            else => try print_mod.printResult(rt, env, &aw.writer, arg),
        }
    }
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

        // Optional `-` (left-justify) flag, then min field width (space-pad).
        var left = false;
        if (fmt[i] == '-') {
            left = true;
            i += 1;
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
        if (prec != null and conv != 'f')
            return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = "%." });

        // Render the conversion into a temp, then space-pad to `width` into w.
        var tmp: std.Io.Writer.Allocating = .init(rt.gpa);
        defer tmp.deinit();
        const tw = &tmp.writer;
        switch (conv) {
            's' => {
                if (ai >= args.len) return error_catalog.raise(.format_args_insufficient, loc, .{});
                try writeArgsSpaced(rt, env, tw, args[ai .. ai + 1], false);
                ai += 1;
            },
            'd' => {
                if (ai >= args.len) return error_catalog.raise(.format_args_insufficient, loc, .{});
                try tw.print("{d}", .{try error_catalog.expectInteger(args[ai], "format", loc)});
                ai += 1;
            },
            'x' => {
                if (ai >= args.len) return error_catalog.raise(.format_args_insufficient, loc, .{});
                try tw.print("{x}", .{try error_catalog.expectInteger(args[ai], "format", loc)});
                ai += 1;
            },
            'f' => {
                if (ai >= args.len) return error_catalog.raise(.format_args_insufficient, loc, .{});
                try writeFloatPrec(tw, try error_catalog.expectNumber(args[ai], "format", loc), prec orelse 6);
                ai += 1;
            },
            else => {
                const sb = [_]u8{ '%', conv };
                return error_catalog.raise(.format_spec_invalid, loc, .{ .spec = sb[0..] });
            },
        }
        const rendered = tw.buffered();
        if (rendered.len >= width) {
            try w.writeAll(rendered);
        } else if (left) {
            try w.writeAll(rendered);
            for (0..width - rendered.len) |_| try w.writeByte(' ');
        } else {
            for (0..width - rendered.len) |_| try w.writeByte(' ');
            try w.writeAll(rendered);
        }
    }
    return try string_mod.alloc(rt, w.buffered());
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

const ENTRIES = [_]Entry{
    .{ .name = "__instance?", .f = &instanceQPrim },
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
    .{ .name = "symbol", .f = &symbolFn },
    .{ .name = "name", .f = &nameFn },
    .{ .name = "println", .f = &printlnFn },
    .{ .name = "print", .f = &printFn },
    .{ .name = "prn", .f = &prnFn },
    .{ .name = "pr-str", .f = &prStrFn },
    .{ .name = "str", .f = &strFn },
    .{ .name = "format", .f = &formatFn },
    .{ .name = "subs", .f = &subsFn },
};

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
