// SPDX-License-Identifier: EPL-2.0
//! UUID v4 generation + parsing — namespace-neutral implementation
//! per F-009.
//!
//! Two surfaces consume this file:
//!   1. `lang/primitive/uuid.zig` — Clojure-ns peer (`random-uuid`
//!      / `parse-uuid` in clojure.core).
//!   2. `runtime/java/util/UUID.zig` — Java surface
//!      (`(java.util.UUID/randomUUID)` etc.).
//!
//! Both call into `generateV4(...)` / `format(...)` / `parse(...)`
//! here; neither knows about the other. F-009's "neutral impl,
//! surfaces are thin wrappers" applies.
//!
//! ## The UUID value type (ADR-0074)
//!
//! `UuidValue` is the first-class `.uuid` heap Value (NaN-box slot B15).
//! `#uuid "…"`, `random-uuid`, `parse-uuid`, and `java.util.UUID/randomUUID`
//! all produce it, so cljw has ONE coherent UUID representation that
//! round-trips through `pr-str` (`#uuid "…"`) and answers `uuid?` / `class`.
//! The 16 bytes sit inline in the heap struct (no `gc.infra` payload), so
//! the GC trace walks only `meta` and no finaliser is needed.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

/// 16-byte UUID payload (RFC 4122 big-endian field order).
pub const Bytes = [16]u8;

/// 36-character lowercase canonical form (`8-4-4-4-12`).
pub const Canonical = [36]u8;

/// Generate a random UUID v4 byte sequence. Sets the version
/// (`bytes[6] = (bytes[6] & 0x0F) | 0x40`) and variant
/// (`bytes[8] = (bytes[8] & 0x3F) | 0x80`) per RFC 4122.
///
/// Phase 6 takes an `std.Io` so the caller chooses between
/// `std.Io.randomSecure` (kernel CSPRNG via getrandom) and
/// `std.Io.random` (fast PRNG fallback). Per F-006 + ADR-0015
/// Tier 1/2 split, the io handle is the single point of
/// pluggability; an `io_interface`-mediated random source can
/// land later if the abstraction grows.
pub fn generateV4(io: std.Io) Bytes {
    var b: Bytes = undefined;
    std.Io.randomSecure(io, &b) catch std.Io.random(io, &b);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    return b;
}

/// Format a 16-byte UUID as the canonical lowercase 36-char form.
pub fn format(b: Bytes) Canonical {
    var out: Canonical = undefined;
    const hex = "0123456789abcdef";
    var oi: usize = 0;
    for (b, 0..) |byte, i| {
        out[oi] = hex[byte >> 4];
        out[oi + 1] = hex[byte & 0x0F];
        oi += 2;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            out[oi] = '-';
            oi += 1;
        }
    }
    return out;
}

pub const ParseError = error{InvalidUuid};

/// Parse a 36-char canonical UUID string back into its 16 bytes.
/// Returns `error.InvalidUuid` on length / hyphen-position / hex-
/// digit failures. Accepts upper- or lower-case hex digits.
pub fn parse(s: []const u8) ParseError!Bytes {
    if (s.len != 36) return error.InvalidUuid;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-')
        return error.InvalidUuid;
    var b: Bytes = undefined;
    var si: usize = 0;
    var bi: usize = 0;
    while (bi < 16) : (bi += 1) {
        if (si == 8 or si == 13 or si == 18 or si == 23) si += 1;
        const hi = nibble(s[si]) catch return error.InvalidUuid;
        const lo = nibble(s[si + 1]) catch return error.InvalidUuid;
        b[bi] = (hi << 4) | lo;
        si += 2;
    }
    return b;
}

fn nibble(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
}

// --- The .uuid heap value type (ADR-0074) ---

/// Heap-managed UUID Value. `header` at offset 0 (gc.alloc invariant);
/// the 16 RFC-4122 bytes sit INLINE (no gc.infra payload → no finaliser).
/// `meta` carries optional user metadata.
pub const UuidValue = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    bytes: Bytes,
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(UuidValue) >= 8);
        std.debug.assert(@offsetOf(UuidValue, "header") == 0);
    }
};

/// Wrap 16 UUID bytes in a fresh `.uuid` heap Value.
pub fn alloc(rt: *Runtime, b: Bytes) !Value {
    const u = try rt.gc.alloc(UuidValue);
    u.* = .{ .header = HeapHeader.init(.uuid), .bytes = b, .meta = Value.nil_val };
    return Value.encodeHeapPtr(.uuid, u);
}

/// Decode a `.uuid` Value to its carrier. Caller verifies `v.tag() == .uuid`.
pub fn asUuid(v: Value) *const UuidValue {
    std.debug.assert(v.tag() == .uuid);
    return v.decodePtr(*const UuidValue);
}

/// Canonical 36-char form of a `.uuid` Value (for `str` / printing).
pub fn canonicalOf(v: Value) Canonical {
    return format(asUuid(v).bytes);
}

/// Per-tag trace: the bytes are inline, so only `meta` needs marking.
fn traceUuid(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const u: *UuidValue = @ptrCast(@alignCast(header));
    if (u.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.uuid, &traceUuid);
    // No finaliser — the 16 bytes are inline (no gc.infra payload to free).
}

// --- tests ---

const testing = std.testing;

test "generateV4 sets version=4 (high nibble of byte 6) and variant=10xx (high bits of byte 8)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const b = generateV4(th.io());
    try testing.expectEqual(@as(u8, 0x40), b[6] & 0xF0);
    try testing.expectEqual(@as(u8, 0x80), b[8] & 0xC0);
}

test "format produces 36 chars with hyphens at the right positions" {
    const b: Bytes = .{ 0x12, 0x34, 0x56, 0x78, 0xab, 0xcd, 0x4e, 0xf0, 0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde };
    const s = format(b);
    try testing.expectEqualStrings("12345678-abcd-4ef0-8012-3456789abcde", &s);
}

test "parse round-trips a canonical UUID" {
    const b: Bytes = .{ 0x12, 0x34, 0x56, 0x78, 0xab, 0xcd, 0x4e, 0xf0, 0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde };
    const s = format(b);
    const parsed = try parse(&s);
    try testing.expectEqualSlices(u8, &b, &parsed);
}

test "parse rejects wrong length" {
    try testing.expectError(error.InvalidUuid, parse("too short"));
    try testing.expectError(error.InvalidUuid, parse("12345678-abcd-4ef0-8012-3456789abcdex"));
}

test "parse rejects wrong hyphen positions" {
    try testing.expectError(error.InvalidUuid, parse("12345678xabcd-4ef0-8012-3456789abcde"));
}

test "canonicalOf round-trips a .uuid value's bytes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const b: Bytes = .{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    const v = try alloc(&rt, b);
    try testing.expectEqual(value_mod.Value.Tag.uuid, v.tag());
    const canon = canonicalOf(v);
    try testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", &canon);
    try testing.expectEqualSlices(u8, &b, &asUuid(v).bytes);
}
