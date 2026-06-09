// SPDX-License-Identifier: EPL-2.0
//! Class-name registry for `instance?` dispatch. Maps the recognised
//! cw v1 class symbols (`String`, `Long`, `Pattern`, `IFn`, ...) to the
//! Value predicate they accept, and routes Throwable hierarchy queries
//! through `runtime/error/host_class.zig`.
//!
//! ## Scope
//!
//! Holds the data + lookup helpers. `isInstance(v, class_name)` is
//! the public entry point. The `__instance?` primitive
//! (`lang/primitive/core.zig`) calls it after unwrapping its
//! quoted-Symbol first arg. The `instance?` macro
//! (`lang/macro_transforms.zig`) auto-quotes the user-form Class
//! symbol so callers write `(instance? String x)` without explicit
//! quote — matching JVM Clojure surface syntax via Path A
//! (Symbol-based primitive-side lookup).
//!
//! ## Hierarchy
//!
//! - **Native classes** (table-driven, exact tag match): the full set
//!   is `NATIVE_ENTRIES` below (`String`, `Long`, `Double`, `Boolean`,
//!   `Character`, `Keyword`, `Symbol`, `PersistentList`,
//!   `PersistentVector`, `MapEntry`, `PersistentArrayMap`,
//!   `PersistentHashMap`, `PersistentHashSet`, `PersistentQueue`,
//!   `Pattern`, `UUID`, `BigInt`, `Ratio`, `BigDecimal`).
//! - **Interface-shaped classes** (multi-tag match): `IFn`, `Number`,
//!   `IPersistentMap`, `IPersistentSet`, `IPersistentCollection`.
//! - **Throwable hierarchy**: delegates to `host_class.matches`
//!   (covers `Throwable` / `Exception` / `RuntimeException` /
//!   `ExceptionInfo` etc.).
//! - **User types** (`defrecord` / `deftype` / `reify`): walks the
//!   `TypeDescriptor.parent` chain, comparing `fqcn` against the
//!   class name.
//!
//! ## DIVERGENCE from cw v0
//!
//! cw v0 accepted keyword-form `(instance? :integer 42)` and
//! silently returned false for unknown class names (Tier D
//! PersistentQueue etc.). cw v1 rejects both: only Symbols at the
//! Class slot (the macro auto-quotes); unknown class symbols raise
//! a loud `name_error` from the primitive (see `core.zig::instanceQPrim`).
//! Per the survey DIVERGENCE catalogue + F-002 finished-form +
//! `provisional_marker.md` "permanent-no-op forbidden" —
//! silent-default-shift is eliminated at the source.
//!
//! `Pattern` aliasing to the `.regex` Tag (DIVERGENCE D2 in the
//! survey) lives here too: `java.util.regex.Pattern` is a class in
//! JVM but cw v1's `runtime/regex/value.zig` carries `HeapTag.regex`
//! as a first-class Value, so the class-name lookup short-circuits
//! to the tag rather than waiting for `runtime/java/util/regex/
//! Pattern.zig` surface to mature (gated on D-048).

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Tag = Value.Tag;
const TypeDescriptor = @import("type_descriptor.zig").TypeDescriptor;
const TypedInstance = @import("type_descriptor.zig").TypedInstance;
const ReifiedInstance = @import("type_descriptor.zig").ReifiedInstance;
const host_class = @import("error/host_class.zig");
const interface_membership = @import("interface_membership.zig");
const stream_classes = @import("io/stream_classes.zig");

/// One Tag-level entry — exact match against `Value.tag()`.
const NativeEntry = struct {
    name: []const u8,
    tag: Tag,
};

