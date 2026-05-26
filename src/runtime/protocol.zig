// SPDX-License-Identifier: EPL-2.0
//! Protocol dispatch table — `ProtocolDescriptor` + `MethodEntry`
//! struct declarations (ROADMAP §9.6 / 4.18, ADR-0008).
//!
//! Phase 4 entry ships declarations only. The `dispatch` function
//! lands at Phase 7 alongside the `CallSite` cache (per ADR-0008's
//! Phase 7 entry activation). Phase 4 freezes the struct layout so
//! `TypeDescriptor.method_table` (4.17) and the future call-site
//! cache (4.25) can reference these types now.

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const Runtime = @import("runtime.zig").Runtime;
const td_mod = @import("type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;

/// One method on a protocol — name + arity (Clojure protocols are
/// arity-overloaded). The implementation pointer lives on the
/// implementing `TypeDescriptor.method_table` entry, not here; this
/// descriptor only declares the protocol's surface.
pub const MethodEntry = struct {
    name: []const u8,
    arity: u8,
};

/// One protocol — fully-qualified name + the methods it declares.
/// Implementations are registered on the implementing type's
/// `TypeDescriptor` (4.17), so a protocol descriptor itself carries
/// no `*const fn` pointers.
///
/// Row 7.3 cycle 4: migrated to `extern struct` with HeapHeader at
/// field 0 so cycle 5's `__make-protocol!` primitive can return a
/// `.protocol`-tagged Value (Group B slot 18). The `fqcn` and
/// `methods` fields decompose to ptr+len pairs (extern struct
/// forbids fat pointers — same workaround `MultiFn.name = Symbol
/// Value` used at row 7.2 + `ProtocolFn.method_name_ptr/_len` from
/// cycle 3).
pub const ProtocolDescriptor = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// Fully-qualified name backing bytes (interned, runtime-owned).
    fqcn_ptr: [*]const u8,
    fqcn_len: usize,
    /// Declared methods array — pointer + length; the array's
    /// `MethodEntry` elements stay plain struct (slice fields in
    /// MethodEntry are fine because the array itself is referenced
    /// by raw pointer, ABI-clean).
    methods_ptr: [*]const MethodEntry,
    methods_len: usize,

    /// Return the fqcn as a `[]const u8` slice.
    pub fn fqcn(self: *const ProtocolDescriptor) []const u8 {
        return self.fqcn_ptr[0..self.fqcn_len];
    }

    /// Return the methods array as a `[]const MethodEntry` slice.
    pub fn methods(self: *const ProtocolDescriptor) []const MethodEntry {
        return self.methods_ptr[0..self.methods_len];
    }
};

/// Allocate a `ProtocolDescriptor` Value on `rt.gc.infra`. Caller
/// supplies the interned fqcn slice + the methods array. Returns a
/// `.protocol`-tagged Value.
pub fn makeProtocol(
    rt: *Runtime,
    fqcn_slice: []const u8,
    methods_slice: []const MethodEntry,
) !Value {
    const pd = try rt.gc.infra.create(ProtocolDescriptor);
    pd.* = .{
        .header = HeapHeader.init(.protocol),
        .fqcn_ptr = fqcn_slice.ptr,
        .fqcn_len = fqcn_slice.len,
        .methods_ptr = methods_slice.ptr,
        .methods_len = methods_slice.len,
    };
    return Value.encodeHeapPtr(.protocol, pd);
}

/// Decode a `.protocol`-tagged Value back to its
/// `*const ProtocolDescriptor`. Asserts the tag.
pub fn asProtocol(val: Value) *const ProtocolDescriptor {
    std.debug.assert(val.tag() == .protocol);
    return val.decodePtr(*const ProtocolDescriptor);
}

