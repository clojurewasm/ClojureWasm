// SPDX-License-Identifier: EPL-2.0
//! Host-supertype / interface recognition for `deftype`/`reify`/`extend-type`
//! impl-spec heads (ADR-0102, F-013).
//!
//! This module is the SINGLE in-code read point for "is this name a recognised
//! host supertype marker, and how does it route". The macro lowering
//! (`isHostMarker`) and the `__reify!`/`__extend-type!` primitives consult it
//! instead of hand-coding `std.mem.eql(name, "Object")` at scattered sites — the
//! scatter is the 個別最適化 entry F-013 clause 3 forbids.
//!
//! SSOT-of-record is `host_interfaces.yaml` (the reviewable closed set with
//! `derives_from` notes); `scripts/check_host_interface.sh` gates that the names
//! recognised HERE are a subset of the YAML rows (set-bound) and that every
//! `recognised: true` row is actually present here (no over-claim).
//!
//! `Object` / `clojure.lang.*` are MARKER NAMES selecting a dispatch family,
//! NOT real host classes (ADR-0059 / AD-003 — cljw has no JVM Class) and NOT
//! cljw protocol Vars (which resolve through the ordinary `.protocol` path).

const std = @import("std");
const interface_membership = @import("interface_membership.zig");

/// The three ways a recognised host-supertype name is handled (ADR-0102):
///   - method_family: `Object` — quote-wrapped; methods registered under the
///     canonical name ("Object") and read by a direct dispatch consult
///     (print.zig's str/toString). NOT a cljw protocol Var.
///   - marker: `clojure.lang.MapEquivalence`, `java.io.Serializable` —
///     quote-wrapped, zero methods, just records "implements X".
///   - protocol_remap: `clojure.lang.ILookup` etc. — NOT quote-wrapped; the
///     macro REWRITES the section into bare cljw-protocol section(s), translating
///     each clj method to its (cljw-protocol, cljw-method) target. The primitive
///     never sees the qualified name.
pub const Kind = enum {
    method_family,
    marker,
    protocol_remap,
    /// A no-JVM java host interface (java.util.Map, java.lang.Iterable) a deftype
    /// declares for java-interop. Recognised so the deftype loads; its methods are
    /// accepted-and-recorded but NEVER dispatched (cljw has no java-interop, ADR-0059
    /// / ADR-0103). Reserved for FULLY-inert interfaces; a mixed one uses protocol_remap.
    host_inert,
};

/// One clj method's target in cljw's protocol surface (protocol_remap only).
/// `protocol` is the bare cljw protocol Var name the method registers under;
/// `method` is cljw's dispatch method name. clj groups methods by interface, but
/// cljw splits them across protocols (e.g. clj IPersistentMap's `count` → cljw
/// IPersistentCollection/`-count`), so the target carries BOTH (D-280).
pub const MethodRemap = struct { clj: []const u8, protocol: []const u8, method: []const u8 };

/// A recognised host-supertype name and how it is handled. `canonical` is a
/// process-lifetime literal (the borrowed `MethodEntry.protocol_name` contract).
/// `wired_methods` applies to method_family; `remap` to protocol_remap.
pub const HostInterface = struct {
    kind: Kind,
    canonical: []const u8,
    wired_methods: []const []const u8 = &.{},
    remap: []const MethodRemap = &.{},

    /// protocol_remap: the (cljw-protocol, cljw-method) target for a clj method,
    /// or null when the interface declares no mapping for it (→ the caller raises
    /// feature_not_supported rather than silently dropping the impl).
    pub fn remapMethod(self: HostInterface, clj: []const u8) ?MethodRemap {
        for (self.remap) |r| if (std.mem.eql(u8, r.clj, clj)) return r;
        return null;
    }
};

// `hasheq` (clojure.lang.IHashEq, D-280d5) joins the Object method-family: clj's
// `(hash x)` uses hasheq (hashCode is the Java method). cljw has one value-hash, so
// hashFn consults hasheq → hashCode → valueHash. Distinct method names avoid the
// (Object, hashCode) collision when a type declares both.
const OBJECT: HostInterface = .{ .kind = .method_family, .canonical = "Object", .wired_methods = &.{ "toString", "equals", "hashCode", "hasheq", "equiv" } };

