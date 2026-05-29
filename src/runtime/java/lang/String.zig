// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.String` instance methods.
//!
//! Backend: impl-only
//! Impl deps: charset
//! Clojure peer: clojure.string/upper-case
//!
//! Thin wrapper over `runtime/charset.zig` per F-009. Unlike the
//! `___HOST_EXTENSION` static-descriptor surfaces (System / UUID / …),
//! String exposes **instance** methods reached as `(.toUpperCase s)`.
//! Instance dispatch on a native receiver resolves via
//! `rt.nativeDescriptor(.string)` — a per-Runtime descriptor distinct
//! from the static `rt.types` entries `installAll` registers — so these
//! methods are installed by `installNativeMethods(rt)` at runtime init
//! (ADR-0050 am1 caveat 3), not by the `___HOST_EXTENSION` aggregator.

const std = @import("std");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const charset = @import("../../charset.zig");
const string_collection = @import("../../collection/string.zig");

/// Implements `(.toUpperCase s)`.
/// Spec: returns a copy of the string with all codepoints upper-cased.
/// JVM reference: java.lang.String#toUpperCase.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn toUpperCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // args[0] is the receiver; a no-arg instance method takes exactly it.
    try error_catalog.checkArity(".toUpperCase", args, 1, loc);
    const up = try charset.upperCaseAlloc(rt.gpa, string_collection.asString(args[0]));
    defer rt.gpa.free(up);
    return string_collection.alloc(rt, up);
}

/// Implements `(.toLowerCase s)`.
/// Spec: returns a copy of the string with all codepoints lower-cased.
/// JVM reference: java.lang.String#toLowerCase.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn toLowerCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".toLowerCase", args, 1, loc);
    const down = try charset.lowerCaseAlloc(rt.gpa, string_collection.asString(args[0]));
    defer rt.gpa.free(down);
    return string_collection.alloc(rt, down);
}

/// Implements `(.trim s)`.
/// Spec: returns a copy with leading/trailing ASCII whitespace removed.
/// JVM reference: java.lang.String#trim.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn trim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".trim", args, 1, loc);
    return string_collection.alloc(rt, charset.trim(string_collection.asString(args[0])));
}

/// Populate the per-Runtime native `.string` descriptor's `method_table`
/// with String instance methods. Driven from `lang/primitive.zig` at
/// runtime init (Layer 2 — Layer 0 `runtime/` may not import this
/// surface per zone rules). Idempotent: a non-empty table short-circuits.
///
/// Allocations land on `rt.gc.infra` (the same allocator
/// `Runtime.deinit`'s native-descriptor pass frees), so the method-name
/// dups + the slice are released without a separate owner.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.string);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 3);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toUpperCase"), .method_val = Value.initBuiltinFn(&toUpperCase) };
    entries[1] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toLowerCase"), .method_val = Value.initBuiltinFn(&toLowerCase) };
    entries[2] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "trim"), .method_val = Value.initBuiltinFn(&trim) };
    td.method_table = entries;
}

// --- tests ---

const testing = std.testing;

test "installNativeMethods populates the native .string descriptor" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    try installNativeMethods(&rt);
    const td = try rt.nativeDescriptor(.string);
    try testing.expect(td.lookupMethod(null, "toUpperCase") != null);
    try testing.expect(td.lookupMethod(null, "toLowerCase") != null);
    try testing.expect(td.lookupMethod(null, "trim") != null);
    try testing.expect(td.lookupMethod(null, "noSuchMethod") == null);

    // Idempotent: a second call leaves the table length unchanged.
    const len_before = td.method_table.len;
    try installNativeMethods(&rt);
    try testing.expectEqual(len_before, td.method_table.len);
}
