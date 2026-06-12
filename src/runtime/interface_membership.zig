// SPDX-License-Identifier: EPL-2.0
//! Native `instance?` membership SSOT: which native `Value.Tag`s implement each
//! recognised `clojure.lang.*` / `java.*` interface (ADR-0116, F-013).
//!
//! This is the SINGLE in-code source for "is value v (by its tag) an instance of
//! interface X". `class_name.zig` derives ALL of its interface consumers from
//! this table — `matchInterface` (membership), `isInterfaceName` / `isKnown`
//! (the recognised-name set). `host_interface.zig` derives the extend-protocol-
//! TARGET native-tag distribution for the interfaces where the two agree
//! (ISeq / Named / IPersistentMap — D-317 partial). One table → the consumers
//! cannot drift apart (the D-317 hazard).
//!
//! ## Representation choice (ADR-0116 Decision A)
//!
//! A forward `{ name, tags }` table, NOT an inverse exhaustive `switch
//! (Value.Tag)`: `zig_tips.md` rules that wide value-dispatch enums (`Value.Tag`,
//! heading 54→64 slots per F-004) use `else =>`, not exhaustive enumeration — a
//! new tag is MEANT to fall through (no membership) until its primitives are
//! wired in, at which point its interface rows are added here.
//!
//! ## Co-membership (ADR-0116 R2 trap)
//!
//! Interfaces that share a tag set (IPersistentCollection/Seqable/Iterable,
//! Associative/ILookup, Indexed/IPersistentVector, IPersistentMap/Map, …) point
//! at ONE shared constant — the set is authored once, so no within-SSOT drift.
//!
//! ## Scope (ADR-0116 Decision D — IObj / IMeta NOT yet active)
//!
//! IObj / IMeta membership is enumerated below but INACTIVE (no table row),
//! gated on D-271: clj guarantees `(instance? IObj x)` ⟹ `(with-meta x m)`, but
//! cljw's `.range`/`.chunked_cons` substrate has no meta slot (D-271), so
//! claiming the membership would break F-011. The full oracle-verified sets are
//! recorded so the closed set is 網羅-complete (F-013 cl.4) — only activation
//! waits. clj-verified (`clj` oracle, 2026-06-08):
//!   IObj  = promise, future + most collections/seqs (vector, list, set,
//!           sorted_map, sorted_set, persistent_queue, cons, lazy_seq, range,
//!           chunked_cons, array_map, hash_map, string_seq, array_seq) + symbol
//!           + fn tags. EXCLUDES map_entry, keyword, delay.
//!   IMeta = IObj ∪ { atom, agent, ref, var_ref, ns }.

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Tag = Value.Tag;

// --- shared tag-set constants (co-membership: authored once) ---

