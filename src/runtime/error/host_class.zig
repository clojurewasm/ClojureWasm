// SPDX-License-Identifier: EPL-2.0
//! Host-class hierarchy table for `(try ... (catch ClassName e ...))`
//! dispatch — ROADMAP §9.9 row 7.11 / D-077. Replaces the prior
//! `ExceptionInfo`-only silent match in `tree_walk.catchMatches` +
//! `vm.matchExceptionClass` with a comptime hierarchy walk over the
//! Java exception class names cw v1 recognises.
//!
//! ## Scope
//!
//! This file holds the data — a flat `Entry` array describing the
//! parent chain for each recognised class name, FQCN→simple
//! normalization, and the `isSubclassOf` walk — plus the
//! `matches(thrown, class_name)` integration the `tree_walk` + `vm`
//! catch sites call. The analyzer-time `catch_class_unknown` error
//! (in `catalog.zig`) rejects unknown class symbols rather than
//! letting them pass through silently.
//!
//! ## Hierarchy (mirrors JVM `java.lang.Throwable` chain)
//!
//! ```text
//! Throwable
//!   ├─ Error
//!   │    └─ OutOfMemoryError
//!   └─ Exception
//!        ├─ IOException
//!        │    ├─ FileNotFoundException
//!        │    └─ EOFException
//!        └─ RuntimeException
//!             ├─ ArithmeticException
//!             ├─ ClassCastException
//!             ├─ IllegalArgumentException
//!             │    └─ NumberFormatException
//!             ├─ IllegalStateException
//!             ├─ IndexOutOfBoundsException
//!             ├─ NullPointerException
//!             ├─ UnsupportedOperationException
//!             └─ ExceptionInfo            (clojure.lang)
//! ```
//!
//! ## DIVERGENCE from cw v0
//!
//! cw v0 carried the same table in `lang/interop/exception_hierarchy.zig`
//! plus a `pub var exception_matches_class` function pointer in
//! `runtime/dispatch.zig`. cw v1 drops the pub-var injection (ROADMAP
//! §13 forbidden patterns) — `tree_walk` + `vm` import this file
//! directly (Layer 1 → Layer 0 downward import, zone_check-clean).
//! cw v0 also silently let unknown class names pass through
//! `normalizeClassName` and returned false from `isSubclassOf`,
//! preserving the silent-default-shift cw v1 is here to eliminate.
//! Cycle 3's analyzer-time `catch_class_unknown` raise discharges
//! that smell at the root.

const std = @import("std");
const Value = @import("../value/value.zig").Value;
const ex_info_mod = @import("../collection/ex_info.zig");
const Kind = @import("info.zig").Kind;

/// One node of the recognised exception hierarchy. `parent == null`
/// marks the chain root (Throwable). Names are simple (no package
/// prefix); FQCN inputs go through `normalizeClassName` first.
pub const Entry = struct {
    name: []const u8,
    parent: ?[]const u8,
};

/// Flat hierarchy table. Comptime-known so the lookup helpers below
/// can fold to a static switch / StaticStringMap-style search at
/// compile time. Order does not matter for correctness; kept roughly
/// breadth-first for readability.
pub const ENTRIES = [_]Entry{
    .{ .name = "Throwable", .parent = null },

    .{ .name = "Error", .parent = "Throwable" },
    .{ .name = "OutOfMemoryError", .parent = "Error" },
    // `(assert …)` throws an AssertionError (under Error, NOT Exception) — D-192.
    .{ .name = "AssertionError", .parent = "Error" },

    .{ .name = "Exception", .parent = "Throwable" },
    .{ .name = "IOException", .parent = "Exception" },
    .{ .name = "FileNotFoundException", .parent = "IOException" },
    .{ .name = "EOFException", .parent = "IOException" },
    // D-301: checked reflective exception (Exception→ReflectiveOperationException→
    // ClassNotFoundException on the JVM); cw flattens the intermediate. Caught
    // (never thrown) by libs probing for optional classes, e.g.
    // clojure.math.numeric-tower's `(catch ClassNotFoundException _ …)`.
    .{ .name = "ReflectiveOperationException", .parent = "Exception" },
    .{ .name = "ClassNotFoundException", .parent = "ReflectiveOperationException" },

    .{ .name = "RuntimeException", .parent = "Exception" },
    .{ .name = "ArithmeticException", .parent = "RuntimeException" },
    .{ .name = "ClassCastException", .parent = "RuntimeException" },
    .{ .name = "IllegalArgumentException", .parent = "RuntimeException" },
    .{ .name = "ArityException", .parent = "IllegalArgumentException" },
    .{ .name = "NumberFormatException", .parent = "IllegalArgumentException" },
    .{ .name = "IllegalStateException", .parent = "RuntimeException" },
    .{ .name = "IndexOutOfBoundsException", .parent = "RuntimeException" },
    .{ .name = "NullPointerException", .parent = "RuntimeException" },
    .{ .name = "UnsupportedOperationException", .parent = "RuntimeException" },
    .{ .name = "ExceptionInfo", .parent = "RuntimeException" },
};

