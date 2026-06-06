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

/// A recognised host-supertype marker: its canonical (process-lifetime) name
/// plus the methods wired to a real cljw surface. The canonical name is a
/// static literal so a borrowed `MethodEntry.protocol_name` (which is never
/// freed — ProtocolDescriptor-lifetime contract) stays valid. A method absent
/// from `wired_methods` raises an explicit transient `feature_not_supported`
/// (ADR-0018), never a silently-dropped impl.
pub const HostInterface = struct {
    canonical: []const u8,
    wired_methods: []const []const u8,
};

const OBJECT: HostInterface = .{ .canonical = "Object", .wired_methods = &.{"toString"} };

/// Recognised marker names (+ qualified aliases) → their `HostInterface`.
/// Slice 1 (D-275): only `Object`/`toString`. The `clojure.lang.*` family lands
/// as entries here as each interface is modeled (D-275 slices 3+) — always a new
/// row gated against `host_interfaces.yaml`, never a fresh `eql` site.
const MARKERS = std.StaticStringMap(HostInterface).initComptime(.{
    .{ "Object", OBJECT },
});

/// True when `name` (a deftype/reify impl-spec head symbol) is a recognised
/// host-supertype marker, so the macro quote-wraps it (the analyzer must never
/// Var-resolve it). A non-marker symbol stays bare and resolves as a protocol
/// Var through the ordinary path.
pub fn isMarker(name: []const u8) bool {
    return MARKERS.has(name);
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
