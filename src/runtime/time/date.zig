// SPDX-License-Identifier: EPL-2.0
//! `java.util.Date` VALUE (D-200 / clj-parity C6, ADR-0079).
//!
//! A `#inst "…"` literal / `java.util.Date` is a no-slot cljw-native value
//! (user β: F-004 layout UNCHANGED) — a `.typed_instance` carrying ONE
//! epoch-millis field + the ONE canonical `rt.types["java.util.Date"]`
//! descriptor (ADR-0174: shared with the `java/util/Date.zig` static
//! surface, so `(= java.util.Date (class d))` is identity and the AOT
//! wire round-trips). `print_tag = "inst"` makes the printer emit
//! `#inst "<ISO>"`. The epoch-ms parse/format lives in the sibling
//! `instant.zig` (F-009 neutral home); both the Clojure `#inst`/`inst?`
//! surface and the Java `java.util.Date` surface wrap this from above.
//!
//! `printTypedInstance` keys off `print_tag` (no rt, no surface import —
//! zone-clean); `inst?` keys off the descriptor's fqcn.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const instant_value = @import("instant_value.zig");

/// `(.getTime date)` — the epoch-millis the Date wraps (JVM `Date.getTime`).
/// Registered on the per-Runtime Date descriptor, so dispatch only reaches it
/// with a Date receiver. `(inst-ms d)` reads the same field via the clj surface.
fn getTimeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getTime", args, 1, loc);
    return Value.initInteger(epochMsOf(args[0]));
}
const TypedInstance = td_mod.TypedInstance;

/// `(.before a b)` / `(.after a b)` — epoch-millis comparison of two Dates
/// (JVM `Date.before` / `Date.after`). Sibling of `.getTime`; ships with it
/// (F-014 per-class completeness, D-431).
fn beforeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("before", args, 2, loc);
    if (!isDate(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".before", .expected = "Date", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochMsOf(args[0]) < epochMsOf(args[1]));
}
fn afterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("after", args, 2, loc);
    if (!isDate(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".after", .expected = "Date", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochMsOf(args[0]) > epochMsOf(args[1]));
}

/// `(.toInstant date)` — the equivalent `java.time.Instant` (JVM `Date.toInstant`).
/// Same epoch-ms → second + sub-second-nanos split as `Instant/ofEpochMilli`.
fn toInstantFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".toInstant", args, 1, loc);
    const ms = epochMsOf(args[0]);
    const secs = @divFloor(ms, 1000);
    const nanos: i32 = @intCast(@rem(@rem(ms, 1000) + 1000, 1000) * 1_000_000);
    return instant_value.make(rt, secs * 1000, nanos);
}

/// The JVM-visible class name — also the `rt.types` registry key
/// (ADR-0174 D1: Java-surface-backed classes carry their JVM FQCN).
pub const FQCN = "java.util.Date";

/// Append the Date instance methods onto `td` (idempotent — guarded on the
/// `getTime` sentinel). Called by BOTH creation orders: the surface's
/// `init` callback (production, registerExtension-first) and
/// `configureDescriptor` (bare-Runtime unit tests, impl-first).
pub fn ensureInstanceMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.lookupMethod(null, "getTime") != null) return;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getTime", &getTimeFn },
        .{ "before", &beforeFn },
        .{ "after", &afterFn },
        .{ "toInstant", &toInstantFn },
    });
}

fn configureDescriptor(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.print_tag = "inst"; // drives the `#inst "…"` print form
    try ensureInstanceMethods(td, gpa);
}

/// The ONE canonical Date descriptor: `rt.types["java.util.Date"]`
/// (ADR-0174 D2 merge — the static surface and the instance values share
/// it, so class-symbol resolution, `=`, `instance?`, and the AOT wire all
/// agree). Registered by the surface at startup; minted here only on a
/// bare Runtime (unit tests).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FQCN, &configureDescriptor);
}

/// Build a Date value from epoch-millis (one typed_instance field; i48
/// inline holds ms to year ~6429).
pub fn make(rt: *Runtime, epoch_ms: i64) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{Value.initInteger(epoch_ms)});
}

/// True when `v` is a Date value (carries the canonical Date descriptor,
/// recognised by fqcn — rt-free so equal/print/prim guards stay cheap).
pub fn isDate(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// The epoch-millis field. Caller must have checked `isDate`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
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
    try testing.expect(isDate(d));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(d));
    try testing.expectEqualStrings("inst", d.decodePtr(*const TypedInstance).descriptor.print_tag.?);
    try testing.expect(!isDate(Value.initInteger(5)));
}
