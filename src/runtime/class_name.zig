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
//!   `LazySeq`, `Cons`, `Pattern`, `UUID`, `BigInt`, `Ratio`, `BigDecimal`).
//! - **Interface-shaped classes** (multi-tag match): `IFn`, `Number`,
//!   `IPersistentMap`, `IPersistentSet`, `IPersistentCollection`.
//! - **Throwable hierarchy**: delegates to `host_class.matches`
//!   (covers `Throwable` / `Exception` / `RuntimeException` /
//!   `ExceptionInfo` etc.).
//! - **User classes** (`defrecord` / `deftype` / `reify`) are NOT matched
//!   by name (ADR-0201). A user class is its TypeDescriptor, so membership
//!   in one is descriptor identity: `isInstanceOfClass` / `classIsaOf`,
//!   which take the class VALUE's descriptor. The name oracle below only
//!   answers which host interfaces a user type declares (its
//!   `protocol_impls` / `method_table`), and matches a descriptor's own
//!   fqcn only for a native host-surface descriptor.
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
    // clj's `(class (subvec …))` is APersistentVector$SubVector; the simple name
    // "SubVector" per AD-003 (ADR-0059 simple-name policy).
    .{ .name = "SubVector", .tag = .sub_vector },
    .{ .name = "MapEntry", .tag = .map_entry },
    .{ .name = "PersistentArrayMap", .tag = .array_map },
    .{ .name = "PersistentHashMap", .tag = .hash_map },
    .{ .name = "PersistentHashSet", .tag = .hash_set },
    // ADR-0194: these are real cljw value classes, not display-only labels.
    // Making the name↔tag relation exact lets tools.reader dispatch on the
    // clojure.lang interface spelling and makes instance? JVM-faithful.
    .{ .name = "LazySeq", .tag = .lazy_seq },
    .{ .name = "Cons", .tag = .cons },
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
    // ADR-0174 D4: a class VALUE's class is `Class` (clj: java.lang.Class;
    // AD-003 simple name). One row wires `(class Long)` → Class, bare
    // `Class` as a value, and `(instance? Class (class 5))` — the
    // instance-method surface (getName/…) already lives on
    // nativeDescriptor(.type_descriptor) via java/lang/Class.zig.
    .{ .name = "Class", .tag = .type_descriptor },
    // clojure.lang.MultiFn — a multimethod IS a distinct native class (1 tag →
    // 1 name), so it is an exact-tag `instance?` target (unlike the ambiguous
    // `Fn`, whose 3 fn tags share one display name and stay in displayClassName).
    // Lets `(instance? clojure.lang.MultiFn ct/report)` be true — the branch
    // clojure.test.check.clojure-test guards its multimethod reporting on.
    .{ .name = "MultiFn", .tag = .multi_fn },
};