/// Per-method dispatch handle, allocated when `(defprotocol P (m
/// [this]) ...)` evaluates. Carries the (descriptor, method-name)
/// pair that cycle 4's `(m receiver args)` callable Value uses to
/// route through the row 7.1 dispatch ABI. Sits on F-004 Group B
/// slot 19 (`.protocol_fn`, declared in heap_tag.zig); CallSite is
/// NOT carried here — analyzer-time per-call-site CallSite slots
/// remain the cache location, this struct is just the per-method
/// handle.
pub const ProtocolFn = extern struct {
    header: HeapHeader,
    // Pad to align Value-sized fields to 16 — header is 8 bytes,
    // but the descriptor pointer + method_name slice need an even
    // boundary so the C-ABI layout is portable.
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// Owning protocol descriptor. Process-lifetime (allocated on
    /// `rt.gc.infra`), so the pointer is stable for the runtime's
    /// lifetime.
    descriptor: *const ProtocolDescriptor,
    /// Interned method name (bytes owned by the symbol pool).
    method_name_ptr: [*]const u8,
    method_name_len: usize,

    /// Return the method name as a `[]const u8` slice.
    pub fn methodName(self: *const ProtocolFn) []const u8 {
        return self.method_name_ptr[0..self.method_name_len];
    }
};

/// Allocate a `ProtocolFn` Value on `rt.gc.infra`. Caller supplies
/// the owning ProtocolDescriptor pointer + the method's interned
/// name slice. Returns a `.protocol_fn`-tagged Value pointing at
/// the new struct.
pub fn makeProtocolFn(
    rt: *Runtime,
    descriptor: *const ProtocolDescriptor,
    method_name: []const u8,
) !Value {
    const pfn = try rt.gc.infra.create(ProtocolFn);
    pfn.* = .{
        .header = HeapHeader.init(.protocol_fn),
        .descriptor = descriptor,
        .method_name_ptr = method_name.ptr,
        .method_name_len = method_name.len,
    };
    return Value.encodeHeapPtr(.protocol_fn, pfn);
}

/// Decode a `.protocol_fn`-tagged Value back to its `*ProtocolFn`.
/// Asserts the tag (callers must check `val.tag() == .protocol_fn`
/// beforehand).
pub fn asProtocolFn(val: Value) *const ProtocolFn {
    std.debug.assert(val.tag() == .protocol_fn);
    return val.decodePtr(*const ProtocolFn);
}

/// Row 7.3 cycle 5: does `td` (or any descriptor up its `.parent`
/// chain) carry at least one MethodEntry for `proto.fqcn`? Mirrors
/// `clojure.core/satisfies?` semantics — the user-facing predicate
/// only cares about presence, not which methods. The future
/// `__satisfies?` primitive (cycle 6+) calls this on a
/// typed_instance's descriptor.
pub fn satisfies(proto: *const ProtocolDescriptor, td: *const TypeDescriptor) bool {
    const target_name = proto.fqcn();
    var cursor: ?*const TypeDescriptor = td;
    while (cursor) |t| {
        for (t.method_table) |entry| {
            if (std.mem.eql(u8, entry.protocol_name, target_name)) return true;
        }
        cursor = t.parent;
    }
    return false;
}

/// Row 7.3 cycle 1: append `new_impls` to `td.method_table` and bump
/// `rt.protocol_generation`. The TypeDescriptor's `method_table` is
/// re-allocated on `rt.gc.infra` (process-lifetime) so the new slice
/// pointer stays valid for the descriptor's lifetime; the old slice
/// is leaked to infra rather than freed because live CallSite caches
/// may still reference the stale pointer until the next dispatch
/// invalidates them via the generation check.
///
/// Per survey §5.2 + ADR-0008 amendment 1 Alt 1 ("generation deferred
/// to 7.3 / extend-type"). cycle 2 wires CallSite.cached_generation
/// + the lookupWithCache predicate that consumes the bump.
pub fn extendTypeWithImpls(
    rt: *Runtime,
    td: *TypeDescriptor,
    new_impls: []const TypeDescriptor.MethodEntry,
) !void {
    const old = td.method_table;
    const combined = try rt.gc.infra.alloc(TypeDescriptor.MethodEntry, old.len + new_impls.len);
    @memcpy(combined[0..old.len], old);
    @memcpy(combined[old.len..], new_impls);
    td.method_table = combined;
    rt.protocol_generation +%= 1;
}

// --- tests ---

const testing = std.testing;

test "MethodEntry shape" {
    const m: MethodEntry = .{ .name = "first", .arity = 1 };
    try testing.expectEqualStrings("first", m.name);
    try testing.expectEqual(@as(u8, 1), m.arity);
}