const NATIVE_ENTRIES = [_]NativeEntry{
    .{ .name = "String", .tag = .string },
    .{ .name = "Long", .tag = .integer },
    .{ .name = "Double", .tag = .float },
    .{ .name = "Boolean", .tag = .boolean },
    .{ .name = "Character", .tag = .char },
    .{ .name = "Keyword", .tag = .keyword },
    .{ .name = "Symbol", .tag = .symbol },
    .{ .name = "PersistentList", .tag = .list },
    .{ .name = "PersistentVector", .tag = .vector },
    .{ .name = "MapEntry", .tag = .map_entry },
    .{ .name = "PersistentArrayMap", .tag = .array_map },
    .{ .name = "PersistentHashMap", .tag = .hash_map },
    .{ .name = "PersistentHashSet", .tag = .hash_set },
    // ADR-0109: clj-faithful class names for sorted colls + Var (were raw
    // @tagName "sorted_map"/"sorted_set"/"var_ref" — fqcnForTag gap). Each maps
    // 1:1 to a clj class, so `(class (sorted-map …))` → "PersistentTreeMap" etc.
    .{ .name = "PersistentTreeMap", .tag = .sorted_map },
    .{ .name = "PersistentTreeSet", .tag = .sorted_set },
    .{ .name = "Var", .tag = .var_ref },
    .{ .name = "PersistentQueue", .tag = .persistent_queue },
    .{ .name = "Pattern", .tag = .regex },
    .{ .name = "UUID", .tag = .uuid },
    .{ .name = "BigInt", .tag = .big_int },
    .{ .name = "Ratio", .tag = .ratio },
    .{ .name = "BigDecimal", .tag = .big_decimal },
};

/// FQCN → simple normalisation for native class names. Throwable
/// hierarchy normalisation happens inside `host_class.normalizeClassName`;
/// this table covers the non-Throwable Java + Clojure FQCNs we
/// recognise.
const FQCN_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ "java.lang.String", "String" },
    .{ "java.lang.Long", "Long" },
    .{ "java.lang.Double", "Double" },
    .{ "java.lang.Boolean", "Boolean" },
    .{ "java.lang.Character", "Character" },
    .{ "java.lang.Number", "Number" },
    .{ "java.util.regex.Pattern", "Pattern" },
    .{ "java.util.UUID", "UUID" },
    .{ "java.util.Date", "Date" },
    .{ "clojure.lang.BigInt", "BigInt" },
    .{ "clojure.lang.Ratio", "Ratio" },
    .{ "java.math.BigDecimal", "BigDecimal" },
    .{ "clojure.lang.Keyword", "Keyword" },
    .{ "clojure.lang.Symbol", "Symbol" },
    .{ "clojure.lang.PersistentList", "PersistentList" },
    .{ "clojure.lang.PersistentVector", "PersistentVector" },
    .{ "clojure.lang.MapEntry", "MapEntry" },
    .{ "clojure.lang.PersistentArrayMap", "PersistentArrayMap" },
    .{ "clojure.lang.PersistentHashMap", "PersistentHashMap" },
    .{ "clojure.lang.PersistentHashSet", "PersistentHashSet" },
    .{ "clojure.lang.PersistentTreeMap", "PersistentTreeMap" },
    .{ "clojure.lang.PersistentTreeSet", "PersistentTreeSet" },
    .{ "clojure.lang.Var", "Var" },
    .{ "clojure.lang.PersistentQueue", "PersistentQueue" },
    .{ "clojure.lang.IFn", "IFn" },
    .{ "clojure.lang.IPersistentMap", "IPersistentMap" },
    .{ "clojure.lang.IPersistentSet", "IPersistentSet" },
    .{ "clojure.lang.IPersistentCollection", "IPersistentCollection" },
    .{ "clojure.lang.IEditableCollection", "IEditableCollection" },
    .{ "java.lang.Iterable", "Iterable" },
    .{ "clojure.lang.Seqable", "Seqable" },
    .{ "clojure.lang.Sequential", "Sequential" },
    .{ "clojure.lang.ISeq", "ISeq" },
    .{ "clojure.lang.Associative", "Associative" },
    .{ "clojure.lang.ILookup", "ILookup" },
    .{ "clojure.lang.Indexed", "Indexed" },
    .{ "clojure.lang.IPersistentVector", "IPersistentVector" },
    .{ "clojure.lang.IPersistentList", "IPersistentList" },
    .{ "clojure.lang.IPersistentStack", "IPersistentStack" },
    .{ "clojure.lang.Named", "Named" },
    .{ "clojure.lang.Reversible", "Reversible" },
    .{ "clojure.lang.Sorted", "Sorted" },
    // java.util collection interfaces (cljw collections implement them, JVM
    // parity) — surfaced by clojure.core.unify's `(instance? java.util.Map x)`.
    .{ "java.util.Map", "Map" },
    .{ "java.util.List", "List" },
    .{ "java.util.Set", "Set" },
    .{ "java.util.Collection", "Collection" },
    // deref / pending / ref family (ADR-0116, D-308).
    .{ "clojure.lang.IDeref", "IDeref" },
    .{ "clojure.lang.IRef", "IRef" },
    .{ "clojure.lang.IReference", "IReference" },
    .{ "clojure.lang.IPending", "IPending" },
    .{ "clojure.lang.IBlockingDeref", "IBlockingDeref" },
});