/// FQCN → simple normalisation for native class names. Throwable
/// hierarchy normalisation happens inside `host_class.normalizeClassName`;
/// this table covers the non-Throwable Java + Clojure FQCNs we
/// recognise.
const FQCN_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ "java.lang.String", "String" },
    .{ "java.lang.Class", "Class" },
    .{ "java.lang.Long", "Long" },
    .{ "java.lang.Double", "Double" },
    .{ "java.lang.Boolean", "Boolean" },
    .{ "java.lang.Character", "Character" },
    .{ "java.lang.Number", "Number" },
    .{ "java.util.regex.Pattern", "Pattern" },
    .{ "java.util.UUID", "UUID" },
    .{ "clojure.lang.MultiFn", "MultiFn" },
    // java.util.Date is NOT here: Date values carry the canonical
    // rt.types["java.util.Date"] descriptor (ADR-0174 merge), whose fqcn IS
    // the FQCN — instance?/resolution match on it directly.
    .{ "clojure.lang.BigInt", "BigInt" },
    .{ "clojure.lang.Ratio", "Ratio" },
    .{ "java.math.BigDecimal", "BigDecimal" },
    .{ "clojure.lang.Keyword", "Keyword" },
    .{ "clojure.lang.Symbol", "Symbol" },
    .{ "clojure.lang.PersistentList", "PersistentList" },
    .{ "clojure.lang.PersistentVector", "PersistentVector" },
    .{ "clojure.lang.MapEntry", "MapEntry" },
    // clj's MapEntry implements java.util.Map$Entry; a lib importing the nested
    // class (flatland.ordered.map: `(:import (java.util Map$Entry))`) refers to it
    // bare or FQCN. Both map to the native MapEntry (tag .map_entry) — ADR-0128.
    .{ "java.util.Map$Entry", "MapEntry" },
    .{ "Map$Entry", "MapEntry" },
    .{ "clojure.lang.PersistentArrayMap", "PersistentArrayMap" },
    .{ "clojure.lang.PersistentHashMap", "PersistentHashMap" },
    .{ "clojure.lang.PersistentHashSet", "PersistentHashSet" },
    .{ "clojure.lang.LazySeq", "LazySeq" },
    .{ "clojure.lang.Cons", "Cons" },
    .{ "clojure.lang.PersistentTreeMap", "PersistentTreeMap" },
    .{ "clojure.lang.PersistentTreeSet", "PersistentTreeSet" },
    .{ "clojure.lang.Var", "Var" },
    .{ "clojure.lang.PersistentQueue", "PersistentQueue" },
    .{ "clojure.lang.IFn", "IFn" },
    .{ "clojure.lang.Fn", "Fn" },
    .{ "clojure.lang.IPersistentMap", "IPersistentMap" },
    .{ "clojure.lang.IRecord", "IRecord" },
    .{ "clojure.lang.IPersistentSet", "IPersistentSet" },
    .{ "clojure.lang.IPersistentCollection", "IPersistentCollection" },
    .{ "clojure.lang.IEditableCollection", "IEditableCollection" },
    .{ "java.lang.Iterable", "Iterable" },
    // java.lang.CharSequence: a String natively, else any value declaring it (a
    // StringBuilder's host_supertypes, a deftype such as instaparse's Segment),
    // which matchUserType finds under this simple name.
    .{ "java.lang.CharSequence", "CharSequence" },
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
    // Sorted/Navigable interfaces — host TreeMap/TreeSet only (D-466 follow-up).
    // No native cljw collection is a java.util.SortedMap/-Set (clj's native
    // sorted colls are clojure.lang.Sorted), so these match solely via the host
    // descriptors' host_supertypes.
    .{ "java.util.SortedMap", "SortedMap" },
    .{ "java.util.NavigableMap", "NavigableMap" },
    .{ "java.util.SortedSet", "SortedSet" },
    .{ "java.util.NavigableSet", "NavigableSet" },
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

