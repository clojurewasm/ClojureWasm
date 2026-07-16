// SPDX-License-Identifier: EPL-2.0
//! `java.sql.Timestamp` VALUE (D-382) — a nanosecond-precision instant.
//!
//! Mirrors the Date model (`date.zig`, ADR-0079): a no-slot cljw-native
//! `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag) carrying TWO
//! fields — epoch-millis + the full fractional-second in nanoseconds
//! (0..999_999_999) — plus the ONE canonical `rt.types["java.sql.Timestamp"]`
//! descriptor (ADR-0174) whose `print_tag = "inst"` makes the printer emit
//! `#inst "<ISO with 9-digit fraction>"`. The parse/format lives in the
//! sibling `instant.zig` (F-009 neutral home); the Clojure
//! `clojure.instant/read-instant-timestamp` surface + a future
//! `java.sql.Timestamp` surface wrap this from above.
//!
//! Distinct from Date by the descriptor's fqcn (so `=` / print / `(class …)`
//! discriminate), and richer by the second field (sub-ms nanos).

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const Runtime = @import("../runtime.zig").Runtime;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;

/// The JVM-visible class name — also the `rt.types` registry key
/// (ADR-0174 D1: Java-surface-backed classes carry their JVM FQCN).
pub const FQCN = "java.sql.Timestamp";

fn configureDescriptor(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    _ = gpa; // no instance methods yet — only the print flag
    // The printer picks the 9-digit-nanos `#inst` format off the 2-field shape.
    td.print_tag = "inst";
}

/// The ONE canonical Timestamp descriptor: `rt.types["java.sql.Timestamp"]`
/// (ADR-0174 D2 merge). No static surface exists yet, so this mints +
/// registers on first use.
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FQCN, &configureDescriptor);
}

/// Build a Timestamp from epoch-millis + the full fractional-second nanos
/// (0..999_999_999). Two typed_instance fields.
pub fn make(rt: *Runtime, epoch_ms: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(epoch_ms), Value.initInteger(nanos) });
}

/// True when `v` is a Timestamp (carries the canonical Timestamp descriptor,
/// recognised by fqcn — rt-free).
pub fn isTimestamp(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// The epoch-millis field. Caller must have checked `isTimestamp`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The fractional-second nanos field. Caller must have checked `isTimestamp`.
pub fn nanosOf(v: Value) i32 {
    return @intCast(v.decodePtr(*const TypedInstance).fields()[1].asInteger());
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
    try testing.expect(isTimestamp(ts));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(ts));
    try testing.expectEqual(@as(i32, 123_456_789), nanosOf(ts));
    try testing.expectEqualStrings("inst", ts.decodePtr(*const TypedInstance).descriptor.print_tag.?);
    try testing.expect(!isTimestamp(Value.initInteger(5)));
}
