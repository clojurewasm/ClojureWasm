// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Throwable` instance methods on cljw
//! exception values.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/ex-message, clojure.core/ex-data, clojure.core/ex-cause
//!
//! D-198 targeted discharge: cljw represents a thrown/`ex-info` exception
//! as an `.ex_info` Value (message + data + cause fields). Real Clojure
//! catch bodies very commonly call `(.getMessage e)` / `(.getCause e)` /
//! `(.getData e)` on the caught exception. These are wired here as native
//! instance methods on the per-Runtime `.ex_info` descriptor (the same
//! mechanism `String.installNativeMethods` uses), so BOTH backends resolve
//! them through the shared `receiverDescriptor` → `method_table` path — no
//! per-backend special-case. The cljw-native `ex-message`/`ex-data`/
//! `ex-cause` fns read the same fields; this is the Java-interop surface.
//!
//! Distinct from the full host-class ctor/dispatch machinery (D-048): this
//! only covers the read accessors on an existing `.ex_info` receiver, which
//! is the high-frequency catch-body pattern. `(Exception. msg)` ctor +
//! arbitrary Throwable subclasses remain D-048 / D-198 follow-ups.

const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const ex_info = @import("../../collection/ex_info.zig");
const string_collection = @import("../../collection/string.zig");

/// `(.getMessage e)` — the exception's message string. clj: returns the
/// `Throwable.getMessage()` (the ex-info message). Receiver is guaranteed
/// `.ex_info` (the descriptor this method is installed on).
fn getMessage(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".getMessage", args, 1, loc);
    return try string_collection.alloc(rt, ex_info.message(args[0]));
}

/// `(.getCause e)` — the wrapped cause Value, or nil when none.
fn getCause(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getCause", args, 1, loc);
    return ex_info.cause(args[0]);
}

/// `(.getData e)` — the ex-info data map (clojure.lang.ExceptionInfo's
/// `getData`). nil when the exception carries no data.
fn getData(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getData", args, 1, loc);
    return ex_info.data(args[0]);
}

/// Populate the per-Runtime `.ex_info` native descriptor's method table
/// with the Throwable read accessors. Idempotent. Called at runtime init
/// alongside `String.installNativeMethods` (`lang/primitive.zig`).
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.ex_info);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "getMessage", &getMessage },
        .{ "getCause", &getCause },
        .{ "getData", &getData },
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
