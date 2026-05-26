// SPDX-License-Identifier: EPL-2.0
//! Per-call-site dispatch cache for `.method` invocations
//! (ROADMAP §9.6 / 4.25, ADR-0008).
//!
//! Phase 4 entry ships the `CallSite` struct declaration only. The
//! `dispatch(callsite, receiver, method, args)` function lands at
//! Phase 7 (ADR-0008 amendment 1) with cache-fill on miss.
//!
//! Naming note: the actual per-implementation method record lives
//! at `type_descriptor.zig::TypeDescriptor.MethodEntry` (landed at
//! 4.17). `CallSite.last_method` caches a pointer into that table.
//! A separate `MethodEntry` struct is NOT declared here — see
//! debt D-040 for the cross-file naming reconciliation queued at
//! Phase 7 entry (where the protocol-declaration entry in
//! `protocol.zig` and the type-implementation entry in
//! `type_descriptor.zig` are renamed together with the dispatch
//! function landing).

const std = @import("std");
const TypeDescriptor = @import("../type_descriptor.zig").TypeDescriptor;
const Value = @import("../value/value.zig").Value;

/// Per-call-site monomorphic cache slot.
///
/// At analyzer time, every `.method` call site is given a `CallSite`
/// instance whose two cache slots start `null`. The Phase 7 dispatch
/// function consults the cache:
///
///   1. If `last_type == receiver.typeDescriptor()`, jump directly to
///      `last_method.fn_ptr` (monomorphic fast path).
///   2. Otherwise, fall through to `TypeDescriptor.lookupMethod` and
///      refill both slots.
///
/// The two-slot shape mirrors C2 / V8's inline-cache pattern; cw v1
/// does not (yet) escalate to polymorphic or megamorphic states. If
/// benchmarks at Phase 7+ surface megamorphic hot sites, the cache
/// is widened in place — the `CallSite` consumer surface is just
/// "ask + refill", so widening is local to this file.
pub const CallSite = struct {
    last_type: ?*const TypeDescriptor = null,
    last_method: ?*const TypeDescriptor.MethodEntry = null,
    /// `Runtime.protocol_generation` snapshot at the time the slot
    /// was filled. Cycle 7.3.2: a cache hit additionally requires
    /// `cached_generation == rt.protocol_generation`. When
    /// `extend-type` bumps the counter, prior caches detect the
    /// drift on next dispatch and miss-refill against the fresh
    /// `td.method_table` pointer. Per ADR-0008 amendment 1 Alt 1.
    cached_generation: u32 = 0,

    /// Look up `(protocol, method)` on `td` with monomorphic cache.
    /// Hit short-circuits straight to the cached MethodEntry when:
    ///   - `last_type == td`,
    ///   - `cached_generation == current_generation` (= no
    ///     `extend-type` mutation since the slot filled),
    ///   - `(protocol_name, method_name)` matches the cached entry.
    /// Otherwise falls through to `TypeDescriptor.lookupMethod` and
    /// refills all three cache slots. Returns `null` when no
    /// implementation exists on the descriptor chain (caller raises
    /// `value_not_callable` or a protocol-specific error).
    pub fn lookupWithCache(
        self: *CallSite,
        td: *const TypeDescriptor,
        protocol_name: []const u8,
        method_name: []const u8,
        current_generation: u32,
    ) ?*const TypeDescriptor.MethodEntry {
        if (self.last_type == td and self.cached_generation == current_generation) {
            if (self.last_method) |m| {
                if (std.mem.eql(u8, m.protocol_name, protocol_name) and
                    std.mem.eql(u8, m.method_name, method_name))
                {
                    return m;
                }
            }
        }
        const found = td.lookupMethod(protocol_name, method_name) orelse return null;
        self.last_type = td;
        self.last_method = found;
        self.cached_generation = current_generation;
        return found;
    }
};

// --- tests ---

const testing = std.testing;

test "CallSite default-initialises with both cache slots null" {
    const cs: CallSite = .{};
    try testing.expect(cs.last_type == null);
    try testing.expect(cs.last_method == null);
}

test "lookupWithCache fills the cache on miss and short-circuits on hit" {
    const entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "ISeq", .method_name = "first", .method_val = Value.nil_val },
    };
    const td: TypeDescriptor = .{
        .fqcn = "user.Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{"ISeq"},
        .method_table = &entries,
        .parent = null,
        .meta = .nil_val,
    };
    var cs: CallSite = .{};
    // First call: miss, fills cache.
    const m1 = cs.lookupWithCache(&td, "ISeq", "first", 0).?;
    try testing.expect(cs.last_type.? == &td);
    try testing.expect(cs.last_method.? == m1);
    // Second call: hit, returns the same pointer (cache short-circuit).
    const m2 = cs.lookupWithCache(&td, "ISeq", "first", 0).?;
    try testing.expect(m1 == m2);
}

test "lookupWithCache cache miss when (protocol, method) differs from cache" {
    const entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "ISeq", .method_name = "first", .method_val = Value.nil_val },
        .{ .protocol_name = "ISeq", .method_name = "rest", .method_val = Value.nil_val },
    };
    const td: TypeDescriptor = .{
        .fqcn = "user.Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{"ISeq"},
        .method_table = &entries,
        .parent = null,
        .meta = .nil_val,
    };
    var cs: CallSite = .{};
    _ = cs.lookupWithCache(&td, "ISeq", "first", 0);
    // Now ask for a different method on the same type — cache slot
    // refills because the cached method_name doesn't match.
    const m_rest = cs.lookupWithCache(&td, "ISeq", "rest", 0).?;
    try testing.expectEqualStrings("rest", m_rest.method_name);
}

test "lookupWithCache returns null when method is not on the descriptor" {
    const td: TypeDescriptor = .{
        .fqcn = "user.Bare",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    var cs: CallSite = .{};
    try testing.expect(cs.lookupWithCache(&td, "IAny", "missing", 0) == null);
    try testing.expect(cs.last_type == null);
    try testing.expect(cs.last_method == null);
}

test "lookupWithCache misses when current_generation differs from cached_generation" {
    const entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "ISeq", .method_name = "first", .method_val = Value.nil_val },
    };
    const td: TypeDescriptor = .{
        .fqcn = "user.Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{"ISeq"},
        .method_table = &entries,
        .parent = null,
        .meta = .nil_val,
    };
    var cs: CallSite = .{};
    // Fill the cache at generation 0.
    _ = cs.lookupWithCache(&td, "ISeq", "first", 0);
    try testing.expectEqual(@as(u32, 0), cs.cached_generation);

    // Simulate an extend-type bump: generation advances. Even though
    // (td, protocol, method) match the cache, the generation mismatch
    // forces a miss + refill against td.method_table (which in
    // production has been re-allocated by extendTypeWithImpls).
    _ = cs.lookupWithCache(&td, "ISeq", "first", 7);
    try testing.expectEqual(@as(u32, 7), cs.cached_generation);
}

test "CallSite cache slots accept TypeDescriptor + MethodEntry pointers" {
    const td: TypeDescriptor = .{
        .fqcn = "user.MyType",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    const me: TypeDescriptor.MethodEntry = .{
        .protocol_name = "ISeq",
        .method_name = "first",
        .method_val = Value.nil_val,
    };
    const cs: CallSite = .{ .last_type = &td, .last_method = &me };
    try testing.expect(cs.last_type.? == &td);
    try testing.expectEqualStrings("first", cs.last_method.?.method_name);
}