/// Map FQCN inputs (`java.lang.RuntimeException`,
/// `clojure.lang.ExceptionInfo`, `java.io.IOException`, ...) to their
/// simple names. Unknown FQCNs fall through unchanged so the caller's
/// known-name lookup raises rather than silently matching nothing.
const FQCN_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ "java.lang.Throwable", "Throwable" },
    .{ "java.lang.Error", "Error" },
    .{ "java.lang.OutOfMemoryError", "OutOfMemoryError" },
    .{ "java.lang.Exception", "Exception" },
    .{ "java.lang.RuntimeException", "RuntimeException" },
    .{ "java.lang.ArithmeticException", "ArithmeticException" },
    .{ "java.lang.ClassCastException", "ClassCastException" },
    .{ "java.lang.IllegalArgumentException", "IllegalArgumentException" },
    .{ "clojure.lang.ArityException", "ArityException" },
    .{ "java.lang.NumberFormatException", "NumberFormatException" },
    .{ "java.lang.IllegalStateException", "IllegalStateException" },
    .{ "java.lang.IndexOutOfBoundsException", "IndexOutOfBoundsException" },
    .{ "java.lang.NullPointerException", "NullPointerException" },
    .{ "java.lang.UnsupportedOperationException", "UnsupportedOperationException" },
    .{ "java.io.IOException", "IOException" },
    .{ "java.io.FileNotFoundException", "FileNotFoundException" },
    .{ "java.io.EOFException", "EOFException" },
    .{ "clojure.lang.ExceptionInfo", "ExceptionInfo" },
});

/// Return the simple class name for `class_name` if it is a known
/// FQCN; otherwise return the input unchanged (so `isKnownException`
/// can decide whether it is recognised at all).
pub fn normalizeClassName(class_name: []const u8) []const u8 {
    return FQCN_MAP.get(class_name) orelse class_name;
}

/// Return `true` iff `class_name` (simple or FQCN) names an entry in
/// the hierarchy table. Cycle 3's analyzer-time check uses this to
/// reject unknown catch-clause class symbols up front.
pub fn isKnownException(class_name: []const u8) bool {
    const simple = normalizeClassName(class_name);
    inline for (ENTRIES) |e| {
        if (std.mem.eql(u8, e.name, simple)) return true;
    }
    return false;
}

/// Closed set of JVM numeric classes cljw COLLAPSES into its own types (F-005 /
/// ADR-0059 / AD-016): java.math.BigInteger → cljw BigInt; Integer/Short/Byte/
/// Float → cljw Long/Double. cljw has NO values of these types, so as class
/// VALUES they are OPAQUE — distinct from every cljw type. Resolving them
/// (ADR-0109) makes `(= (type 5) Integer)` / `(instance? Integer 5)` correctly
/// false (clj-faithful: a cljw int IS a Long, not an Integer) and lets libs that
/// branch on these JVM classes load with the JVM-class branch correctly dead.
/// `Character`/`Boolean` are NOT here — cljw models those as real types.
const OPAQUE_CLASSES = std.StaticStringMap(void).initComptime(.{
    .{"java.math.BigInteger"},
    .{"Integer"},
    .{"java.lang.Integer"},
    .{"Short"},
    .{"java.lang.Short"},
    .{"Byte"},
    .{"java.lang.Byte"},
    .{"Float"},
    .{"java.lang.Float"},
});

/// True iff `class_name` is a recognised OPAQUE host class (ADR-0109). Such a
/// class resolves as a distinct class VALUE that no cljw value has as its type:
/// `instance?` is uniformly false and `extend-type` on it is a load-only no-op.
pub fn isKnownOpaqueClass(class_name: []const u8) bool {
    return OPAQUE_CLASSES.has(class_name);
}