/// Normalise FQCN inputs to simple names. Falls back to `host_class`
/// normalisation for Throwable hierarchy FQCNs (so a single normalise
/// pass handles both surfaces). Unknown FQCNs pass through unchanged.
pub fn normalizeClassName(class_name: []const u8) []const u8 {
    if (FQCN_MAP.get(class_name)) |simple| return simple;
    return host_class.normalizeClassName(class_name);
}

/// Resolve a native class name (simple or FQCN) to its exact
/// `Value.Tag`, or null if the name is not a `NATIVE_ENTRIES`
/// exact-tag class. Interface-shaped names (`Number`/`IFn`/
/// `IPersistent*`) return null — they span multiple tags, so there
/// is no single descriptor to resolve a bare symbol to. Drives the
/// analyzer's native-class symbol resolution (ADR-0072): a bare
/// `Long`/`String`/`java.lang.Long` becomes its native descriptor
/// value, so `extend-type` over a native class lands where dispatch
/// finds it and a class symbol is a value (= `(class x)`).
pub fn nativeTagFor(name: []const u8) ?Tag {
    const simple = normalizeClassName(name);
    inline for (NATIVE_ENTRIES) |e| {
        if (std.mem.eql(u8, e.name, simple)) return e.tag;
    }
    return null;
}

/// Reverse of `nativeTagFor`: the canonical class name for a native `Tag`,
/// or null if the Tag is not a `NATIVE_ENTRIES` class. This is the SSOT for
/// the name↔Tag relation (D-204): `runtime.nativeDescriptor`'s fqcn derives
/// from it, so `(class x)` and `(instance? Name x)` cannot drift apart (they
/// did pre-D-204: `nativeFqcnFor` knew BigInt/Ratio/BigDecimal but
/// `NATIVE_ENTRIES` did not, and `(class #"x")` printed `regex` not `Pattern`).
pub fn fqcnForTag(tag: Tag) ?[]const u8 {
    inline for (NATIVE_ENTRIES) |e| {
        if (e.tag == tag) return e.name;
    }
    return null;
}

/// Return true iff `class_name` (simple or FQCN) is recognised by
/// either the native table, the interface table, or the Throwable
/// hierarchy. Drives the `__instance?` primitive's analyzer-time
/// validation: unknown class names raise `class_name_unknown`
/// rather than silently returning false.
pub fn isKnown(class_name: []const u8) bool {
    const simple = normalizeClassName(class_name);
    inline for (NATIVE_ENTRIES) |e| {
        if (std.mem.eql(u8, e.name, simple)) return true;
    }
    if (isInterfaceName(simple)) return true;
    if (host_class.isKnownException(simple)) return true;
    // java.io stream classes (family + leaf): one buffer-backed host_stream
    // answers `instance?` for the whole closed set (D-358). Shared SSOT with
    // host_stream's descriptor `protocol_impls` so the precheck and the match
    // agree. FQCN form (cljw never auto-imports java.io), unchanged by normalise.
    if (stream_classes.isStreamClass(simple)) return true;
    return false;
}

fn isInterfaceName(simple: []const u8) bool {
    // Derived from the interface_membership SSOT (ADR-0116): the former
    // 24-deep or-chain is retired so the recognised set has one source.
    return interface_membership.isInterface(simple);
}