/// IPersistentCollection / Seqable / Iterable — every persistent collection + seq
/// (clj-verified across all collection/seq tags).
const COLL_AND_SEQ = [_]Tag{ .list, .cons, .lazy_seq, .chunked_cons, .vector, .array_map, .hash_map, .sorted_map, .hash_set, .sorted_set, .persistent_queue, .range, .string_seq, .array_seq, .map_entry };
/// IPersistentMap / java.util.Map.
const MAP_TAGS = [_]Tag{ .array_map, .hash_map, .sorted_map };
/// IPersistentSet / java.util.Set.
const SET_TAGS = [_]Tag{ .hash_set, .sorted_set };
/// Associative / ILookup — key→value lookup colls (maps + indexed vector +
/// map_entry; sets are NOT Associative).
const ASSOC_TAGS = [_]Tag{ .vector, .map_entry, .array_map, .hash_map, .sorted_map };
/// Indexed / IPersistentVector — vector + map_entry (a MapEntry is a [k v]
/// IPersistentVector). NOTE: the extend-protocol-TARGET set for IPersistentVector
/// is {vector} ONLY (host_interface.nativeExtendTags) — distributing to map_entry
/// is the D-317 residual, see ADR-0116 Decision C.
const INDEXED_TAGS = [_]Tag{ .vector, .map_entry };
/// ISeq — the seq views + list (a PersistentList is a seq); NOT vector/maps/sets.
const ISEQ_TAGS = [_]Tag{ .list, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq };
/// Sequential — ordered colls + seqs (NOT maps/sets); kept in sync with
/// `sequential?` (lang/primitive/core.zig).
const SEQUENTIAL_TAGS = [_]Tag{ .vector, .map_entry, .list, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq, .persistent_queue };
/// IFn — every callable (mirrors core.ifnQ): fns + keyword/symbol/var + the
/// persistent colls (all invocable as lookups).
const IFN_TAGS = [_]Tag{ .fn_val, .builtin_fn, .multi_fn, .protocol_fn, .keyword, .symbol, .var_ref, .vector, .array_map, .hash_map, .hash_set, .sorted_map, .sorted_set };
/// Number — the full numeric tower (mirrors `number?` / `(instance? Number x)`):
/// inline Long/Double + heap BigInt/Ratio/BigDecimal. (Was `{integer, float}`;
/// widened with ADR-0128 so `isInstance("Number")` IS `number?` and the macro's
/// opaque/Number special-case dissolves into this SSOT.)
const NUMBER_TAGS = [_]Tag{ .integer, .float, .big_int, .ratio, .big_decimal };
/// IPersistentList — a PersistentQueue is an IPersistentList in clj.
const IPLIST_TAGS = [_]Tag{ .list, .cons, .persistent_queue };
/// IPersistentStack — peek/pop: list, vector, queue, cons, map_entry.
const ISTACK_TAGS = [_]Tag{ .vector, .list, .cons, .map_entry, .persistent_queue };
const NAMED_TAGS = [_]Tag{ .keyword, .symbol };
/// Reversible — rseq-able: vector + sorted colls + map_entry.
const REVERSIBLE_TAGS = [_]Tag{ .vector, .map_entry, .sorted_map, .sorted_set };
const SORTED_TAGS = [_]Tag{ .sorted_map, .sorted_set };
/// IEditableCollection — `transient`-able: vector + unsorted maps/sets.
const EDITABLE_TAGS = [_]Tag{ .vector, .array_map, .hash_map, .hash_set };
/// java.util.List — clj-verified membership (a MapEntry IS a 2-vector List).
const JLIST_TAGS = [_]Tag{ .list, .cons, .lazy_seq, .chunked_cons, .vector, .range, .string_seq, .array_seq, .map_entry };
/// java.util.Collection — maps excluded (JVM: Map does not extend Collection).
const JCOLLECTION_TAGS = [_]Tag{ .list, .cons, .lazy_seq, .chunked_cons, .vector, .hash_set, .sorted_set, .persistent_queue, .range, .string_seq, .array_seq, .map_entry };

// --- deref / pending / ref family (ADR-0116; clj-oracle 2026-06-08) ---

/// IDeref — every deref-able value.
const IDEREF_TAGS = [_]Tag{ .atom, .agent, .ref, .@"volatile", .future, .promise, .reduced, .delay, .var_ref };
/// IRef — watchable/validatable refs (a subset of IDeref).
const IREF_TAGS = [_]Tag{ .atom, .agent, .ref, .var_ref };
/// IReference — meta-mutable refs (IRef ∪ Namespace).
const IREFERENCE_TAGS = [_]Tag{ .atom, .agent, .ref, .var_ref, .ns };
/// IPending — realized?-able: delay/future/promise + a (non-chunked) lazy seq.
const IPENDING_TAGS = [_]Tag{ .delay, .future, .promise, .lazy_seq };
/// IBlockingDeref — a blocking deref (with timeout): future + promise.
const IBLOCKING_TAGS = [_]Tag{ .future, .promise };

/// IObj — ACTIVATED 2026-06-13 (ADR-0134 value-driven slice; pullers:
/// instaparse's safe-with-meta + clojure.datafy's guard). Limited to the
/// tags where `(with-meta x m)` WORKS today (measured live), preserving
/// clj's `(instance? IObj x)` ⟹ with-meta-works invariant — the
/// not-yet-metable clj-IObj tags (range, chunked_cons, sorted colls,
/// queue, string_seq/array_seq, promise/future, fns) answer false until
/// their meta slots land (the remaining ADR-0134 substrates). A deftype
/// DECLARING clojure.lang.IObj answers true via matchUserType regardless.
const IOBJ_TAGS = [_]Tag{ .vector, .list, .lazy_seq, .hash_set, .array_map, .hash_map, .symbol };
/// IMeta — meta-READABLE: the metable IObj set ∪ the reference family.
const IMETA_TAGS = [_]Tag{ .vector, .list, .lazy_seq, .hash_set, .array_map, .hash_map, .symbol, .atom, .agent, .ref, .var_ref, .ns };