// Zero-method markers (D-280a): a recognised supertype with NO methods — the
// deftype/reify just records "implements X" (the Sequential/ADR-0068 precedent).
const MAP_EQUIVALENCE: HostInterface = .{ .kind = .marker, .canonical = "clojure.lang.MapEquivalence" };
const SERIALIZABLE: HostInterface = .{ .kind = .marker, .canonical = "java.io.Serializable" };

// host_inert java interfaces (D-281 / ADR-0103): recognised so collection deftypes
// declaring them for java-interop load; methods are inert (no java dispatch in cljw).
const JAVA_UTIL_MAP: HostInterface = .{ .kind = .host_inert, .canonical = "java.util.Map" };
const JAVA_LANG_ITERABLE: HostInterface = .{ .kind = .host_inert, .canonical = "java.lang.Iterable" };
// The java.util collection interface family deftypes declare for java-interop
// (D-286a, big-bang per F-013): Set/List/Collection alongside Map. All inert.
const JAVA_UTIL_SET: HostInterface = .{ .kind = .host_inert, .canonical = "java.util.Set" };
const JAVA_UTIL_LIST: HostInterface = .{ .kind = .host_inert, .canonical = "java.util.List" };
const JAVA_UTIL_COLLECTION: HostInterface = .{ .kind = .host_inert, .canonical = "java.util.Collection" };
// java.io.Closeable (D-291): tools.reader's InputStreamReader declares it +
// implements `(close [this] (.close is))`. host_inert accepts the close-with-body
// (the guard at protocol.zig:229 skips host_inert) and never dispatches it; the
// `.close`/`.read` on the wrapped InputStream resolve at EVAL, so the deftype loads.
const JAVA_IO_CLOSEABLE: HostInterface = .{ .kind = .host_inert, .canonical = "java.io.Closeable" };

// protocol_remap interfaces (D-280b+): the macro rewrites each declared method to
// its cljw (protocol, method) target. ILookup's valAt → ILookup/-lookup (a 3-arity
// valAt collapses onto the same -lookup via D-279 multi-arity; the not-found arm is
// dormant until core get routes a 3-arity -lookup).
const ILOOKUP: HostInterface = .{ .kind = .protocol_remap, .canonical = "ILookup", .remap = &.{
    .{ .clj = "valAt", .protocol = "ILookup", .method = "-lookup" },
} };

// clj `IPersistentMap` extends IPersistentCollection / Associative / Counted, so a
// deftype groups those methods under one `IPersistentMap` section; cljw splits them
// across protocols (D-280c multi-target). The macro regroups by target protocol.
// Object methods (hashCode/equals) + cljw-unmodeled (equiv/entryAt) clj also allows
// under this section are NOT mapped here → an explicit feature_not_supported (slice 2
// + entryAt/equiv modeling, D-280d), never a silent drop.
// clojure.lang.Reversible — rseq (D-280d3). Single-target: rseq → Reversible/-rseq.
const REVERSIBLE: HostInterface = .{ .kind = .protocol_remap, .canonical = "Reversible", .remap = &.{
    .{ .clj = "rseq", .protocol = "Reversible", .method = "-rseq" },
} };

// clojure.lang.Sorted — comparator/entryKey/seq(asc)/seqFrom (D-280d4). Modeled as
// a protocol; load-level for now (the nav consult by subseq/rsubseq is a follow-up).
const SORTED: HostInterface = .{ .kind = .protocol_remap, .canonical = "Sorted", .remap = &.{
    .{ .clj = "comparator", .protocol = "Sorted", .method = "-sorted-comparator" },
    .{ .clj = "entryKey", .protocol = "Sorted", .method = "-entry-key" },
    .{ .clj = "seq", .protocol = "Sorted", .method = "-sorted-seq" },
    .{ .clj = "seqFrom", .protocol = "Sorted", .method = "-sorted-seq-from" },
} };

// clojure.lang.IFn — invoke (D-280d6). Load-level: registers (multi-arity via
// D-279); making `(inst args)` actually call -invoke is a call-path follow-up.
const IFN: HostInterface = .{ .kind = .protocol_remap, .canonical = "IFn", .remap = &.{
    .{ .clj = "invoke", .protocol = "IFn", .method = "-invoke" },
} };