/// `(instance? Class v)` predicate. Returns true iff `v` is a
/// member of the class named by `class_name` (simple or FQCN).
///
/// Dispatch order:
/// 1. Throwable hierarchy (host_class.matches walks the parent chain).
/// 2. Native exact-tag table (`String`, `Long`, etc.).
/// 3. Interface-shaped multi-tag set (`IFn`, `Number`, `IPersistent*`).
/// 4. User TypeDescriptor walk for `.typed_instance` / `.reified_instance`
///    receivers — comparing the simple name against each ancestor's
///    `fqcn`.
///
/// Unknown class names return false here; callers (= the
/// `__instance?` primitive) should pre-check with `isKnown` and raise
/// loud rather than relying on silent false.
pub fn isInstance(v: Value, class_name: []const u8) bool {
    const simple = normalizeClassName(class_name);

    if (host_class.isKnownException(simple)) {
        // `host_class.matches` is the catch-clause predicate where the
        // caller already knows `v` is thrown — its `Throwable` arm
        // returns true unconditionally. For `instance?` we additionally
        // require the value's tag to be a throwable carrier; nil and
        // non-throwable Values must not match `Throwable`.
        if (!isThrowableTag(v.tag())) return false;
        return host_class.matches(v, class_name);
    }

    if (matchNativeExact(v, simple)) return true;
    if (matchInterface(v, simple)) return true;
    if (matchUserType(v, simple)) return true;
    return false;
}

fn isThrowableTag(t: Tag) bool {
    return switch (t) {
        .ex_info => true,
        // PROVISIONAL: host_instance receiver arm pending D-048 host_class wire-up [refs: D-048, feature_deps.yaml#runtime/error/catch_class_host_instance_arm]
        else => false,
    };
}

fn matchNativeExact(v: Value, simple: []const u8) bool {
    const t = v.tag();
    // Heap-boxed Long and genuine BigInt share tag `.big_int`; the `origin`
    // flag disambiguates `(instance? Long …)` vs `(instance? BigInt …)`
    // (D-165 / ADR-0080). An inline Long (tag `.integer`) is handled by the
    // generic table below.
    if (t == .big_int) {
        const is_long = @import("numeric/big_int.zig").originOf(v) == .long;
        if (std.mem.eql(u8, simple, "Long")) return is_long;
        if (std.mem.eql(u8, simple, "BigInt")) return !is_long;
    }
    inline for (NATIVE_ENTRIES) |e| {
        if (std.mem.eql(u8, e.name, simple)) return t == e.tag;
    }
    return false;
}

/// True iff `name` is a callable class — a member of `clojure.lang.IFn` for
/// class-level `(isa? <class> IFn)` (ADR-0109). The cljw class names whose
/// instances are `ifn?`: fns (raw tag names), Keyword/Symbol/Var, and the
/// persistent collections (all invocable as lookups). Mirrors `core.ifnQ`.
pub fn isCallableClassName(name: []const u8) bool {
    const CALLABLE = [_][]const u8{
        "fn_val",             "builtin_fn",        "multi_fn",          "protocol_fn",
        "Keyword",            "Symbol",            "Var",               "PersistentVector",
        "PersistentArrayMap", "PersistentHashMap", "PersistentHashSet", "PersistentTreeMap",
        "PersistentTreeSet",
    };
    const simple = normalizeClassName(name);
    inline for (CALLABLE) |c| {
        if (std.mem.eql(u8, c, simple)) return true;
    }
    return false;
}

fn matchInterface(v: Value, simple: []const u8) bool {
    // Membership derives from the interface_membership SSOT (ADR-0116) so
    // instance? and extend-protocol-target distribution share one source
    // and cannot drift (D-317).
    return interface_membership.isMember(v.tag(), simple);
}

