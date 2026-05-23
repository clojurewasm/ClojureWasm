// SPDX-License-Identifier: EPL-2.0
//! cw v1 class system — TypeDescriptor / TypedInstance / ReifiedInstance
//! struct declarations only (Phase 4 skeleton per ROADMAP §9.6 / 4.17
//! and ADR-0007 Option β).
//!
//! Phase 4 entry lands only the type shapes. `lookupMethod` /
//! `register` / `new` operations are Phase 5 work (per ADR-0007 §Phase
//! 5+ migration note) and rewrite primitives in
//! `src/runtime/collection/*.zig` to carry a back-pointer to a native
//! TypeDescriptor. Until then, the cw runtime keeps the Phase-3
//! keyword-only `(type x)` dispatch.

const std = @import("std");
const Value = @import("value.zig").Value;

/// Discriminates `TypeDescriptor`'s origin so dispatch can fast-path
/// the common cases. `native` covers the cw primitive types (String,
/// List, Keyword, ...); `deftype` / `defrecord` cover user
/// `(deftype …)` / `(defrecord …)` forms; `reify_anon` is the
/// anonymous descriptor a `reify` form produces.
pub const TypeKind = enum {
    native,
    deftype,
    defrecord,
    reify_anon,
};

/// Descriptor for one type. Layout is final at Phase 4 (Phase 5
/// activation populates the function pointers but does not reshape
/// the struct). `fqcn` is `?[]const u8` because `reify_anon`
/// descriptors carry no fully-qualified class name.
pub const TypeDescriptor = struct {
    fqcn: ?[]const u8,
    kind: TypeKind,
    /// Field name → slot index, in declaration order. `null` for
    /// `reify_anon` (which has no positional field layout).
    field_layout: ?[]const FieldEntry,
    /// Protocols this descriptor implements (Phase 7 wires the
    /// dispatch cache; Phase 4 holds the names only).
    protocol_impls: []const []const u8,
    /// Method table. Phase 5 populates entries; Phase 7 caches
    /// resolutions per call site. Phase 4 declares the slice shape.
    method_table: []const MethodEntry,
    /// Parent descriptor, when `kind == .defrecord` extends another
    /// record (rare but valid in Clojure). `null` otherwise.
    parent: ?*const TypeDescriptor,
    /// User-attached metadata Value (Clojure `meta` map). `nil_val`
    /// when none.
    meta: Value,

    pub const FieldEntry = struct {
        name: []const u8,
        index: u16,
    };

    pub const MethodEntry = struct {
        protocol_name: []const u8,
        method_name: []const u8,
        /// Function pointer; `null` at Phase 4 (Phase 5 wires real
        /// implementations via `register`).
        fn_ptr: ?*const anyopaque,
    };
};

/// A `deftype` / `defrecord` runtime value. The fields slice is
/// sized by `descriptor.field_layout.?.len` at allocation time and
/// lives alongside the value (cw allocator strategy, not a separate
/// allocation per field).
pub const TypedInstance = struct {
    descriptor: *const TypeDescriptor,
    field_values: []Value,
};

/// A `reify` runtime value. Closed-over locals from the surrounding
/// lexical scope live here; the anonymous descriptor lives on
/// `descriptor` and is never registered into a namespace.
pub const ReifiedInstance = struct {
    descriptor: *const TypeDescriptor,
    closure_bindings: []Value,
};

// --- tests ---

const testing = std.testing;

test "TypeDescriptor struct layout: fqcn is optional, kind is required" {
    const td: TypeDescriptor = .{
        .fqcn = "user.MyType",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    try testing.expect(td.fqcn != null);
    try testing.expectEqualStrings("user.MyType", td.fqcn.?);
    try testing.expectEqual(TypeKind.deftype, td.kind);
}

test "TypeDescriptor: reify_anon variant carries no fqcn" {
    const td: TypeDescriptor = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    try testing.expect(td.fqcn == null);
    try testing.expectEqual(TypeKind.reify_anon, td.kind);
}

test "FieldEntry indexes are stable u16 slots" {
    const entries = [_]TypeDescriptor.FieldEntry{
        .{ .name = "x", .index = 0 },
        .{ .name = "y", .index = 1 },
    };
    try testing.expectEqual(@as(u16, 1), entries[1].index);
}

test "MethodEntry fn_ptr stays null at Phase 4 skeleton" {
    const m: TypeDescriptor.MethodEntry = .{
        .protocol_name = "ISeq",
        .method_name = "first",
        .fn_ptr = null,
    };
    try testing.expect(m.fn_ptr == null);
}