/// One interface → its native implementor tag set.
pub const Entry = struct { name: []const u8, tags: []const Tag };

/// The recognised-interface closed set. Simple (un-namespaced) names; callers
/// normalise FQCNs to simple first (class_name.normalizeClassName / the strip in
/// `tagsFor`). Co-membership names share a `tags` constant.
pub const TABLE = [_]Entry{
    .{ .name = "IFn", .tags = &IFN_TAGS },
    .{ .name = "Number", .tags = &NUMBER_TAGS },
    .{ .name = "IPersistentMap", .tags = &MAP_TAGS },
    .{ .name = "Map", .tags = &MAP_TAGS },
    .{ .name = "IPersistentSet", .tags = &SET_TAGS },
    .{ .name = "Set", .tags = &SET_TAGS },
    .{ .name = "IPersistentCollection", .tags = &COLL_AND_SEQ },
    .{ .name = "Seqable", .tags = &COLL_AND_SEQ },
    .{ .name = "Iterable", .tags = &COLL_AND_SEQ },
    .{ .name = "Sequential", .tags = &SEQUENTIAL_TAGS },
    .{ .name = "ISeq", .tags = &ISEQ_TAGS },
    .{ .name = "Associative", .tags = &ASSOC_TAGS },
    .{ .name = "ILookup", .tags = &ASSOC_TAGS },
    .{ .name = "Indexed", .tags = &INDEXED_TAGS },
    .{ .name = "IPersistentVector", .tags = &INDEXED_TAGS },
    .{ .name = "IPersistentList", .tags = &IPLIST_TAGS },
    .{ .name = "IPersistentStack", .tags = &ISTACK_TAGS },
    .{ .name = "Named", .tags = &NAMED_TAGS },
    .{ .name = "Reversible", .tags = &REVERSIBLE_TAGS },
    .{ .name = "Sorted", .tags = &SORTED_TAGS },
    .{ .name = "IEditableCollection", .tags = &EDITABLE_TAGS },
    .{ .name = "IObj", .tags = &IOBJ_TAGS },
    .{ .name = "IMeta", .tags = &IMETA_TAGS },
    .{ .name = "List", .tags = &JLIST_TAGS },
    .{ .name = "Collection", .tags = &JCOLLECTION_TAGS },
    // deref / pending / ref family (D-308)
    .{ .name = "IDeref", .tags = &IDEREF_TAGS },
    .{ .name = "IRef", .tags = &IREF_TAGS },
    .{ .name = "IReference", .tags = &IREFERENCE_TAGS },
    .{ .name = "IPending", .tags = &IPENDING_TAGS },
    .{ .name = "IBlockingDeref", .tags = &IBLOCKING_TAGS },
};

/// Strip a recognised host package prefix so both `ISeq` and `clojure.lang.ISeq`
/// resolve. class_name passes an already-simple name (no-op here); host_interface
/// passes the raw symbol. Unknown prefixes pass through unchanged.
pub fn simpleOf(name: []const u8) []const u8 {
    inline for (.{ "clojure.lang.", "java.util.", "java.lang.", "java.io." }) |pfx| {
        if (std.mem.startsWith(u8, name, pfx)) return name[pfx.len..];
    }
    return name;
}

/// The native tag set for `name` (simple or FQCN), or null if `name` is not a
/// recognised interface.
pub fn tagsFor(name: []const u8) ?[]const Tag {
    const simple = simpleOf(name);
    for (TABLE) |e| {
        if (std.mem.eql(u8, e.name, simple)) return e.tags;
    }
    return null;
}

/// True iff value-tag `t` is a native implementor of interface `name`.
pub fn isMember(t: Tag, name: []const u8) bool {
    const tags = tagsFor(name) orelse return false;
    for (tags) |x| if (x == t) return true;
    return false;
}

/// True iff `name` is a recognised interface (drives class_name.isInterfaceName /
/// isKnown — retires the former hand-maintained `or`-chain).
pub fn isInterface(name: []const u8) bool {
    return tagsFor(name) != null;
}