fn matchUserType(v: Value, simple: []const u8) bool {
    const td: *const TypeDescriptor = switch (v.tag()) {
        .typed_instance => v.decodePtr(*const TypedInstance).descriptor,
        .reified_instance => v.decodePtr(*const ReifiedInstance).descriptor,
        // ADR-0106: a stateful host object (java.util.Random) carries its
        // surface descriptor; its fqcn is FULL (java.util.Random), so match the
        // normalized simple form too.
        .host_instance => @import("host_instance.zig").asHostInstance(v).descriptor,
        else => return false,
    };
    var cursor: ?*const TypeDescriptor = td;
    while (cursor) |t| {
        if (t.fqcn) |fqcn| {
            if (std.mem.eql(u8, fqcn, simple)) return true;
            if (std.mem.eql(u8, normalizeClassName(fqcn), simple)) return true;
        }
        // ADR-0116 Decision B (∪ arm): a user deftype/reify that EXTENDS a
        // clojure.lang interface (e.g. IDeref) registers its method under the
        // bare cljw protocol name; match that against the normalised interface
        // name so `(instance? clojure.lang.IDeref user-inst)` is true. Mirrors
        // protocol.satisfies' name comparison; native membership stays primary,
        // this is the additive arm.
        for (t.method_table) |entry| {
            if (std.mem.eql(u8, entry.protocol_name, simple)) return true;
        }
        for (t.protocol_impls) |pn| {
            if (std.mem.eql(u8, pn, simple)) return true;
        }
        cursor = t.parent;
    }
    return false;
}

// --- tests ---

const testing = std.testing;

test "isKnown accepts native simple names + FQCNs" {
    try testing.expect(isKnown("String"));
    try testing.expect(isKnown("Long"));
    try testing.expect(isKnown("Pattern"));
    try testing.expect(isKnown("java.lang.String"));
    try testing.expect(isKnown("java.util.regex.Pattern"));
}

test "isKnown accepts interface names" {
    try testing.expect(isKnown("IFn"));
    try testing.expect(isKnown("Number"));
    try testing.expect(isKnown("IPersistentMap"));
    try testing.expect(isKnown("IPersistentSet"));
    try testing.expect(isKnown("IPersistentCollection"));
    try testing.expect(isKnown("IEditableCollection"));
    try testing.expect(isKnown("clojure.lang.IEditableCollection"));
    try testing.expect(isKnown("Iterable"));
    try testing.expect(isKnown("java.lang.Iterable"));
    // The interface-membership sweep (Seqable/Sequential/ISeq/Associative/…)
    inline for (.{ "Seqable", "Sequential", "ISeq", "Associative", "ILookup", "Indexed", "IPersistentVector", "IPersistentList", "IPersistentStack", "Named", "Reversible", "Sorted" }) |name| {
        try testing.expect(isKnown(name));
    }
    try testing.expect(isKnown("clojure.lang.Seqable"));
    try testing.expect(isKnown("clojure.lang.Associative"));
}

test "matchInterface: corrected + new interface membership" {
    // IPersistentMap/Set now include the sorted variants (were too narrow).
    try testing.expect(isInstance(Value.nil_val, "Sorted") == false);
    // Named: keywords + symbols only.
    // (value construction for collections needs a Runtime; the clj-verified
    // membership across all tags lives in corpus instance_interfaces.txt — this
    // test just locks the scalar-negative + name-resolution path.)
    try testing.expect(!isInstance(Value.initInteger(5), "Seqable"));
    try testing.expect(!isInstance(Value.initInteger(5), "Sequential"));
    try testing.expect(!isInstance(Value.initInteger(5), "ISeq"));
}

test "isKnown accepts java.io stream family + leaf class names (D-358)" {
    try testing.expect(isKnown("java.io.Reader"));
    try testing.expect(isKnown("java.io.BufferedReader"));
    try testing.expect(isKnown("java.io.FileInputStream"));
    try testing.expect(isKnown("java.io.PrintWriter"));
    try testing.expect(isKnown("java.io.ByteArrayOutputStream"));
    // Unknown io-shaped names still raise (no silent-default-shift).
    try testing.expect(!isKnown("java.io.RandomAccessFile"));
}

test "isKnown delegates Throwable hierarchy to host_class" {
    try testing.expect(isKnown("Throwable"));
    try testing.expect(isKnown("ExceptionInfo"));
    try testing.expect(isKnown("java.lang.RuntimeException"));
}

