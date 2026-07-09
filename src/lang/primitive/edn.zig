// SPDX-License-Identifier: EPL-2.0
//! `clojure.edn` Tier-A surface (§9.11 row 9.2).
//!
//! cw v1's reader already parses EDN syntax (Clojure IS EDN-shaped);
//! this module exposes `clojure.edn/read-string` as a thin Layer-2
//! primitive that runs `eval/reader.readOne` followed by
//! `analyzer.formToValue` (recursively lifted at row 9.2 to cover
//! vector / map / set literals).
//!
//! Both the 1-arity `(read-string s)` and the 2-arity
//! `(read-string opts s)` form (`:readers` / `:default` / `:eof`)
//! are implemented (D-200).
//!
//! **Location note (D-095)**: this Zig primitive lives under
//! `src/lang/primitive/` (mirroring `string.zig` / `walk.zig`); the
//! matching `.clj` source sits at `src/lang/clj/clojure/edn.clj`
//! (mirroring `clojure.string` / `clojure.set` precedent). The former
//! top-level `modules/` reservation for a co-located `modules/edn/`
//! layout was retired (D-095 — the migration was never warranted;
//! primitives stay in `src/lang/`).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const reader_mod = @import("../../eval/reader.zig");
const analyzer_mod = @import("../../eval/analyzer/analyzer.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const keyword = @import("../../runtime/keyword.zig");
const Var = env_mod.Var;

/// Implements clojure.edn/read-string.
/// Spec: `(read-string s)` reads one EDN form from `s` and returns it as
///   a Value; empty / whitespace-only / comment-only input THROWS EOF (clj
///   parity, D-269) unless an `:eof` opt supplies a sentinel. `(read-string opts s)`
///   honours an opts map: `:readers` (a `{tag-symbol reader-fn}` map bound
///   to `*data-readers*` for the read), `:default` (a `(fn [tag value])`
///   bound to `*default-data-reader-fn*`), `:eof` (value returned on empty
///   input instead of `nil`). The readers/default install via a
///   `BindingFrame` (ADR-0073) so the `formToValue` `.tagged` arm sees them.
/// JVM reference: clojure.edn/read-string (note: opts is the FIRST arg)
/// cw v1 tier: A (Phase 9 row 9.2 + Phase 14 D-200 cycle 2)
pub fn readStringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("read-string", args, 1, 2, loc);
    const opts: ?Value = if (args.len == 2) args[0] else null;
    const str_arg = args[args.len - 1];
    if (str_arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-string",
            .actual = @tagName(str_arg.tag()),
        });
    }
    const source = string_collection.asString(str_arg);

    // EOF (no form in `source`): clj THROWS `RuntimeException: EOF while
    // reading` UNLESS an `:eof` opt is supplied, in which case that value is
    // returned (D-269 — was a silent nil-default that masked "nothing to read").
    // `:eof` may be explicitly bound to nil, so detect KEY PRESENCE, not a
    // non-nil value.
    var eof_provided = false;
    var eof_val: Value = Value.nil_val;
    if (opts) |o| switch (o.tag()) {
        .array_map, .hash_map => {
            const k = try keyword.intern(rt, null, "eof");
            if (try map_collection.contains(o, k)) {
                eof_provided = true;
                eof_val = try map_collection.get(o, k);
            }
        },
        else => {},
    };

    // Install `:readers` / `:default` as a dynamic-binding frame for the
    // read so the data-reader dispatch in `formToValue` sees them.
    var frame: env_mod.BindingFrame = .{};
    defer frame.bindings.deinit(rt.gpa);
    if (opts) |o| {
        if (try optGet(rt, o, "readers")) |readers| {
            if (rt.data_readers_var) |p|
                try frame.bindings.put(rt.gpa, @as(*const Var, @ptrCast(@alignCast(p))), readers);
        }
        if (try optGet(rt, o, "default")) |default_fn| {
            if (rt.default_data_reader_fn_var) |p|
                try frame.bindings.put(rt.gpa, @as(*const Var, @ptrCast(@alignCast(p))), default_fn);
        }
    }
    env_mod.pushFrame(&frame);
    defer env_mod.popFrame();

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    // D-457(3): a data read rejects `#?` (clj: "Conditional read not allowed")
    // unless the caller opts in with `:read-cond :allow`. Source-loading
    // (require/load/eval) keeps allowing `#?` via the Reader's default; only this
    // DATA-read path flips it off.
    var allow_cond = false;
    if (opts) |o| {
        if (try optGet(rt, o, "read-cond")) |rc| {
            if (rc == try keyword.intern(rt, null, "allow")) allow_cond = true;
        }
    }
    var reader = reader_mod.Reader.init(arena.allocator(), source);
    reader.allow_reader_cond = allow_cond;
    const form_opt = reader.read() catch |e| {
        // A specific reader diagnostic (e.g. reader_cond_not_allowed) carries its
        // own catalog Info; re-raise it so the message survives rather than being
        // flattened to the generic EDN-reader-error wrapper.
        if (e == error.SyntaxError) return e;
        return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "EDN reader error in clojure.edn/read-string",
        });
    };
    const form = form_opt orelse {
        if (eof_provided) return eof_val;
        return error_catalog.raise(.eof_unexpected, loc, .{});
    };
    return try analyzer_mod.formToValue(rt, env, form);
}

/// Look up `:key` in an opts map, returning the bound value or null when
/// absent / nil. Returns null (no error) if `opts` is not a map, so a
/// non-map opts is simply treated as "no options".
fn optGet(rt: *Runtime, opts: Value, key: []const u8) !?Value {
    switch (opts.tag()) {
        .array_map, .hash_map => {},
        else => return null,
    }
    const k = try keyword.intern(rt, null, key);
    const v = try map_collection.get(opts, k);
    return if (v.tag() == .nil) null else v;
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "read-string", .f = &readStringFn },
};

/// Register `clojure.edn` primitives into the dedicated namespace.
/// Mirrors the row 6.9 pattern from `lang/primitive/string.zig`:
/// creates `clojure.edn` ns if missing + interns each Var. The
/// `(ns clojure.edn ...)` head in `src/lang/clj/clojure/edn.clj`
/// finds an already-populated ns when bootstrap evaluates it.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.edn");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