// clojure.lang.IObj — meta/withMeta (D-280d7). Load-level: registers; meta/with-meta
// consulting -meta/-with-meta for a typed_instance is a follow-up.
const IOBJ: HostInterface = .{ .kind = .protocol_remap, .canonical = "IObj", .remap = &.{
    .{ .clj = "meta", .protocol = "IObj", .method = "-meta" },
    .{ .clj = "withMeta", .protocol = "IObj", .method = "-with-meta" },
} };

// clojure.lang.IDeref / IPending — the deref-able family (D-307). A deftype
// declaring IDeref registers deref→IDeref/-deref; `deref`/`@` consult it for a
// typed_instance (stm.zig derefFn). IPending's isRealized→IPending/-realized?,
// consulted by `realized?`. core.memoize's RetryingDelay implements both.
const IDEREF: HostInterface = .{ .kind = .protocol_remap, .canonical = "IDeref", .remap = &.{
    .{ .clj = "deref", .protocol = "IDeref", .method = "-deref" },
} };
const IPENDING: HostInterface = .{ .kind = .protocol_remap, .canonical = "IPending", .remap = &.{
    .{ .clj = "isRealized", .protocol = "IPending", .method = "-realized?" },
} };

// clojure.lang.IPersistentStack — peek/pop (D-280d2). core.clj peek/pop consult it.
const IPERSISTENT_STACK: HostInterface = .{ .kind = .protocol_remap, .canonical = "IPersistentStack", .remap = &.{
    .{ .clj = "peek", .protocol = "IPersistentStack", .method = "-peek" },
    .{ .clj = "pop", .protocol = "IPersistentStack", .method = "-pop" },
} };

// clojure.lang.IHashEq — hasheq (D-280d5). Targets the Object method-family
// (hasheq), consulted by hashFn before hashCode/valueHash.
const IHASHEQ: HostInterface = .{ .kind = .protocol_remap, .canonical = "IHashEq", .remap = &.{
    .{ .clj = "hasheq", .protocol = "Object", .method = "hasheq" },
} };

const IPERSISTENT_MAP: HostInterface = .{
    .kind = .protocol_remap,
    .canonical = "IPersistentMap",
    .remap = &.{
        .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
        .{ .clj = "cons", .protocol = "IPersistentCollection", .method = "-cons" },
        .{ .clj = "empty", .protocol = "IPersistentCollection", .method = "-empty" },
        .{ .clj = "assoc", .protocol = "Associative", .method = "-assoc" },
        .{ .clj = "containsKey", .protocol = "Associative", .method = "-contains-key?" },
        .{ .clj = "seq", .protocol = "Seqable", .method = "-seq" },
        .{ .clj = "without", .protocol = "IPersistentMap", .method = "-without" },
        // clj groups Object's hashCode/equals under IPersistentMap (the interface
        // inherits Object) — target the Object METHOD-FAMILY (D-280d1b). rewriteProtocolRemap
        // groups these into an `(extend-type Name Object …)` section that re-expands via
        // the isMarker quote-wrap path; equal.zig/hashFn (D-280d1) consult them.
        .{ .clj = "hashCode", .protocol = "Object", .method = "hashCode" },
        .{ .clj = "equals", .protocol = "Object", .method = "equals" },
        // equiv = clj collection value-equality (consulted by =); entryAt → Associative
        // (D-280d8). equiv targets the Object method-family (same-type consult, cross-
        // type is the residual); entryAt adds an Associative protocol method.
        .{ .clj = "equiv", .protocol = "Object", .method = "equiv" },
        .{ .clj = "entryAt", .protocol = "Associative", .method = "-entry-at" },
        // valAt → ILookup/-lookup (D-372): OrderedMap declares valAt under its
        // IPersistentMap section (clj's IPersistentMap extends ILookup). 2- and
        // 3-arity collapse onto -lookup via D-279 multi-arity (the not-found arm
        // is dormant until core get routes a 3-arity -lookup, same as ILookup).
        .{ .clj = "valAt", .protocol = "ILookup", .method = "-lookup" },
        // cljw -name identities (D-372/D-286b): the BARE IPersistentMap
        // deftype-supertype now routes through protocol_remap, so a cljw-NATIVE
        // `(extend-type T IPersistentMap (-keys …))` (D-089 native-extend test) +
        // the rewrite's own emitted `(extend-type N IPersistentMap (-without …))`
        // self-section must pass through unchanged. The IPersistentMap protocol Var
        // declares -without/-keys/-vals (core.clj), so all three need an identity
        // entry the sectionNeedsRemap guard reads to detect the cljw-form section.
        .{ .clj = "-without", .protocol = "IPersistentMap", .method = "-without" },
        .{ .clj = "-keys", .protocol = "IPersistentMap", .method = "-keys" },
        .{ .clj = "-vals", .protocol = "IPersistentMap", .method = "-vals" },
    },
};