/// True iff `class_name` is `java.lang.Object` — the UNIVERSAL supertype
/// (ADR-0109). Resolved as a class VALUE so `(derive Object …)` works (algo.generic);
/// `(isa? <any-class> Object)` is true and `(instance? Object x)` is true for any
/// non-nil x (clj: nil is not an Object). The OTHER host_interface markers (IFn,
/// Counted, …) as class values are the tracked D-293 remainder.
pub fn isUniversalClass(class_name: []const u8) bool {
    return std.mem.eql(u8, class_name, "Object") or std.mem.eql(u8, class_name, "java.lang.Object");
}

/// Return the immediate parent of `class_name` in the hierarchy, or
/// `null` for the root (Throwable) or for unknown class names.
pub fn getParent(class_name: []const u8) ?[]const u8 {
    const simple = normalizeClassName(class_name);
    inline for (ENTRIES) |e| {
        if (std.mem.eql(u8, e.name, simple)) return e.parent;
    }
    return null;
}

/// Return `true` iff `child` is `parent` or any ancestor on its
/// `parent` chain. Both arguments accept simple names or FQCNs.
/// Unknown class names compare structurally (return true only when
/// `child == parent`) — the analyzer-time `catch_class_unknown`
/// check rejects unknown class names before they reach this
/// function, so the fallthrough is defensive, not load-bearing.
pub fn isSubclassOf(child: []const u8, parent: []const u8) bool {
    const simple_child = normalizeClassName(child);
    const simple_parent = normalizeClassName(parent);
    var cursor: ?[]const u8 = simple_child;
    while (cursor) |c| {
        if (std.mem.eql(u8, c, simple_parent)) return true;
        cursor = getParent(c);
    }
    return false;
}

/// Class name a thrown Value matches against. Maps each currently-
/// throwable Value tag to the simple class name a `(catch …)` clause
/// would receive. Only `.ex_info` flows through here today (the only
/// throwable Value tag in cw v1). The `.host_instance` arm — via a
/// TypeDescriptor parent walk inside `matches()` below — is still
/// unwired (see the PROVISIONAL marker, D-048).
fn thrownClassName(thrown: Value) ?[]const u8 {
    return switch (thrown.tag()) {
        // ADR-0060: a runtime-synthesized internal error carries its
        // class (`"ArithmeticException"`, …); a real `(ex-info …)` has
        // none → `"ExceptionInfo"`. So `(instance? ExceptionInfo …)` is
        // false for a synthesized exception and true for a user ex-info.
        .ex_info => ex_info_mod.className(thrown) orelse "ExceptionInfo",
        else => null,
    };
}

/// ADR-0060: map a catalog error `Kind` to the exception class a
/// `(catch …)` clause should match (grounded against real `clj`), or
/// `null` for the uncatchable Kinds. `internal_error` / `out_of_memory`
/// descend from `Error` (JVM `(catch Exception …)` does not catch them);
/// `not_implemented` stays a loud uncaught signal so a `(catch Exception
/// …)` cannot silently swallow a missing-feature gap (Silent-default-shift
/// smell). The returned strings are comptime-static (stored by pointer on
/// the synthesized ex_info, never duped/freed).
pub fn kindToHostClass(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .arithmetic_error => "ArithmeticException",
        .type_error => "ClassCastException",
        .index_error => "IndexOutOfBoundsException",
        .value_error => "IllegalArgumentException",
        .arity_error => "ArityException",
        .number_error => "NumberFormatException",
        .name_error, .syntax_error, .string_error => "RuntimeException",
        .io_error => "IOException",
        .not_implemented, .internal_error, .out_of_memory => null,
    };
}

