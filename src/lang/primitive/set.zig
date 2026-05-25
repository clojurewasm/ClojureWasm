// SPDX-License-Identifier: EPL-2.0
//! `clojure.set/` namespace surface — Phase 6.16.b-1 (.clj migration).
//!
//! The Group A + B vars (`union` / `intersection` / `difference` /
//! `subset?` / `superset?` / `rename-keys` / `map-invert`) moved to
//! pure-Clojure Pattern A defns in `src/lang/clj/clojure/set.clj`
//! per ADR-0033 D3 + v5 §8.2. This file now ships only:
//!
//! - `hash-set` (variadic constructor; the `#{...}` reader literal
//!   lowers to a `hash-set` call until D-061 lands a `.set` Form
//!   variant + analyzer node at 6.16.b-2).
//! - `hash-map` (variadic constructor; same role for `{...}` until
//!   D-059 lands map-literal-as-Value at 6.16.b-2).
//!
//! Group C (`select` / `project` / `index` / `rename` / `join`) is
//! also a `.clj` defn — lands at 6.16.b-3 after the D-061 + D-059
//! infra ships.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const map_collection = @import("../../runtime/collection/map.zig");

/// `(hash-set & xs)` — construct a set from variadic args. Empty
/// arg list returns the empty-set singleton. Each arg is conj-ed
/// in order (idempotent — duplicates collapse).
pub fn hashSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    var s = set_collection.empty();
    for (args) |a| s = try set_collection.conj(rt, s, a);
    return s;
}

/// `(hash-map & kvs)` — construct a map from variadic key/value pairs.
/// Odd argument count raises `map_literal_arity_odd` (matches the
/// JVM `IllegalArgumentException`). Empty arg list returns the
/// empty-map singleton.
pub fn hashMap(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len % 2 != 0)
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    var m = map_collection.empty();
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        m = try map_collection.assoc(rt, m, args[i], args[i + 1]);
    }
    return m;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const RT_ENTRIES = [_]Entry{
    .{ .name = "hash-set", .f = &hashSet },
    .{ .name = "hash-map", .f = &hashMap },
};

/// Register `hash-set` / `hash-map` into `rt/` (so they are user-
/// callable unqualified after `(refer 'rt)` into `user/`) and ensure
/// the `clojure.set` namespace exists for the .clj loader to enter.
/// The Group A + B vars themselves are registered by evaluating
/// `src/lang/clj/clojure/set.clj` at bootstrap.
pub fn register(env: *Env) !void {
    const rt_ns = env.findNs("rt") orelse return error.RtNamespaceMissing;
    for (RT_ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
    _ = try env.findOrCreateNs("clojure.set");
}