// The clojure.lang collection-BASE interfaces a deftype can declare DIRECTLY as
// supertypes (D-306, F-013 definition-derived family). clj's IPersistentMap
// EXTENDS IPersistentCollection / Counted / Associative (and IPersistentCollection
// extends Seqable), so IPERSISTENT_MAP above already remaps these methods when
// grouped under one IPersistentMap section. A macro like core.cache's `defcache`
// instead names the base interfaces directly — these rows make the QUALIFIED
// spellings resolve to the SAME (protocol, method) targets. The bare spellings
// (Associative/Seqable/IPersistentCollection) already resolve as cljw protocol
// Vars; only the `clojure.lang.`-qualified forms need a row (+ Counted, which has
// no protocol Var — its count routes to IPersistentCollection/-count).
const COUNTED: HostInterface = .{ .kind = .protocol_remap, .canonical = "Counted", .remap = &.{
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
} };
const SEQABLE: HostInterface = .{ .kind = .protocol_remap, .canonical = "Seqable", .remap = &.{
    .{ .clj = "seq", .protocol = "Seqable", .method = "-seq" },
} };
const ASSOCIATIVE: HostInterface = .{ .kind = .protocol_remap, .canonical = "Associative", .remap = &.{
    .{ .clj = "assoc", .protocol = "Associative", .method = "-assoc" },
    .{ .clj = "containsKey", .protocol = "Associative", .method = "-contains-key?" },
    .{ .clj = "entryAt", .protocol = "Associative", .method = "-entry-at" },
} };
const IPERSISTENT_COLLECTION: HostInterface = .{
    .kind = .protocol_remap,
    .canonical = "IPersistentCollection",
    .remap = &.{
        .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
        .{ .clj = "cons", .protocol = "IPersistentCollection", .method = "-cons" },
        .{ .clj = "empty", .protocol = "IPersistentCollection", .method = "-empty" },
        // equiv = clj collection value-equality → Object method-family (same as the
        // IPersistentMap grouping); consulted by = (D-280d8 same-type).
        .{ .clj = "equiv", .protocol = "Object", .method = "equiv" },
    },
};

