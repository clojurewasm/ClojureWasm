// SPDX-License-Identifier: EPL-2.0
//! Per-call-site dispatch cache for `.method` invocations
//! (ROADMAP §9.6 / 4.25, ADR-0008).
//!
//! `CallSite` caches the resolved method for a `.method` call site;
//! `lookupWithCache` fills the cache on miss (ADR-0008 amendment 1).
//!
//! Naming note: the actual per-implementation method record lives
//! at `type_descriptor.zig::TypeDescriptor.MethodEntry`.
//! `CallSite.last_method` caches a pointer into that table. A
//! separate `MethodEntry` struct is NOT declared here; the
//! cross-file naming collision (protocol-declaration entry in
//! `protocol.zig` vs type-implementation entry in
//! `type_descriptor.zig`) was resolved by namespace-qualification
//! (D-040, discharged).

const std = @import("std");
const builtin = @import("builtin");
const TypeDescriptor = @import("../type_descriptor.zig").TypeDescriptor;
const Value = @import("../value/value.zig").Value;

/// Per-call-site monomorphic cache slot.
///
/// At analyzer time, every `.method` call site is given a `CallSite`
/// instance whose two cache slots start `null`. The dispatch
/// function consults the cache:
///
///   1. If `last_type == receiver.typeDescriptor()`, jump directly to
///      `last_method.fn_ptr` (monomorphic fast path).
///   2. Otherwise, fall through to `TypeDescriptor.lookupMethod` and
///      refill both slots.
///
/// The two-slot shape mirrors C2 / V8's inline-cache pattern; cw v1
/// does not (yet) escalate to polymorphic or megamorphic states. If
/// benchmarks later surface megamorphic hot sites, the cache
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
        protocol_name: ?[]const u8,
        method_name: []const u8,
        current_generation: u32,
    ) ?*const TypeDescriptor.MethodEntry {
        if (self.last_type == td and self.cached_generation == current_generation) {
            if (self.last_method) |m| {
                const proto_ok = if (protocol_name) |pn|
                    std.mem.eql(u8, m.protocol_name, pn)
                else
                    true;
                if (proto_ok and std.mem.eql(u8, m.method_name, method_name)) {
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

/// Per-protocol-method resolution cache, embedded in every `ProtocolFn`
/// (ADR-0206). Maps the receiver's TypeDescriptor to the FINAL resolved
/// method Value of the whole `dispatch.resolveProtocolMethod` chain
/// (per-type impl, then the ADR-0187 protocol-target, IRecord and Object
/// fallbacks), all of which are a pure function of `(td, protocol_generation)`.
/// Every mutation of a method table or of the fallback side tables bumps
/// `protocol_generation`, so a generation mismatch is the whole
/// invalidation story: extend-type, extend-protocol, extend, a re-extend that
/// replaces a row, and a redefined record (a NEW descriptor address) all miss.
/// Descriptors are never freed while the runtime lives (D-587 retirement), so
/// a stale `td` address cannot be reused by another type (no ABA).
/// Host-surface `init`s (`appendMethodEntries`, ADR-0174) write rows with
/// `protocol_name = ""` and no bump: interop members that a protocol lookup
/// never matches, so they cannot stale a memo. A failed resolution raises and
/// is never filled, so a `class_descriptors` insert (no bump) cannot either.
/// The cached `method_val` is not traced: its row roots it, and a replaced row
/// bumps the generation, so it is only returned while still rooted (a reify
/// descriptor's row lives until process exit, `trackHeap`).
/// Known gap (D-600): `protocol_generation` is a plain `+%= 1`, so two extends
/// racing on different threads can lose a bump.
///
/// Unlike `CallSite` (analyzer-arena, one owner), a `ProtocolFn` is shared by
/// every thread that calls it, so the slot is a seqlock: a reader that
/// observes an odd or changed `seq` treats the read as a miss, and a writer
/// that loses the even-to-odd race simply skips the fill. A torn
/// `(td, val)` pair therefore never dispatches.
pub const DispatchCache = extern struct {
    seq: u32 = 0,
    generation: u32 = 0,
    /// `@intFromPtr` of the cached receiver descriptor; 0 = empty.
    td_addr: usize = 0,
    method_val: Value = .nil_val,

    pub fn lookup(self: *const DispatchCache, td: *const TypeDescriptor, generation: u32) ?Value {
        const s1 = @atomicLoad(u32, &self.seq, .acquire);
        if (s1 & 1 != 0) return null;
        const addr = @atomicLoad(usize, &self.td_addr, .acquire);
        const gen = @atomicLoad(u32, &self.generation, .acquire);
        const val = loadMethodVal(&self.method_val);
        if (@atomicLoad(u32, &self.seq, .acquire) != s1) return null;
        if (addr != @intFromPtr(td) or gen != generation) return null;
        return val;
    }

    pub fn fill(self: *DispatchCache, td: *const TypeDescriptor, generation: u32, method_val: Value) void {
        const s0 = @atomicLoad(u32, &self.seq, .monotonic);
        if (s0 & 1 != 0) return;
        if (@cmpxchgStrong(u32, &self.seq, s0, s0 +% 1, .acquire, .monotonic) != null) return;
        @atomicStore(usize, &self.td_addr, @intFromPtr(td), .release);
        @atomicStore(u32, &self.generation, generation, .release);
        storeMethodVal(&self.method_val, method_val);
        @atomicStore(u32, &self.seq, s0 +% 2, .release);
    }
};

/// A `Value` is 64 bits wide, and 32-bit wasm has no 64-bit atomics. The
/// single-threaded targets (wasm32-wasi, ADR-0193) have no concurrent reader,
/// so a plain access is the whole seqlock there.
inline fn loadMethodVal(p: *const Value) Value {
    if (comptime builtin.single_threaded) return p.*;
    return @atomicLoad(Value, p, .acquire);
}

inline fn storeMethodVal(p: *Value, v: Value) void {
    if (comptime builtin.single_threaded) {
        p.* = v;
        return;
    }
    @atomicStore(Value, p, v, .release);
}

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

test "DispatchCache: hit on same (td, generation), miss on generation bump or another td" {
    const td_a: TypeDescriptor = .{ .fqcn = "A", .kind = .deftype, .field_layout = null, .protocol_impls = &.{}, .method_table = &.{}, .parent = null, .meta = Value.nil_val };
    const td_b: TypeDescriptor = .{ .fqcn = "B", .kind = .deftype, .field_layout = null, .protocol_impls = &.{}, .method_table = &.{}, .parent = null, .meta = Value.nil_val };
    var c: DispatchCache = .{};
    try testing.expect(c.lookup(&td_a, 0) == null);
    c.fill(&td_a, 3, Value.initInteger(7));
    try testing.expectEqual(Value.initInteger(7), c.lookup(&td_a, 3).?);
    try testing.expect(c.lookup(&td_a, 4) == null);
    try testing.expect(c.lookup(&td_b, 3) == null);
    c.fill(&td_b, 4, Value.initInteger(9));
    try testing.expectEqual(Value.initInteger(9), c.lookup(&td_b, 4).?);
    try testing.expect(c.lookup(&td_a, 3) == null);
    try testing.expectEqual(@as(u32, 4), c.seq);
}
