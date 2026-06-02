// SPDX-License-Identifier: EPL-2.0
//! `java.util.Date` VALUE (D-200 / clj-parity C6, ADR-0079).
//!
//! A `#inst "…"` literal / `java.util.Date` is a no-slot cljw-native value
//! (user β: F-004 layout UNCHANGED) — a `.typed_instance` carrying ONE
//! epoch-millis field + a per-Runtime `.native` descriptor whose
//! `print_tag = "inst"` makes the printer emit `#inst "<ISO>"`. The
//! epoch-ms parse/format lives in the sibling `instant.zig` (F-009 neutral
//! home); both the Clojure `#inst`/`inst?` surface and the Java
//! `java.util.Date` surface wrap this from above.
//!
//! The descriptor is per-Runtime (allocated on `gc.infra`, like
//! `empty_list` / `native_descriptors`) so parallel Runtimes don't share a
//! mutable `ref_cache` static. `printTypedInstance` keys off `print_tag`
//! (no rt, no surface import — zone-clean); `inst?`/`=` key off the
//! per-Runtime descriptor pointer.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const Runtime = @import("../runtime.zig").Runtime;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;

/// The per-Runtime canonical Date descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "Date"` so `(class …)`
/// prints the simple name (AD-003 / no-JVM); `print_tag = "inst"` drives
/// the `#inst "…"` print form.
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.date_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "Date",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .print_tag = "inst",
    };
    rt.date_descriptor = td;
    return td;
}

/// Build a Date value from epoch-millis (one typed_instance field; i48
/// inline holds ms to year ~6429).
pub fn make(rt: *Runtime, epoch_ms: i64) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{Value.initInteger(epoch_ms)});
}

/// True when `v` is a Date value (carries the per-Runtime Date descriptor).
pub fn isDate(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.date_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
}

/// The epoch-millis field. Caller must have checked `isDate`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.date_descriptor) |td| {
        rt.gc.infra.destroy(td);
        rt.date_descriptor = null;
    }
}

// --- tests ---

const testing = std.testing;

test "Date value: make / isDate / epochMsOf + print_tag set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const d = try make(&rt, 1_704_067_200_000);
    try testing.expect(d.tag() == .typed_instance);
    try testing.expect(isDate(&rt, d));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(d));
    try testing.expectEqualStrings("inst", d.decodePtr(*const TypedInstance).descriptor.print_tag.?);
    try testing.expect(!isDate(&rt, Value.initInteger(5)));
}