/// `(catch ClassName e ...)` match predicate. Replaces the prior
/// `ExceptionInfo`-only silent match in `tree_walk.catchMatches` +
/// `vm.matchExceptionClass` (row 7.11 cycle 2; D-077 discharge).
///
/// Match rules (mirror JVM `(catch ClassName e)` semantics):
/// 1. `Throwable` catches every recognised throwable.
/// 2. Otherwise the thrown Value's mapped class name must be a
///    subclass (per `isSubclassOf`) of `class_name`.
/// 3. Unknown class names return false defensively — the
///    analyzer-time `catch_class_unknown` raise eliminates this
///    fallthrough at the source.
pub fn matches(thrown: Value, class_name: []const u8) bool {
    const simple = normalizeClassName(class_name);
    if (std.mem.eql(u8, simple, "Throwable")) return true;
    if (thrownClassName(thrown)) |thrown_simple| {
        return isSubclassOf(thrown_simple, simple);
    }
    // PROVISIONAL: host_instance receiver arm pending D-048 host_class wire-up [refs: D-048, feature_deps.yaml#runtime/error/catch_class_host_instance_arm]
    return false;
}

// --- tests ---

const testing = std.testing;

test "isKnownException accepts simple names + FQCNs" {
    try testing.expect(isKnownException("Throwable"));
    try testing.expect(isKnownException("ArithmeticException"));
    try testing.expect(isKnownException("ExceptionInfo"));
    try testing.expect(isKnownException("java.lang.RuntimeException"));
    try testing.expect(isKnownException("clojure.lang.ExceptionInfo"));
    try testing.expect(isKnownException("java.io.FileNotFoundException"));
}

test "isKnownException rejects unknown class names" {
    try testing.expect(!isKnownException("FooBarException"));
    try testing.expect(!isKnownException("java.lang.Object"));
    try testing.expect(!isKnownException(""));
}

test "getParent walks single step" {
    try testing.expectEqualStrings("RuntimeException", getParent("ArithmeticException").?);
    try testing.expectEqualStrings("RuntimeException", getParent("ExceptionInfo").?);
    try testing.expectEqualStrings("Exception", getParent("RuntimeException").?);
    try testing.expectEqualStrings("IllegalArgumentException", getParent("NumberFormatException").?);
}

test "getParent of Throwable is null" {
    try testing.expectEqual(@as(?[]const u8, null), getParent("Throwable"));
}

test "getParent FQCN normalises before lookup" {
    try testing.expectEqualStrings("RuntimeException", getParent("java.lang.ArithmeticException").?);
}

test "isSubclassOf transitive: ExceptionInfo → RuntimeException → Exception → Throwable" {
    try testing.expect(isSubclassOf("ExceptionInfo", "RuntimeException"));
    try testing.expect(isSubclassOf("ExceptionInfo", "Exception"));
    try testing.expect(isSubclassOf("ExceptionInfo", "Throwable"));
}

test "isSubclassOf self: every class is its own subclass" {
    try testing.expect(isSubclassOf("Throwable", "Throwable"));
    try testing.expect(isSubclassOf("ArithmeticException", "ArithmeticException"));
}

test "isSubclassOf rejects sibling and ancestor-direction queries" {
    try testing.expect(!isSubclassOf("ArithmeticException", "IOException"));
    try testing.expect(!isSubclassOf("RuntimeException", "ExceptionInfo"));
    try testing.expect(!isSubclassOf("Throwable", "Exception"));
}

test "isSubclassOf rejects Error <-> RuntimeException cross-branch" {
    try testing.expect(!isSubclassOf("OutOfMemoryError", "RuntimeException"));
    try testing.expect(!isSubclassOf("ArithmeticException", "Error"));
}

test "isSubclassOf with FQCN inputs on both sides" {
    try testing.expect(isSubclassOf("java.lang.ArithmeticException", "java.lang.RuntimeException"));
    try testing.expect(isSubclassOf("clojure.lang.ExceptionInfo", "java.lang.Throwable"));
}

test "normalizeClassName: FQCN → simple" {
    try testing.expectEqualStrings("RuntimeException", normalizeClassName("java.lang.RuntimeException"));
    try testing.expectEqualStrings("ExceptionInfo", normalizeClassName("clojure.lang.ExceptionInfo"));
    try testing.expectEqualStrings("IOException", normalizeClassName("java.io.IOException"));
}

test "normalizeClassName: simple name passes through unchanged" {
    try testing.expectEqualStrings("Throwable", normalizeClassName("Throwable"));
    try testing.expectEqualStrings("ArithmeticException", normalizeClassName("ArithmeticException"));
}

test "normalizeClassName: unknown FQCN passes through unchanged (caller decides)" {
    try testing.expectEqualStrings("foo.bar.Quux", normalizeClassName("foo.bar.Quux"));
    try testing.expectEqualStrings("", normalizeClassName(""));
}
