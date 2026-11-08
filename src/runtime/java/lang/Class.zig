// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Class` — the instance-method side of the host
//! class object that `(class x)` returns (a boxed TypeDescriptor, ADR-0059).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/class (the VALUE producer; this is its method surface)
//!
//! `(class x)` resolves to a `.type_descriptor` Value (the STATIC class-value
//! side, D-293). This file adds the INSTANCE methods reached as
//! `(.isArray klass)` / `(.getName klass)` / `(.getSimpleName klass)` /
//! `(.isInstance klass obj)` by populating the per-Runtime `.type_descriptor`
//! native descriptor's method_table (same mechanism as
//! `String.installNativeMethods`). Surfaced by clojure.core.unify, whose
//! `composite?` calls `(-> x class .isArray)` (D-311).
//!
//! cljw uses simple class names (AD-003), so `getName` returns the descriptor's
//! fqcn unchanged (already simple for native tags). Array detection is a pointer
//! identity test against the `.array` native descriptor (the Java-array tag,
//! ADR-0105 / D-287).

const std = @import("std");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const string_collection = @import("../../collection/string.zig");
const class_name = @import("../../class_name.zig");

/// `(.isArray klass)` — true iff `klass` is a Java-array class. cljw's array
/// tag (ADR-0105) has a single per-Runtime descriptor, so this is a pointer
/// identity test. JVM reference: java.lang.Class#isArray. cw v1 tier: A.
fn isArray(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".isArray", args, 1, loc);
    const td = type_descriptor.asTypeDescriptorRef(args[0]);
    const array_td = try rt.nativeDescriptor(.array);
    return Value.initBoolean(td == array_td);
}

/// `(.getName klass)` — the class name. cljw uses simple names (AD-003), so the
/// descriptor's fqcn is returned unchanged. JVM reference: java.lang.Class#getName.
fn getName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".getName", args, 1, loc);
    const td = type_descriptor.asTypeDescriptorRef(args[0]);
    return string_collection.alloc(rt, td.fqcn orelse "Object");
}

/// `(.getSimpleName klass)` — the unqualified class name (normalizes a
/// fully-qualified fqcn like `clojure.lang.PersistentVector` to its tail).
/// JVM reference: java.lang.Class#getSimpleName.
fn getSimpleName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".getSimpleName", args, 1, loc);
    const td = type_descriptor.asTypeDescriptorRef(args[0]);
    return string_collection.alloc(rt, class_name.normalizeClassName(td.fqcn orelse "Object"));
}

/// `(.isInstance klass obj)` — true iff `obj` is an instance of `klass`. Routes
/// through the same `class_name.isInstanceOfClass` entry `instance?` uses
/// (native tags + interface sets + Throwable hierarchy by name, descriptor
/// identity for a user class per ADR-0201). JVM reference:
/// java.lang.Class#isInstance.
fn isInstance(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isInstance", args, 2, loc);
    const td = type_descriptor.asTypeDescriptorRef(args[0]);
    return Value.initBoolean(class_name.isInstanceOfClass(args[1], td));
}

/// Populate the per-Runtime `.type_descriptor` native descriptor's method table
/// with the java.lang.Class instance accessors. Idempotent. Called at runtime
/// init alongside `String`/`Throwable.installNativeMethods` (lang/primitive.zig).
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.type_descriptor);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "isArray", &isArray },
        .{ "getName", &getName },
        .{ "getSimpleName", &getSimpleName },
        .{ "isInstance", &isInstance },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

// --- tests ---

const testing = std.testing;

test "installNativeMethods populates the .type_descriptor descriptor" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    try installNativeMethods(&rt);
    const td = try rt.nativeDescriptor(.type_descriptor);
    try testing.expect(td.lookupMethod(null, "isArray") != null);
    try testing.expect(td.lookupMethod(null, "getName") != null);
    try testing.expect(td.lookupMethod(null, "getSimpleName") != null);
    try testing.expect(td.lookupMethod(null, "isInstance") != null);
    try testing.expect(td.lookupMethod(null, "noSuchMethod") == null);

    const len_before = td.method_table.len;
    try installNativeMethods(&rt);
    try testing.expectEqual(len_before, td.method_table.len);
}
