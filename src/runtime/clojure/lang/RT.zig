// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.RT` static methods (ADR-0108 tree).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/gensym (shares the id counter)
//!
//! Pure-Clojure libraries drop to `clojure.lang.RT` for a handful of runtime
//! statics. `core.logic` mints logic-variable ids with `(. clojure.lang.RT
//! (nextID))`. Only the members listed here are modelled; any other
//! `clojure.lang.RT/x` keeps the AD-008 deferred rewrite (it loads, and errors
//! only when evaluated). Registered as `cljw.clojure.lang.RT`, so
//! `resolveJavaSurface("clojure.lang.RT")` hits via the `cljw.<fqcn>` path.

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");

/// `(clojure.lang.RT/nextID)` — the next id from the runtime's monotonic id
/// counter. JVM RT.nextID backs `gensym`; here it advances the same
/// per-Runtime `gensym_counter`, so ids and `(gensym)` suffixes never repeat
/// against each other.
fn nextID(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("clojure.lang.RT/nextID", args, 0, loc);
    const n = rt.gensym_counter;
    rt.gensym_counter += 1;
    return Value.initInteger(@as(i64, @intCast(n)));
}

fn initRT(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "nextID", &nextID },
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

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.clojure.lang.RT",
    .descriptor = &descriptor,
    .init = &initRT,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.RT",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
