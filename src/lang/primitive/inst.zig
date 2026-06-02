//! `#inst` / java.util.Date primitives for the `rt/` namespace (D-200 /
//! clj-parity C6, ADR-0079). `inst?` / `inst-ms` + the `#inst "…"` data
//! reader. All wrap the namespace-neutral `runtime/time/date.zig` (Date
//! value) + `runtime/time/instant.zig` (parse/format) per F-009.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const date = @import("../../runtime/time/date.zig");
const instant = @import("../../runtime/time/instant.zig");

/// The default `#inst "…"` data reader (ADR-0079). Parses the RFC3339-subset
/// string → a `java.util.Date` value (epoch-ms, UTC). A malformed string
/// raises (clj's `#inst` throws on bad input).
pub fn instReader(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("#inst", args, 1, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "#inst", .actual = @tagName(args[0].tag()) });
    }
    const s = string_collection.asString(args[0]);
    const epoch_ms = instant.parseInstantMillis(s) catch
        return error_catalog.raise(.inst_string_invalid, loc, .{ .s = s });
    return try date.make(rt, epoch_ms);
}

/// `(inst? x)` — true iff `x` is an instant (cljw: a java.util.Date value).
pub fn instQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("inst?", args, 1, loc);
    return if (date.isDate(rt, args[0])) Value.true_val else Value.false_val;
}

/// `(inst-ms inst)` — the instant as epoch-millis. Errors on a non-Date.
pub fn instMs(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("inst-ms", args, 1, loc);
    if (!date.isDate(rt, args[0])) {
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "inst-ms", .expected = "inst", .actual = @tagName(args[0].tag()) });
    }
    return Value.initInteger(date.epochMsOf(args[0]));
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "inst?", .f = &instQ },
    .{ .name = "inst-ms", .f = &instMs },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
