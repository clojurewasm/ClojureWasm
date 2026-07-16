// SPDX-License-Identifier: EPL-2.0
//! Host-class name resolution over the `rt.types` registry — the ONE
//! place the "what does a class symbol mean" rules live (ADR-0050 §R3
//! java.lang auto-import, D-235 per-ns `(:import …)` map, the
//! BigDecimal/BigInteger java.math default imports). Shared by the
//! analyzer's `resolveJavaSurface` (Class/static resolution, `Class.`
//! constructors), `resolveClassValue` (class symbols in value position,
//! ADR-0174), and the completion surface (introspect.zig's class +
//! static-member candidate sources) so they can never drift: a name
//! completes exactly when it resolves.
//!
//! Registry keys ARE the JVM-visible FQCNs (ADR-0174 D1 — the former
//! `cljw.` key prefix and its translation step are retired), so the key
//! is also the user-facing spelling: `(class x)`, `.getName`, and the
//! print form all read the descriptor's fqcn with no translation layer.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const TypeDescriptor = @import("type_descriptor.zig").TypeDescriptor;
const Namespace = @import("env.zig").Namespace;

/// Resolve `head` (a class symbol's text) to its TypeDescriptor:
///   1. `rt.types.get(head)` — exact key (deftype names, `clojure.lang.*`,
///      any fully-qualified `java.*` name).
///   2. For dot-free heads: the per-ns `(:import …)` simple-name map
///      (D-235), then the `java.lang.*` auto-import (ADR-0050 §R3),
///      then the `java.math.BigDecimal`/`BigInteger` default imports.
/// `imports_ns` supplies the `(:import …)` map (null → skip that step).
pub fn resolve(rt: *Runtime, imports_ns: ?*const Namespace, head: []const u8) ?*const TypeDescriptor {
    if (rt.types.get(head)) |td| return td;
    if (std.mem.findScalar(u8, head, '.') == null) {
        if (imports_ns) |ns| {
            if (ns.imports.get(head)) |fqcn| {
                if (rt.types.get(fqcn)) |td| return td;
            }
        }
        var buf: [256]u8 = undefined;
        const auto = std.fmt.bufPrint(&buf, "java.lang.{s}", .{head}) catch return null;
        if (rt.types.get(auto)) |td| return td;
        if (std.mem.eql(u8, head, "BigDecimal") or std.mem.eql(u8, head, "BigInteger")) {
            var buf2: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&buf2, "java.math.{s}", .{head}) catch return null;
            if (rt.types.get(m)) |td| return td;
        }
    }
    return null;
}

/// Whether the registry key is reachable as a BARE simple name from
/// `imports_ns` — the java.lang.* / java.math default imports, or a
/// per-ns `(:import …)` entry. Returns the simple name when it is.
pub fn bareName(imports_ns: ?*const Namespace, key: []const u8) ?[]const u8 {
    const simple = if (std.mem.findScalarLast(u8, key, '.')) |dot| key[dot + 1 ..] else key;
    if (std.mem.startsWith(u8, key, "java.lang.")) return simple;
    if (std.mem.startsWith(u8, key, "java.math.Big")) return simple;
    if (imports_ns) |ns| {
        if (ns.imports.get(simple)) |fqcn| {
            if (std.mem.eql(u8, fqcn, key)) return simple;
        }
    }
    return null;
}

test "resolve is exact-key + auto-import driven (no key translation)" {
    // bareName: java.lang auto-import exposes the simple name; a
    // non-auto-imported package does not.
    try std.testing.expectEqualStrings("Character", bareName(null, "java.lang.Character").?);
    try std.testing.expectEqualStrings("BigDecimal", bareName(null, "java.math.BigDecimal").?);
    try std.testing.expect(bareName(null, "java.util.Date") == null);
    try std.testing.expect(bareName(null, "clojure.lang.PersistentQueue") == null);
}
