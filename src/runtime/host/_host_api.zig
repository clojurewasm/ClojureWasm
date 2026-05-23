// SPDX-License-Identifier: EPL-2.0
//! Host extension registry contract (ROADMAP §9.6 / 4.20, ADR-0011).
//!
//! Each Java-stdlib equivalent under `src/runtime/host/<pkg>/<Class>.zig`
//! exports a top-level `___HOST_EXTENSION` declaration whose type is
//! `Extension`. A future aggregator (Phase 5+) uses Zig comptime
//! introspection to collect every such declaration into the host
//! registry without a central edit per addition.
//!
//! Phase 4 entry lands the contract only. Each placeholder file under
//! `src/runtime/host/<pkg>/_placeholder.zig` is empty of behaviour;
//! when an actual host class lands it replaces the placeholder and
//! exports `___HOST_EXTENSION`.

const std = @import("std");
const type_descriptor = @import("../type_descriptor.zig");

/// Marker symbol every host file exports under this exact name.
/// The Phase-5 aggregator scans for `___HOST_EXTENSION` declarations
/// across `src/runtime/host/**/*.zig`.
pub const MARKER_NAME: []const u8 = "___HOST_EXTENSION";

/// One host extension entry. Carries the user-facing Clojure name
/// (`cljw.host.java.util.UUID`), the corresponding native `TypeDescriptor`,
/// and an optional init function for any one-time setup. The `init`
/// is invoked once at Runtime startup; runs concurrently across
/// extensions only when ROADMAP §9.6 mandates a guard (Phase 5+).
pub const Extension = struct {
    /// `cljw.host.<java-pkg>.<Class>` form. Used by Clojure
    /// `(:require [cljw.host.java.util :refer [UUID]])`.
    cljw_ns: []const u8,
    /// Pre-allocated `TypeDescriptor` for this host class. Lifetime
    /// is the Runtime — the descriptor lives in the host namespace
    /// it is registered into.
    descriptor: *const type_descriptor.TypeDescriptor,
    /// Optional initialiser. `null` means no setup required beyond
    /// descriptor registration.
    init: ?*const fn () anyerror!void = null,
};

// --- tests ---

const testing = std.testing;

test "Extension struct shape" {
    var td: type_descriptor.TypeDescriptor = .{
        .fqcn = "cljw.host.java.util.UUID",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    const ext: Extension = .{
        .cljw_ns = "cljw.host.java.util.UUID",
        .descriptor = &td,
    };
    try testing.expectEqualStrings("cljw.host.java.util.UUID", ext.cljw_ns);
    try testing.expect(ext.init == null);
}

test "MARKER_NAME constant matches the ADR-0011 contract" {
    try testing.expectEqualStrings("___HOST_EXTENSION", MARKER_NAME);
}
