//! UUID primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! `random-uuid` and `parse-uuid` from clojure.core. Both wrap
//! `runtime/uuid.zig` per F-009 (the same impl is shared with the
//! Java surface in `runtime/java/util/UUID.zig`).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const uuid = @import("../../runtime/uuid.zig");
const string_collection = @import("../../runtime/collection/string.zig");

/// `(random-uuid)` — generate a UUID v4 and return it as a `.uuid` value
/// (ADR-0074; was a 36-char String pre-cycle-3). Matches clj's
/// `clojure.core/random-uuid` returning a UUID instance.
pub fn randomUuid(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("random-uuid", args, 0, loc);
    return try uuid.alloc(rt, uuid.generateV4(rt.io));
}

/// `(parse-uuid s)` — parse a canonical UUID string; returns a `.uuid`
/// value on success, `nil` on parse failure (matches clojure.core/parse-uuid:
/// nil for invalid input, never throws).
pub fn parseUuid(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("parse-uuid", args, 1, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "parse-uuid", .actual = @tagName(args[0].tag()) });
    }
    const bytes = uuid.parse(string_collection.asString(args[0])) catch return .nil_val;
    return try uuid.alloc(rt, bytes);
}

/// `(uuid? x)` — true iff `x` is a `.uuid` value (= `(instance? java.util.UUID x)`).
pub fn uuidQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("uuid?", args, 1, loc);
    return if (args[0].tag() == .uuid) Value.true_val else Value.false_val;
}

/// The default `#uuid "…"` data reader (ADR-0073/0074). Installed into the
/// ROOT `*data-readers*` table so `#uuid` works without a `binding`. Parses
/// the canonical string → `.uuid` value; a malformed string raises (clj's
/// `#uuid` throws on bad input, unlike `parse-uuid`'s nil).
pub fn uuidReader(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("#uuid", args, 1, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "#uuid", .actual = @tagName(args[0].tag()) });
    }
    const s = string_collection.asString(args[0]);
    const bytes = uuid.parse(s) catch
        return error_catalog.raise(.uuid_string_invalid, loc, .{ .s = s });
    return try uuid.alloc(rt, bytes);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "random-uuid", .f = &randomUuid },
    .{ .name = "parse-uuid", .f = &parseUuid },
    .{ .name = "uuid?", .f = &uuidQ },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