/// `(class x)` / `(type x)` name for tags that are NOT `NATIVE_ENTRIES` exact
/// classes but ARE reachable as ordinary user values — callables, seq views,
/// reference types, transients. clj returns a generated/reify class for fns,
/// future, and promise that cljw has no analog for (AD-044); for the rest clj's
/// own simple class name is reproduced. Returns null for genuinely-internal
/// tags (HAMT nodes, chunk buffers, …) so `nativeFqcnFor`'s `@tagName` fallback
/// surfaces as a canary if such a value ever reaches `(class)`. This is the
/// SSOT consumed by `runtime.nativeFqcnFor` AFTER `fqcnForTag` (the divergent
/// names here are NOT in `NATIVE_ENTRIES`, so they never become `instance?`
/// targets — see `isInstance`).
pub fn displayClassName(tag: Tag) ?[]const u8 {
    return switch (tag) {
        .fn_val, .builtin_fn, .protocol_fn => "Fn",
        // `.multi_fn` is NOT here: it is a NATIVE_ENTRIES exact-tag class
        // ("MultiFn"), resolved by `fqcnForTag` before this fallback, so a
        // multimethod is an `instance?` target (see NATIVE_ENTRIES).
        .chunked_cons => "ChunkedSeq",
        .range => "LongRange",
        .string_seq => "StringSeq",
        .array_seq => "ArraySeq",
        .atom => "Atom",
        .agent => "Agent",
        .ref => "Ref",
        .@"volatile" => "Volatile",
        .future => "Future",
        .promise => "Promise",
        .delay => "Delay",
        .reduced => "Reduced",
        .ns => "Namespace",
        .transient_vector => "TransientVector",
        .transient_map => "TransientArrayMap",
        .transient_set => "TransientHashSet",
        .tagged_literal => "TaggedLiteral",
        else => null,
    };
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
/// 4. Descriptor walk for `.typed_instance` / `.reified_instance` /
///    `.host_instance` receivers: the interfaces a type declares, plus the
///    own fqcn of a native host-surface descriptor (see `matchUserType`).
///
/// This is the NAME oracle, for host / native classes. A user class is
/// never answered by name; callers holding a class VALUE go through
/// `isInstanceOfClass`, which routes a user class to descriptor identity.
/// Unknown class names return false here.
pub fn isInstance(v: Value, class_name: []const u8) bool {
    const simple = normalizeClassName(class_name);

    // ADR-0109/ADR-0128: java.lang.Object is the universal supertype — every
    // non-nil value is an instance (clj: nil is not). Handled here in the single
    // membership oracle so `-instance-of?` needs no special-case (ADR-0128).
    if (host_class.isUniversalClass(simple)) return v.tag() != .nil;

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

/// `(instance? C v)` for a class VALUE, where `class_td` is the descriptor `C`
/// evaluates to. The entry point for every caller that holds a class rather
/// than a name (`instance?`, `Class.isInstance`). A user class is answered by
/// identity (ADR-0201): `v` is a member iff `class_td` is `v`'s descriptor or on
/// its parent chain, so a redefined `R` and its previous vintage, or `aaa.Point`
/// and `bbb.Point`, never answer for each other. A host / native class has no
/// user descriptor and goes to the name oracle `isInstance`.
pub fn isInstanceOfClass(v: Value, class_td: *const TypeDescriptor) bool {
    if (class_td.isUserClass()) {
        const own = userInstanceDescriptor(v) orelse return false;
        return descendsFrom(own, class_td);
    }
    const name = class_td.fqcn orelse return false;
    return isInstance(v, name);
}

/// Class-vs-class `isa?` over class VALUES, shared by the `isa?` primitive and
/// multimethod dispatch so the two cannot drift (D-464). Identity first. A
/// user-class PARENT is reached only along `child`'s parent chain. A user-class
/// CHILD under a host parent is a subclass of Object and of what it declares
/// (`descriptorIsa`, the relation `instance?` reads), never of a host class that
/// merely shares its simple name: a `(deftype BigInt [])` is not a Number. Only
/// a native child keeps the name relation `classIsa` (ADR-0201).
pub fn classIsaOf(child: *const TypeDescriptor, parent: *const TypeDescriptor) bool {
    if (child == parent) return true;
    if (parent.isUserClass()) return descendsFrom(child, parent);
    const parent_name = parent.fqcn orelse return false;
    if (child.isUserClass()) {
        const simple = normalizeClassName(parent_name);
        return host_class.isUniversalClass(simple) or descriptorIsa(child, simple);
    }
    return classIsa(child.fqcn orelse "", parent_name);
}

/// The descriptor a user-class instance carries, or null for any other value
/// (a host_instance's descriptor is a native surface, never a user class).
fn userInstanceDescriptor(v: Value) ?*const TypeDescriptor {
    return switch (v.tag()) {
        .typed_instance => v.decodePtr(*const TypedInstance).descriptor,
        .reified_instance => v.decodePtr(*const ReifiedInstance).descriptor,
        else => null,
    };
}

/// True iff `ancestor` is `td` itself or on `td`'s parent chain, by pointer.
fn descendsFrom(td: *const TypeDescriptor, ancestor: *const TypeDescriptor) bool {
    var cursor: ?*const TypeDescriptor = td;
    while (cursor) |t| : (cursor = t.parent) {
        if (t == ancestor) return true;
    }
    return false;
}

fn isThrowableTag(t: Tag) bool {
    return switch (t) {
        .ex_info => true,
        // host_instance is deliberately NOT throwable: cljw's host exception
        // classes construct ex_info carriers (the allocException path), and
        // the analyzer rejects a non-exception catch class, so no
        // host_instance reaches a throwable check. `false` is the finished form.
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

/// True iff `name` is a callable class, a member of `clojure.lang.IFn` for
/// class-level `(isa? <class> IFn)` (ADR-0109): `Fn`, the one display name the
/// fn / builtin / protocol-fn tags share (D-337), or a native class whose tag
/// is in IFn's `interface_membership` set, so `(isa? (class x) IFn)` and
/// `(ifn? x)` cannot drift.
pub fn isCallableClassName(name: []const u8) bool {
    const simple = normalizeClassName(name);
    if (std.mem.eql(u8, simple, "Fn")) return true;
    return isClassInterfaceMember(simple, "IFn");
}

/// Class-level interface membership (D-293): true iff instances of the NATIVE
/// class `child` (resolved to its tag) are members of the `interface` marker —
/// the class-level analog of `isInstance`/`matchInterface`, sharing the
/// `interface_membership` SSOT so `(isa? <class> Seqable)` and
/// `(instance? Seqable x)` cannot drift. Returns false for a non-native child
/// (user deftype/reify resolves via the descriptor walk, not the native table)
/// or a non-interface `interface` name (so callers can probe unconditionally and
/// fall through). Both args may be simple or FQCN.
pub fn isClassInterfaceMember(child: []const u8, interface: []const u8) bool {
    const tag = nativeTagFor(child) orelse displayClassTag(child) orelse return false;
    return interface_membership.isMember(tag, normalizeClassName(interface));
}

/// Inverse of `displayClassName` for the seq-view and transient class names,
/// the names `(class x)` reports for values that are NOT `NATIVE_ENTRIES`
/// exact-tag classes. Lets `isClassInterfaceMember` resolve e.g.
/// `(isa? (class (range 3)) Seqable)` or `(isa? (class (transient [])) Counted)`.
/// Refs (Atom/Ref/…) are omitted, as they implement no collection interface,
/// and so is the ambiguous `Fn` (see `isCallableClassName`).
fn displayClassTag(name: []const u8) ?Tag {
    const M = std.StaticStringMap(Tag).initComptime(.{
        .{ "LazySeq", .lazy_seq },                 .{ "LongRange", .range },
        .{ "ChunkedSeq", .chunked_cons },          .{ "Cons", .cons },
        .{ "StringSeq", .string_seq },             .{ "ArraySeq", .array_seq },
        .{ "TransientVector", .transient_vector }, .{ "TransientArrayMap", .transient_map },
        .{ "TransientHashSet", .transient_set },
    });
    return M.get(name);
}

/// Class-vs-class `isa?` BY NAME, for a host / native parent: the name half of
/// `classIsaOf`, which is the entry both `core.classIsaPrim` (the `isa?`
/// primitive) and `multimethod.isaCheck` (method dispatch) call so the two
/// cannot drift (D-464: a `(defmethod f java.lang.Number)` must be found for a
/// `Long` dispatch value exactly as `(isa? Long Number)` is true). Order mirrors
/// clj's isa? class step: identity, universal Object, narrow Number, narrow IFn,
/// interface-marker membership, then the host exception/parent hierarchy. The
/// ad-hoc `derive` hierarchy and non-class isa? stay with the callers.
fn classIsa(child: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, child, parent)) return true;
    if (host_class.isUniversalClass(parent)) return true;
    if (host_class.isNumberClass(parent)) return host_class.isNumericClass(child);
    if (host_class.isIFnClass(parent)) return isCallableClassName(child);
    if (isClassInterfaceMember(child, parent)) return true;
    return host_class.isSubclassOf(normalizeClassName(child), normalizeClassName(parent));
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
    return descriptorIsa(td, simple);
}

/// True iff a value whose descriptor is `td` is an instance of the host class
/// named `simple` (normalised). The descriptor-level half of `matchUserType`,
/// shared with `classIsaOf` so `(instance? C x)` and `(isa? (class x) C)` read
/// ONE relation. A user class answers only from what it DECLARES (its
/// interfaces), never from its own name; a native host-surface descriptor also
/// answers to its own fqcn (ADR-0201).
fn descriptorIsa(td: *const TypeDescriptor, simple: []const u8) bool {
    var cursor: ?*const TypeDescriptor = td;
    while (cursor) |t| {
        // Only a native host-surface descriptor is its NAME. A user class's
        // fqcn is a display string it may share with a host interface (a
        // `(deftype Sorted [])` is not `clojure.lang.Sorted`) or with another
        // user class, so it never answers here (ADR-0201).
        if (!t.isUserClass()) {
            if (t.fqcn) |fqcn| {
                if (std.mem.eql(u8, fqcn, simple)) return true;
                if (std.mem.eql(u8, normalizeClassName(fqcn), simple)) return true;
            }
        }
        // The declared interfaces (ADR-0116 Decision B). `protocol_impls` holds
        // what the type DECLARED; the method table is not consulted, because a
        // protocol_remap method is installed under the cljw protocol that
        // dispatches it (a Counted `count` under IPersistentCollection), which
        // is not an interface the type implements.
        for (t.protocol_impls) |pn| {
            if (declaredNameIs(pn, simple)) return true;
        }
        if (t.kind == .defrecord) {
            for (RECORD_INTERFACES) |n| {
                if (declaredNameIs(n, simple)) return true;
            }
        }
        // Host supertype markers (D-466): `(instance? java.util.Map hm)` for a
        // java.util.HashMap host_instance. Comptime-const list, instance?-only.
        for (t.host_supertypes) |sup| {
            if (declaredNameIs(sup, simple)) return true;
        }
        cursor = t.parent;
    }
    return false;
}

/// The recognised interfaces every defrecord implements without naming them
/// (clj's defrecord emits IRecord, IHashEq, IObj, ILookup, IKeywordLookup,
/// IPersistentMap, java.util.Map and Serializable; IKeywordLookup is not a
/// recognised name). IPersistentMap brings Counted, Associative and the
/// rest of its closure, so `(counted? rec)` and `(coll? rec)` are true.
const RECORD_INTERFACES = [_][]const u8{ "IRecord", "IPersistentMap", "IObj", "ILookup", "IHashEq", "Map", "Serializable" };

/// True iff a declared name (a `protocol_impls` or `host_supertypes` entry)
/// makes its type an instance of the class `simple`: it names that class, or an
/// interface that extends it (clj's superinterface closure,
/// `interface_membership.SUPERS`), so a type declaring `Indexed` is Counted.
/// A protocol_remap declaration may record a qualified name
/// (`clojure.lang.IPersistentMap`), so the simple form is matched too.
fn declaredNameIs(declared: []const u8, simple: []const u8) bool {
    if (std.mem.eql(u8, declared, simple)) return true;
    const norm = normalizeClassName(declared);
    if (std.mem.eql(u8, norm, simple)) return true;
    return interface_membership.extendsInterface(norm, simple);
}

/// `(instance? <iface> v)` for a comptime-known interface: the form of the core
/// predicates clj defines as instance checks (`seq?` = ISeq, `counted?` =
/// Counted, `vector?` = IPersistentVector, ...). A native value answers from
/// its tag (interface_membership, resolved at comptime, so the hot path is a
/// tag compare); a deftype / reify / host object answers from its declared
/// interfaces through the same `matchUserType` walk `instance?` uses, so for
/// every recognised interface this IS `isInstance`, and the predicate and
/// `instance?` cannot disagree.
pub fn implementsInterface(v: Value, comptime iface: []const u8) bool {
    const t = v.tag();
    if (interface_membership.isNativeMember(t, iface)) return true;
    return switch (t) {
        .typed_instance, .reified_instance, .host_instance => matchUserType(v, iface),
        else => false,
    };
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

test "MultiFn is an exact-tag native class (blocker 4: instance? clojure.lang.MultiFn)" {
    // A multimethod resolves 1 tag → 1 name, so it is a real `instance?` target
    // (test.check.clojure-test guards `(instance? clojure.lang.MultiFn ct/report)`).
    try testing.expectEqual(@as(?Tag, .multi_fn), nativeTagFor("MultiFn"));
    try testing.expectEqual(@as(?Tag, .multi_fn), nativeTagFor("clojure.lang.MultiFn"));
    try testing.expectEqualStrings("MultiFn", fqcnForTag(.multi_fn).?);
    try testing.expect(isKnown("MultiFn"));
    try testing.expect(isKnown("clojure.lang.MultiFn"));
    // Still a callable class so `(isa? (class my-multi) IFn)` holds.
    try testing.expect(isCallableClassName("MultiFn"));
    // `Fn` remains ambiguous (3 tags share it) and stays a NON-instance? name.
    try testing.expectEqual(@as(?Tag, null), nativeTagFor("Fn"));
}

test "LazySeq and Cons are exact-tag native classes (ADR-0194)" {
    try testing.expectEqual(@as(?Tag, .lazy_seq), nativeTagFor("LazySeq"));
    try testing.expectEqual(@as(?Tag, .lazy_seq), nativeTagFor("clojure.lang.LazySeq"));
    try testing.expectEqualStrings("LazySeq", fqcnForTag(.lazy_seq).?);
    try testing.expectEqual(@as(?Tag, .cons), nativeTagFor("Cons"));
    try testing.expectEqual(@as(?Tag, .cons), nativeTagFor("clojure.lang.Cons"));
    try testing.expectEqualStrings("Cons", fqcnForTag(.cons).?);
    try testing.expect(isKnown("clojure.lang.LazySeq"));
    try testing.expect(isKnown("clojure.lang.Cons"));
}

test "isCallableClassName derives from the IFn tag set" {
    try testing.expect(isCallableClassName("Fn"));
    try testing.expect(isCallableClassName("clojure.lang.PersistentVector"));
    try testing.expect(isCallableClassName("SubVector"));
    try testing.expect(isCallableClassName("MapEntry"));
    try testing.expect(isCallableClassName("TransientVector"));
    try testing.expect(isCallableClassName("TransientHashSet"));
    try testing.expect(!isCallableClassName("PersistentList"));
    try testing.expect(!isCallableClassName("PersistentQueue"));
    try testing.expect(!isCallableClassName("LazySeq"));
    try testing.expect(isClassInterfaceMember("TransientArrayMap", "Counted"));
    try testing.expect(!isClassInterfaceMember("Cons", "Counted"));
}

test "ADR-0201: a user class is matched by descriptor identity, never by its simple name" {
    const Runtime = @import("runtime.zig").Runtime;
    const td_mod = @import("type_descriptor.zig");
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    // Two vintages of user.R, plus a namesake in another namespace.
    const old = try td_mod.registerType(&rt, "R", "user", &.{"a"}, &.{}, .defrecord);
    const old_inst = try td_mod.allocInstance(&rt, old, &.{Value.initInteger(1)});
    const new = try td_mod.registerType(&rt, "R", "user", &.{ "a", "b" }, &.{}, .defrecord);
    const namesake = try td_mod.registerType(&rt, "R", "other", &.{"a"}, &.{}, .defrecord);
    try testing.expect(old != new);

    try testing.expect(isInstanceOfClass(old_inst, old));
    try testing.expect(!isInstanceOfClass(old_inst, new));
    try testing.expect(!isInstanceOfClass(old_inst, namesake));
    try testing.expect(!isInstanceOfClass(Value.initInteger(1), old));
    try testing.expect(classIsaOf(old, old));
    try testing.expect(!classIsaOf(old, new));
    try testing.expect(!classIsaOf(new, old));
    try testing.expect(!classIsaOf(namesake, old));
    // The name oracle no longer answers for a user class by its display name.
    try testing.expect(!isInstance(old_inst, "R"));

    // Under a host parent a user class is an Object, and is NOT the subclass of
    // a host class that merely shares its simple name.
    const object = try rt.classDescriptor("Object");
    try testing.expect(classIsaOf(old, object));
    try testing.expect(isInstanceOfClass(old_inst, object));
    const user_big_int = try td_mod.registerType(&rt, "BigInt", "user", &.{}, &.{}, .deftype);
    try testing.expect(!classIsaOf(user_big_int, try rt.classDescriptor("Number")));
    try testing.expect(classIsaOf(user_big_int, object));

    // A reify descriptor has no name at all and is still its own class.
    const reify_td: TypeDescriptor = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    const reified = try td_mod.allocReifiedInstance(&rt, &reify_td);
    try testing.expect(isInstanceOfClass(reified, &reify_td));
    try testing.expect(!isInstanceOfClass(reified, old));
    try testing.expect(classIsaOf(&reify_td, object));
}