// Editable / transient collection family (D-286, F-013 definition-derived, big-bang).
// Driven by flatland.ordered (OrderedSet declares IEditableCollection — the LOAD
// blocker — + IPersistentSet with clj-named methods; the Transient* types declare
// the ITransient* family). All protocol_remap. Each remap maps the clj method to a
// cljw (protocol, -method) target; a clj interface groups methods cljw splits across
// protocols (count→IPersistentCollection, get/valAt→ILookup, …), exactly like
// IPERSISTENT_MAP. The cljw-native `-name` spellings are included as IDENTITY entries
// so a future cljw-native deftype using the (also-a-protocol-Var) interface bare with
// `-names` is not mis-routed to feature_not_supported (the D-286b "harder part").
// LOAD-LEVEL: methods register + dispatch; the native conj!/assoc!/persistent!/disj!
// + `into`/`-editable?` typed_instance consult is an off-critical-path follow-up
// (D-369 — `(ordered-set …)` takes the plain conj path, not transients).
const IEDITABLE_COLLECTION: HostInterface = .{ .kind = .protocol_remap, .canonical = "IEditableCollection", .remap = &.{
    .{ .clj = "asTransient", .protocol = "IEditableCollection", .method = "-as-transient" },
    .{ .clj = "-as-transient", .protocol = "IEditableCollection", .method = "-as-transient" },
} };
const ITRANSIENT_COLLECTION: HostInterface = .{ .kind = .protocol_remap, .canonical = "ITransientCollection", .remap = &.{
    .{ .clj = "conj", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "persistent", .protocol = "ITransientCollection", .method = "-persistent!" },
    .{ .clj = "-conj!", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "-persistent!", .protocol = "ITransientCollection", .method = "-persistent!" },
} };
const ITRANSIENT_ASSOCIATIVE: HostInterface = .{ .kind = .protocol_remap, .canonical = "ITransientAssociative", .remap = &.{
    .{ .clj = "assoc", .protocol = "ITransientAssociative", .method = "-assoc!" },
    .{ .clj = "conj", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "persistent", .protocol = "ITransientCollection", .method = "-persistent!" },
    .{ .clj = "-assoc!", .protocol = "ITransientAssociative", .method = "-assoc!" },
} };
const ITRANSIENT_MAP: HostInterface = .{ .kind = .protocol_remap, .canonical = "ITransientMap", .remap = &.{
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
    .{ .clj = "valAt", .protocol = "ILookup", .method = "-lookup" },
    .{ .clj = "assoc", .protocol = "ITransientAssociative", .method = "-assoc!" },
    .{ .clj = "conj", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "without", .protocol = "ITransientMap", .method = "-without!" },
    .{ .clj = "persistent", .protocol = "ITransientCollection", .method = "-persistent!" },
    .{ .clj = "-without!", .protocol = "ITransientMap", .method = "-without!" },
} };
const ITRANSIENT_SET: HostInterface = .{ .kind = .protocol_remap, .canonical = "ITransientSet", .remap = &.{
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
    .{ .clj = "get", .protocol = "ILookup", .method = "-lookup" },
    .{ .clj = "disjoin", .protocol = "ITransientSet", .method = "-disjoin!" },
    .{ .clj = "conj", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "contains", .protocol = "ITransientSet", .method = "-tset-contains?" },
    .{ .clj = "persistent", .protocol = "ITransientCollection", .method = "-persistent!" },
    .{ .clj = "-disjoin!", .protocol = "ITransientSet", .method = "-disjoin!" },
    .{ .clj = "-tset-contains?", .protocol = "ITransientSet", .method = "-tset-contains?" },
} };
const ITRANSIENT_VECTOR: HostInterface = .{ .kind = .protocol_remap, .canonical = "ITransientVector", .remap = &.{
    .{ .clj = "assocN", .protocol = "ITransientVector", .method = "-assoc-n!" },
    .{ .clj = "pop", .protocol = "ITransientVector", .method = "-pop!" },
    .{ .clj = "conj", .protocol = "ITransientCollection", .method = "-conj!" },
    .{ .clj = "persistent", .protocol = "ITransientCollection", .method = "-persistent!" },
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
    .{ .clj = "nth", .protocol = "Indexed", .method = "-nth" },
    .{ .clj = "-assoc-n!", .protocol = "ITransientVector", .method = "-assoc-n!" },
    .{ .clj = "-pop!", .protocol = "ITransientVector", .method = "-pop!" },
} };
// IPersistentSet as a DIRECT deftype supertype (D-286b): OrderedSet groups
// disjoin/cons/seq/empty/equiv/get/count under one IPersistentSet section; cljw
// splits them across protocols like IPersistentMap. Routing the bare name through
// protocol_remap (IPersistentSet is ALSO a cljw protocol Var) translates the clj
// names → cljw -methods so cljw core fns (disj→-disjoin, conj→-cons) find them; the
// `-disjoin` identity entry keeps a cljw-native impl working.
const IPERSISTENT_SET: HostInterface = .{ .kind = .protocol_remap, .canonical = "IPersistentSet", .remap = &.{
    .{ .clj = "disjoin", .protocol = "IPersistentSet", .method = "-disjoin" },
    .{ .clj = "cons", .protocol = "IPersistentCollection", .method = "-cons" },
    .{ .clj = "seq", .protocol = "Seqable", .method = "-seq" },
    .{ .clj = "empty", .protocol = "IPersistentCollection", .method = "-empty" },
    .{ .clj = "equiv", .protocol = "Object", .method = "equiv" },
    .{ .clj = "get", .protocol = "ILookup", .method = "-lookup" },
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
    .{ .clj = "-disjoin", .protocol = "IPersistentSet", .method = "-disjoin" },
} };

