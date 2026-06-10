// SPDX-License-Identifier: EPL-2.0
//! `java.sql.Timestamp` VALUE (D-382) — a nanosecond-precision instant.
//!
//! Mirrors the Date model (`date.zig`, ADR-0079): a no-slot cljw-native
//! `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag) carrying TWO
//! fields — epoch-millis + the full fractional-second in nanoseconds
//! (0..999_999_999) — plus a per-Runtime `.native` descriptor whose
//! `print_tag = "inst"` makes the printer emit `#inst "<ISO with 9-digit
//! fraction>"`. The parse/format lives in the sibling `instant.zig` (F-009
//! neutral home); the Clojure `clojure.instant/read-instant-timestamp`
//! surface + a future `java.sql.Timestamp` surface wrap this from above.
//!
//! Distinct from Date by the per-Runtime descriptor pointer (so `=` / print /
//! `(class …)` discriminate), and richer by the second field (sub-ms nanos).

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const Runtime = @import("../runtime.zig").Runtime;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;

/// The per-Runtime canonical Timestamp descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "Timestamp"` so
/// `(class …)` prints the simple name (AD-003 / no-JVM); `print_tag = "inst"`
/// drives the `#inst "…"` print form (with 9-digit nanos — the printer picks
/// the nanos format off the 2-field shape).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.timestamp_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "Timestamp",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .print_tag = "inst",
    };
    rt.timestamp_descriptor = td;
    return td;
}

/// Build a Timestamp from epoch-millis + the full fractional-second nanos
/// (0..999_999_999). Two typed_instance fields.
pub fn make(rt: *Runtime, epoch_ms: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(epoch_ms), Value.initInteger(nanos) });
}

/// True when `v` is a Timestamp (carries the per-Runtime Timestamp descriptor).
pub fn isTimestamp(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.timestamp_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
}

/// The epoch-millis field. Caller must have checked `isTimestamp`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The fractional-second nanos field. Caller must have checked `isTimestamp`.
pub fn nanosOf(v: Value) i32 {
    return @intCast(v.decodePtr(*const TypedInstance).fields()[1].asInteger());
}

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.timestamp_descriptor) |td| {
        rt.gc.infra.destroy(td);
        rt.timestamp_descriptor = null;
    }
}

// --- tests ---

const testing = std.testing;

test "Timestamp value: make / isTimestamp / epochMsOf / nanosOf" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const ts = try make(&rt, 1_704_067_200_000, 123_456_789);
    try testing.expect(ts.tag() == .typed_instance);
    try testing.expect(isTimestamp(&rt, ts));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(ts));
    try testing.expectEqual(@as(i32, 123_456_789), nanosOf(ts));
    try testing.expectEqualStrings("inst", ts.decodePtr(*const TypedInstance).descriptor.print_tag.?);
    try testing.expect(!isTimestamp(&rt, Value.initInteger(5)));
}