test "isKnown rejects unknown classes (no silent-default-shift)" {
    // PersistentQueue became known with ADR-0087 (it was the placeholder
    // "unknown" example before the queue landed).
    try testing.expect(!isKnown("java.lang.Object"));
    try testing.expect(!isKnown("FooBarException"));
    try testing.expect(!isKnown(""));
}

test "isInstance: native exact tag" {
    try testing.expect(isInstance(Value.initInteger(42), "Long"));
    try testing.expect(!isInstance(Value.initInteger(42), "String"));
    try testing.expect(!isInstance(Value.initInteger(42), "Double"));
    try testing.expect(isInstance(Value.true_val, "Boolean"));
}

test "isInstance: Throwable does NOT match non-throwable values" {
    // `host_class.matches` returns true for `Throwable` unconditionally
    // in catch-clause context; `class_name.isInstance` pre-checks the
    // value's tag is a throwable carrier so `nil` and ordinary values
    // return false (JVM `(instance? Throwable nil)` semantics).
    try testing.expect(!isInstance(Value.nil_val, "Throwable"));
    try testing.expect(!isInstance(Value.initInteger(42), "Throwable"));
    try testing.expect(!isInstance(Value.true_val, "Exception"));
}

test "isInstance: Number matches both integer and float" {
    try testing.expect(isInstance(Value.initInteger(42), "Number"));
    try testing.expect(isInstance(Value.initFloat(3.14), "Number"));
    try testing.expect(!isInstance(Value.true_val, "Number"));
}

test "isInstance: FQCN normalises to simple" {
    try testing.expect(isInstance(Value.initInteger(42), "java.lang.Long"));
    try testing.expect(isInstance(Value.initInteger(42), "java.lang.Number"));
}

test "isInstance: unknown class returns false defensively" {
    try testing.expect(!isInstance(Value.initInteger(42), "PersistentQueue"));
    try testing.expect(!isInstance(Value.initInteger(42), "FooBarClass"));
}

test "nativeTagFor: native exact-tag names + FQCN resolve" {
    try testing.expectEqual(@as(?Tag, .integer), nativeTagFor("Long"));
    try testing.expectEqual(@as(?Tag, .string), nativeTagFor("String"));
    try testing.expectEqual(@as(?Tag, .integer), nativeTagFor("java.lang.Long"));
    try testing.expectEqual(@as(?Tag, .regex), nativeTagFor("java.util.regex.Pattern"));
}

test "fqcnForTag is the inverse of nativeTagFor over NATIVE_ENTRIES" {
    // Every NATIVE_ENTRIES name round-trips name→tag→name (the D-204 SSOT
    // invariant that keeps `(class x)` and `(instance? Name x)` aligned).
    inline for (NATIVE_ENTRIES) |e| {
        try testing.expectEqual(@as(?Tag, e.tag), nativeTagFor(e.name));
        try testing.expectEqualStrings(e.name, fqcnForTag(e.tag).?);
    }
    // Numeric-tower classes now resolve (D-204 drift fix).
    try testing.expectEqual(@as(?Tag, .big_int), nativeTagFor("clojure.lang.BigInt"));
    try testing.expectEqualStrings("Pattern", fqcnForTag(.regex).?);
    try testing.expectEqualStrings("BigDecimal", fqcnForTag(.big_decimal).?);
    // A tag with no canonical class name → null (caller falls back to @tagName).
    try testing.expectEqual(@as(?[]const u8, null), fqcnForTag(.fn_val));
}

test "nativeTagFor: interface-shaped + unknown names do NOT resolve" {
    // Number/IFn span multiple tags — no single descriptor to resolve to.
    try testing.expectEqual(@as(?Tag, null), nativeTagFor("Number"));
    try testing.expectEqual(@as(?Tag, null), nativeTagFor("IFn"));
    // Throwable hierarchy is not a NATIVE_ENTRIES exact-tag class.
    try testing.expectEqual(@as(?Tag, null), nativeTagFor("Throwable"));
    try testing.expectEqual(@as(?Tag, null), nativeTagFor("FooBarClass"));
}