test "ProtocolDescriptor: fqcn + method list shape" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const ms = [_]MethodEntry{
        .{ .name = "first", .arity = 1 },
        .{ .name = "rest", .arity = 1 },
        .{ .name = "cons", .arity = 2 },
    };
    const v = try makeProtocol(&rt, "user/ISeq", &ms);
    defer rt.gc.infra.destroy(@constCast(asProtocol(v)));

    try testing.expect(v.tag() == .protocol);
    const pd = asProtocol(v);
    try testing.expectEqualStrings("user/ISeq", pd.fqcn());
    try testing.expectEqual(@as(usize, 3), pd.methods().len);
    try testing.expectEqualStrings("first", pd.methods()[0].name);
}

test "makeProtocolFn allocates a .protocol_fn Value carrying descriptor + method name" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const ms = [_]MethodEntry{
        .{ .name = "first", .arity = 1 },
    };
    const proto_val = try makeProtocol(&rt, "user/ISeq", &ms);
    defer rt.gc.infra.destroy(@constCast(asProtocol(proto_val)));
    const proto = asProtocol(proto_val);

    const v = try makeProtocolFn(&rt, proto, "first");
    defer rt.gc.infra.destroy(@constCast(asProtocolFn(v)));
    try testing.expect(v.tag() == .protocol_fn);

    const pfn = asProtocolFn(v);
    try testing.expect(pfn.descriptor == proto);
    try testing.expectEqualStrings("first", pfn.methodName());
}

test "satisfies returns true when td.method_table carries any entry for proto.fqcn" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    // Protocol "user/ISeq" with 1 method declared.
    const ms = [_]MethodEntry{ .{ .name = "first", .arity = 1 } };
    const proto_v = try makeProtocol(&rt, "user/ISeq", &ms);
    defer rt.gc.infra.destroy(@constCast(asProtocol(proto_v)));
    const proto = asProtocol(proto_v);

    // TypeDescriptor with NO implementation of user/ISeq → satisfies = false.
    const td_empty = try rt.gc.infra.create(TypeDescriptor);
    defer rt.gc.infra.destroy(td_empty);
    td_empty.* = .{
        .fqcn = "user/Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &[_][]const u8{},
        .method_table = &[_]TypeDescriptor.MethodEntry{},
        .parent = null,
        .meta = Value.nil_val,
    };
    try testing.expect(!satisfies(proto, td_empty));

    // After extending with an ISeq.first impl → satisfies = true.
    const new_impls = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "user/ISeq", .method_name = "first", .fn_ptr = null },
    };
    try extendTypeWithImpls(&rt, td_empty, &new_impls);
    defer rt.gc.infra.free(td_empty.method_table);

    try testing.expect(satisfies(proto, td_empty));
}

test "extendTypeWithImpls bumps protocol_generation and grows method_table" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    // Synthetic descriptor with empty method_table on `rt.gc.infra`.
    // Production deftype / defrecord analysers register descriptors
    // into `rt.types` (which Runtime.deinit then walks); this test
    // pre-empts that machinery by managing the descriptor's lifetime
    // explicitly.
    const td = try rt.gc.infra.create(TypeDescriptor);
    defer rt.gc.infra.destroy(td);
    td.* = .{
        .fqcn = "user/Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &[_][]const u8{},
        .method_table = &[_]TypeDescriptor.MethodEntry{},
        .parent = null,
        .meta = @import("value/value.zig").Value.nil_val,
    };

    try testing.expectEqual(@as(u32, 0), rt.protocol_generation);
    try testing.expectEqual(@as(usize, 0), td.method_table.len);

    const new_impls = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "user/IFoo", .method_name = "bar", .fn_ptr = null },
    };
    try extendTypeWithImpls(&rt, td, &new_impls);
    // Per the "re-alloc + swap, never free old" policy, the heap-
    // allocated slice replacing the empty static one must be freed
    // explicitly when the test exits. Production code accepts the
    // leak because live CallSite caches may still reference the
    // stale pointer until the generation check invalidates them.
    defer rt.gc.infra.free(td.method_table);

    try testing.expectEqual(@as(u32, 1), rt.protocol_generation);
    try testing.expectEqual(@as(usize, 1), td.method_table.len);
    try testing.expectEqualStrings("bar", td.method_table[0].method_name);
    try testing.expectEqualStrings("user/IFoo", td.method_table[0].protocol_name);
}
