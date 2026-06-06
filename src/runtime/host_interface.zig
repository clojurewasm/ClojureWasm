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
pub const Kind = enum { method_family, marker, protocol_remap };

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

const OBJECT: HostInterface = .{ .kind = .method_family, .canonical = "Object", .wired_methods = &.{"toString"} };

// Zero-method markers (D-280a): a recognised supertype with NO methods — the
// deftype/reify just records "implements X" (the Sequential/ADR-0068 precedent).
const MAP_EQUIVALENCE: HostInterface = .{ .kind = .marker, .canonical = "clojure.lang.MapEquivalence" };
const SERIALIZABLE: HostInterface = .{ .kind = .marker, .canonical = "java.io.Serializable" };

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

// clojure.lang.IPersistentStack — peek/pop (D-280d2). core.clj peek/pop consult it.
const IPERSISTENT_STACK: HostInterface = .{ .kind = .protocol_remap, .canonical = "IPersistentStack", .remap = &.{
    .{ .clj = "peek", .protocol = "IPersistentStack", .method = "-peek" },
    .{ .clj = "pop", .protocol = "IPersistentStack", .method = "-pop" },
} };

const IPERSISTENT_MAP: HostInterface = .{ .kind = .protocol_remap, .canonical = "IPersistentMap", .remap = &.{
    .{ .clj = "count", .protocol = "IPersistentCollection", .method = "-count" },
    .{ .clj = "cons", .protocol = "IPersistentCollection", .method = "-cons" },
    .{ .clj = "empty", .protocol = "IPersistentCollection", .method = "-empty" },
    .{ .clj = "assoc", .protocol = "Associative", .method = "-assoc" },
    .{ .clj = "containsKey", .protocol = "Associative", .method = "-contains-key?" },
    .{ .clj = "seq", .protocol = "Seqable", .method = "-seq" },
    .{ .clj = "without", .protocol = "IPersistentMap", .method = "-without" },
} };

/// Recognised host-supertype names → their `HostInterface`. D-275 slice 1:
/// `Object`. D-280a: zero-method markers. D-280b+: the method-bearing
/// `clojure.lang.*` family, each added as a row gated against
/// `host_interfaces.yaml` — never a fresh `eql` site.
const MARKERS = std.StaticStringMap(HostInterface).initComptime(.{
    .{ "Object", OBJECT },
    .{ "clojure.lang.MapEquivalence", MAP_EQUIVALENCE },
    .{ "java.io.Serializable", SERIALIZABLE },
    .{ "clojure.lang.ILookup", ILOOKUP },
    .{ "clojure.lang.IPersistentMap", IPERSISTENT_MAP },
    .{ "clojure.lang.Reversible", REVERSIBLE },
    .{ "clojure.lang.IPersistentStack", IPERSISTENT_STACK },
});

/// True when `name` is a quote-wrap marker (method_family or zero-method marker)
/// — the analyzer must never Var-resolve it. protocol_remap names are NOT markers
/// (the macro rewrites them to bare cljw protocols instead); see `isProtocolRemap`.
pub fn isMarker(name: []const u8) bool {
    const hi = MARKERS.get(name) orelse return false;
    return hi.kind == .method_family or hi.kind == .marker;
}

/// True when `name` is a protocol_remap interface (the macro rewrites its section
/// to bare cljw-protocol section(s) with translated method names).
pub fn isProtocolRemap(name: []const u8) bool {
    const hi = MARKERS.get(name) orelse return false;
    return hi.kind == .protocol_remap;
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

test "Object/toString is wired; equals/hashCode are not (transient)" {
    try std.testing.expect(isMethodWired("Object", "toString"));
    try std.testing.expect(!isMethodWired("Object", "equals"));
    try std.testing.expect(!isMethodWired("Object", "hashCode"));
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