/// Comptime conversion of a tag set to its @tagName strings, for the extend-
/// protocol-TARGET distribution (which addresses native descriptors by name).
fn tagNames(comptime tags: []const Tag) []const []const u8 {
    comptime {
        var arr: [tags.len][]const u8 = undefined;
        for (tags, 0..) |tg, i| arr[i] = @tagName(tg);
        const final = arr;
        return &final;
    }
}

/// Tag-NAME slices for the interfaces host_interface.nativeExtendTags distributes
/// (D-317 partial: ISeq / Named / IPersistentMap derive from the same SSOT
/// class_name.matchInterface uses, so the lists live in ONE place). IPersistentVector
/// is NOT here — its extend-target set is {vector} only, kept explicit in
/// host_interface (ADR-0116 Decision C / D-317 residual).
pub const ISEQ_NAMES = tagNames(&ISEQ_TAGS);
pub const NAMED_NAMES = tagNames(&NAMED_TAGS);
pub const MAP_NAMES = tagNames(&MAP_TAGS);

// --- tests ---

const testing = std.testing;

test "deref family membership (clj-oracle-grounded)" {
    try testing.expect(isMember(.atom, "IDeref"));
    try testing.expect(isMember(.delay, "IDeref"));
    try testing.expect(isMember(.@"volatile", "IDeref"));
    try testing.expect(isMember(.reduced, "IDeref"));
    try testing.expect(!isMember(.integer, "IDeref"));
    try testing.expect(!isMember(.vector, "IDeref"));
    // IRef ⊂ IDeref (delay is NOT IRef).
    try testing.expect(isMember(.atom, "IRef"));
    try testing.expect(!isMember(.delay, "IRef"));
    // IReference = IRef ∪ ns.
    try testing.expect(isMember(.ns, "IReference"));
    try testing.expect(!isMember(.ns, "IRef"));
    // IPending = delay/future/promise + lazy_seq.
    try testing.expect(isMember(.delay, "IPending"));
    try testing.expect(isMember(.lazy_seq, "IPending"));
    try testing.expect(!isMember(.atom, "IPending"));
    try testing.expect(!isMember(.range, "IPending"));
    try testing.expect(isMember(.future, "IBlockingDeref"));
    try testing.expect(!isMember(.delay, "IBlockingDeref"));
}

test "FQCN-prefixed names resolve identically to simple" {
    try testing.expect(isMember(.atom, "clojure.lang.IDeref"));
    try testing.expect(isInterface("clojure.lang.ISeq"));
    try testing.expect(isInterface("java.util.Map"));
}

test "IFn keeps the full callable set (regression guard for the reverted satisfies? bug)" {
    try testing.expect(isMember(.keyword, "IFn"));
    try testing.expect(isMember(.vector, "IFn"));
    try testing.expect(isMember(.fn_val, "IFn"));
    try testing.expect(!isMember(.integer, "IFn"));
}

test "co-membership interfaces share a set" {
    // IPersistentCollection / Seqable / Iterable are one set.
    inline for (.{ "IPersistentCollection", "Seqable", "Iterable" }) |n| {
        try testing.expect(isMember(.vector, n));
        try testing.expect(isMember(.range, n));
        try testing.expect(!isMember(.integer, n));
    }
    // Associative / ILookup.
    try testing.expect(isMember(.array_map, "Associative"));
    try testing.expect(isMember(.array_map, "ILookup"));
    try testing.expect(!isMember(.hash_set, "Associative"));
}

test "isInterface bounds the recognised set" {
    try testing.expect(isInterface("IDeref"));
    try testing.expect(isInterface("IFn"));
    try testing.expect(!isInterface("String")); // a native exact class, not an interface
    try testing.expect(!isInterface("NotARealInterface"));
}

test "extend-target tag-name derivation matches the ISeq tag set" {
    try testing.expectEqual(@as(usize, ISEQ_TAGS.len), ISEQ_NAMES.len);
    try testing.expectEqualStrings("list", ISEQ_NAMES[0]);
    try testing.expectEqualStrings("keyword", NAMED_NAMES[0]);
    try testing.expectEqualStrings("symbol", NAMED_NAMES[1]);
}