/// Recognised host-supertype names → their `HostInterface`. D-275 slice 1:
/// `Object`. D-280a: zero-method markers. D-280b+: the method-bearing
/// `clojure.lang.*` family, each added as a row gated against
/// `host_interfaces.yaml` — never a fresh `eql` site.
const MARKERS = std.StaticStringMap(HostInterface).initComptime(.{
    .{ "Object", OBJECT },
    .{ "clojure.lang.MapEquivalence", MAP_EQUIVALENCE },
    // bare aliases (D-372): flatland.ordered.map `:import`s + declares these bare.
    // MapEquivalence is a zero-method marker (safe). IPersistentMap is a cljw
    // protocol Var, so the bare deftype-supertype routes through protocol_remap +
    // the -without identity entry (the D-286b harder-part shape, like IPersistentSet).
    .{ "MapEquivalence", MAP_EQUIVALENCE },
    .{ "IPersistentMap", IPERSISTENT_MAP },
    .{ "java.io.Serializable", SERIALIZABLE },
    .{ "clojure.lang.ILookup", ILOOKUP },
    .{ "clojure.lang.IPersistentMap", IPERSISTENT_MAP },
    .{ "clojure.lang.Reversible", REVERSIBLE },
    .{ "clojure.lang.IPersistentStack", IPERSISTENT_STACK },
    .{ "clojure.lang.IHashEq", IHASHEQ },
    // bare alias (D-286a): libs `:import [clojure.lang IHashEq]` + use it bare.
    // IHashEq has NO cljw protocol Var (it routes to Object/hasheq), so the bare
    // spelling is unambiguous — safe to add. The bare forms of IFn/IObj/etc. are
    // already protocol Vars, so they resolve bare (their clj→cljw method-name
    // disambiguation is the harder D-286b, deferred).
    .{ "IHashEq", IHASHEQ },
    .{ "clojure.lang.Sorted", SORTED },
    .{ "clojure.lang.IFn", IFN },
    .{ "clojure.lang.IObj", IOBJ },
    // D-306: collection-base interfaces declarable as DIRECT deftype supertypes
    // (core.cache's defcache). Qualified spelling only — the bare Associative/
    // Seqable/IPersistentCollection are cljw protocol Vars that resolve already.
    .{ "clojure.lang.Counted", COUNTED },
    .{ "clojure.lang.Seqable", SEQABLE },
    .{ "clojure.lang.Associative", ASSOCIATIVE },
    .{ "clojure.lang.IPersistentCollection", IPERSISTENT_COLLECTION },
    // D-307: the deref-able family (core.memoize's RetryingDelay).
    .{ "clojure.lang.IDeref", IDEREF },
    .{ "clojure.lang.IPending", IPENDING },
    // D-286: the editable / transient collection family (flatland.ordered).
    // BOTH the qualified spelling AND the bare simple name (a deftype `:import`s
    // `(clojure.lang IEditableCollection …)` then declares the BARE name) route to
    // the same protocol_remap row. IPersistentSet (D-286b) is added bare too — it
    // is already a cljw protocol Var, but the remap (with the `-disjoin` identity
    // entry) translates ordered's clj-named methods so they dispatch.
    .{ "IEditableCollection", IEDITABLE_COLLECTION },
    .{ "clojure.lang.IEditableCollection", IEDITABLE_COLLECTION },
    .{ "ITransientCollection", ITRANSIENT_COLLECTION },
    .{ "clojure.lang.ITransientCollection", ITRANSIENT_COLLECTION },
    .{ "ITransientAssociative", ITRANSIENT_ASSOCIATIVE },
    .{ "clojure.lang.ITransientAssociative", ITRANSIENT_ASSOCIATIVE },
    .{ "ITransientMap", ITRANSIENT_MAP },
    .{ "clojure.lang.ITransientMap", ITRANSIENT_MAP },
    .{ "ITransientSet", ITRANSIENT_SET },
    .{ "clojure.lang.ITransientSet", ITRANSIENT_SET },
    .{ "ITransientVector", ITRANSIENT_VECTOR },
    .{ "clojure.lang.ITransientVector", ITRANSIENT_VECTOR },
    .{ "IPersistentSet", IPERSISTENT_SET },
    .{ "clojure.lang.IPersistentSet", IPERSISTENT_SET },
    // host_inert: accept both the bare spelling (priority-map writes `Map`/`Iterable`)
    // and the fully-qualified one (the canonical, which the primitive re-checks).
    .{ "Map", JAVA_UTIL_MAP },
    .{ "java.util.Map", JAVA_UTIL_MAP },
    .{ "Iterable", JAVA_LANG_ITERABLE },
    .{ "java.lang.Iterable", JAVA_LANG_ITERABLE },
    .{ "Set", JAVA_UTIL_SET },
    .{ "java.util.Set", JAVA_UTIL_SET },
    .{ "List", JAVA_UTIL_LIST },
    .{ "java.util.List", JAVA_UTIL_LIST },
    .{ "Collection", JAVA_UTIL_COLLECTION },
    .{ "java.util.Collection", JAVA_UTIL_COLLECTION },
    // java.io.Closeable (D-291): bare `Closeable` (tools.reader writes it bare) +
    // the qualified canonical. Inert — close-with-body accepted, never dispatched.
    .{ "Closeable", JAVA_IO_CLOSEABLE },
    .{ "java.io.Closeable", JAVA_IO_CLOSEABLE },
});

/// extend-protocol TARGET interfaces → native value-tag NAMES. A
/// `(extend-protocol P clojure.lang.ISeq …)` distributes the impl over each
/// listed tag's native descriptor (via `rt/__native-type`), so a cljw seq /
/// named / map value dispatches P. ISeq / Named / IPersistentMap DERIVE from the
/// `interface_membership` SSOT (the same source class_name.matchInterface uses),
/// so the tag lists live in ONE place (ADR-0116 Decision C, D-317 partial).
/// IPersistentVector is kept EXPLICIT: its extend-target set is {vector} ONLY,
/// NOT the instance? membership {vector, map_entry} — distributing to map_entry
/// needs a separate decision (D-317 residual, ADR-0116). Distinct from MARKERS
/// (which cover the deftype-supertype / protocol position).
const IPV_EXTEND_TAGS = [_][]const u8{"vector"};

/// The native `Value.Tag` keyword names a `(extend-protocol P <iface> …)` must
/// distribute the impl over (bare or `clojure.lang.`-qualified), or null when
/// `name` is not an extend-target interface.
pub fn nativeExtendTags(name: []const u8) ?[]const []const u8 {
    const simple = interface_membership.simpleOf(name);
    if (std.mem.eql(u8, simple, "IPersistentVector")) return &IPV_EXTEND_TAGS;
    if (std.mem.eql(u8, simple, "ISeq")) return interface_membership.ISEQ_NAMES;
    if (std.mem.eql(u8, simple, "Named")) return interface_membership.NAMED_NAMES;
    if (std.mem.eql(u8, simple, "IPersistentMap")) return interface_membership.MAP_NAMES;
    return null;
}

/// True when `name` is a quote-wrap marker (method_family or zero-method marker)
/// — the analyzer must never Var-resolve it. protocol_remap names are NOT markers
/// (the macro rewrites them to bare cljw protocols instead); see `isProtocolRemap`.
pub fn isMarker(name: []const u8) bool {
    const hi = MARKERS.get(name) orelse return false;
    return hi.kind == .method_family or hi.kind == .marker or hi.kind == .host_inert;
}

/// True when `name` is a protocol_remap interface (the macro rewrites its section
/// to bare cljw-protocol section(s) with translated method names).
pub fn isProtocolRemap(name: []const u8) bool {
    const hi = MARKERS.get(name) orelse return false;
    return hi.kind == .protocol_remap;
}

/// True when `name` is a no-JVM host_inert interface (java.util.Map etc.) — its
/// declared methods are accepted-and-recorded but never dispatched, so the
/// primitive must NOT raise feature_not_supported on them (ADR-0103). Accepts the
/// bare and qualified spellings AND the canonical (the primitive re-checks the
/// canonicalised proto_name).
pub fn isHostInert(name: []const u8) bool {
    const hi = MARKERS.get(name) orelse return false;
    return hi.kind == .host_inert;
}

/// java.util.Map / java.util.Collection / java.util.List / java.lang.Iterable
/// instance methods a deftype may declare UNDER a clojure.lang.* `protocol_remap`
/// section (clj's IPersistentMap/Vector/Set EXTEND Iterable/Map/Collection, so a
/// lib can group these methods there — flatland.ordered's OrderedMap declares
/// `iterator`/`entrySet` under its IPersistentMap section). cljw has NO java
/// dispatch (ADR-0103 / ADR-0059), so — exactly like a whole `host_inert` java
/// section — these are ACCEPTED-AND-DROPPED (load-level, no dispatch) rather than
/// raising `feature_not_supported`. Closed set derived from the java.util/lang
/// interface definitions (D-372, F-013), NOT from any one library's usage. The
/// READ/iteration surface only — a persistent type never implements the mutators
/// (put/add/clear) so they are omitted; if one appears it correctly still raises.
pub fn isJavaUtilMethod(name: []const u8) bool {
    const SET = std.StaticStringMap(void).initComptime(.{
        // java.lang.Iterable
        .{"iterator"}, .{"forEach"}, .{"spliterator"},
        // java.util.Collection
        .{"size"}, .{"isEmpty"}, .{"contains"}, .{"containsAll"}, .{"toArray"}, .{"stream"}, .{"parallelStream"},
        // java.util.Map
        .{"containsKey"}, .{"containsValue"}, .{"keySet"}, .{"values"}, .{"entrySet"}, .{"getOrDefault"},
        // java.util.List
        .{"listIterator"}, .{"indexOf"}, .{"lastIndexOf"}, .{"subList"},
    });
    return SET.has(name);
}

/// The full entry for a recognised name, or null.
pub fn lookup(name: []const u8) ?HostInterface {
    return MARKERS.get(name);
}

/// Canonical process-lifetime name for a recognised marker (the borrowed
/// `MethodEntry.protocol_name` contract needs a process-lifetime slice), or
/// null when `name` is not a recognised marker.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    return if (MARKERS.get(name)) |hi| hi.canonical else null;
}

/// True when `marker`'s `method` is wired to a real surface. A recognised
/// marker whose method is NOT wired must raise `feature_not_supported` rather
/// than register a method that silently does nothing.
pub fn isMethodWired(marker: []const u8, method: []const u8) bool {
    const hi = MARKERS.get(marker) orelse return false;
    for (hi.wired_methods) |m| if (std.mem.eql(u8, m, method)) return true;
    return false;
}

test "Object is a recognised marker; canonical name is the static literal" {
    try std.testing.expect(isMarker("Object"));
    try std.testing.expect(!isMarker("IDeref"));
    try std.testing.expect(!isMarker("MyProtocol"));
    try std.testing.expectEqualStrings("Object", canonicalName("Object").?);
    try std.testing.expect(canonicalName("NotAMarker") == null);
}

test "Object toString/equals/hashCode are wired (D-280d1); unknown methods are not" {
    try std.testing.expect(isMethodWired("Object", "toString"));
    try std.testing.expect(isMethodWired("Object", "equals"));
    try std.testing.expect(isMethodWired("Object", "hashCode"));
    try std.testing.expect(!isMethodWired("Object", "clone"));
    try std.testing.expect(!isMethodWired("NotAMarker", "toString"));
}

test "zero-method markers are markers, not protocol_remap" {
    try std.testing.expect(isMarker("clojure.lang.MapEquivalence"));
    try std.testing.expect(isMarker("java.io.Serializable"));
    try std.testing.expect(!isProtocolRemap("clojure.lang.MapEquivalence"));
}

test "ILookup is a protocol_remap (not a quote-wrap marker); valAt → ILookup/-lookup" {
    try std.testing.expect(isProtocolRemap("clojure.lang.ILookup"));
    try std.testing.expect(!isMarker("clojure.lang.ILookup"));
    const hi = lookup("clojure.lang.ILookup").?;
    const r = hi.remapMethod("valAt").?;
    try std.testing.expectEqualStrings("ILookup", r.protocol);
    try std.testing.expectEqualStrings("-lookup", r.method);
    try std.testing.expect(hi.remapMethod("nonexistent") == null);
}
