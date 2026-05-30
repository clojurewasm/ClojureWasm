// SPDX-License-Identifier: EPL-2.0
//! Data-structure / keyword as IFn (D-085): keyword·symbol·map·set·vector
//! invoked as functions. The single call-dispatch chokepoint
//! `tree_walk.treeWalkCall` routes these tags here; since the VM's
//! `op_call`, `apply`, and every higher-order primitive funnel through
//! the same `rt.vtable.callFn`, wiring it here makes direct calls AND
//! `(map :k coll)` / `(filter :flag coll)` work across both backends.
//!
//! Semantics (Clojure clojure.lang IFn for data structures):
//!   (:k m)  / (:k m default)   keyword → (get m :k [default])
//!   ('s m)  / ('s m default)   symbol  → (get m 's [default])
//!   (m k)   / (m k default)    map     → (get m k  [default])
//!   (#{…} x)                   set     → x when present else nil  (1-arg)
//!   ([…] i)                    vector  → (nth v i), throws on OOB  (1-arg)
//!
//! Layer 0 by design: `tree_walk` (Layer 1) must not import `lang/`
//! (where `getFn`/`nthFn` live), so the lookup logic is re-derived here
//! over the Layer-0 accessors (`map.get` / `set.contains` / `vector.nth`).

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const map = @import("map.zig");
const set = @import("set.zig");
const vector = @import("vector.zig");
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;

/// Look up `k` in `m` honouring an optional `default`. With no default,
/// `map.get` already yields nil for an absent key; with a default we must
/// distinguish "absent" from "present → nil" via `contains`. A non-map
/// `m` (e.g. `(:k 5)`) yields the default — `contains`/`get` return
/// false/nil for it.
fn lookupWithDefault(m: Value, k: Value, has_default: bool, default: Value) !Value {
    if (!has_default) return try map.get(m, k);
    if (try map.contains(m, k)) return try map.get(m, k);
    return default;
}

fn arityError(name: []const u8, got: usize, min: usize, max: usize, loc: SourceLocation) error_catalog.ClojureWasmError {
    return error_catalog.raise(.arity_out_of_range, loc, .{
        .fn_name = name,
        .got = got,
        .min = min,
        .max = max,
    });
}

/// Vector index access — `nth` semantics (throws on out-of-range, unlike
/// `get`). Mirrors `collection.nthFn`'s vector arm so the error surface
/// is identical to `(nth v i)`.
fn vectorIndex(v: Value, i_val: Value, loc: SourceLocation) !Value {
    if (i_val.tag() != .integer) {
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "nth", .actual = @tagName(i_val.tag()) });
    }
    const idx = i_val.asInteger();
    if (idx < 0) {
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "nth", .expected = "non-negative integer index", .actual = "negative" });
    }
    if (idx >= vector.count(v)) {
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "nth", .expected = "index in bounds", .actual = "out of range" });
    }
    return vector.nth(v, @intCast(idx));
}

/// Invoke a data-structure / keyword `callee` with `args` (the call's
/// arguments, callee excluded). The caller (`treeWalkCall`) guarantees
/// `callee.tag()` is one of keyword/symbol/array_map/hash_map/hash_set/
/// vector.
pub fn invoke(callee: Value, args: []const Value, loc: SourceLocation) !Value {
    switch (callee.tag()) {
        .keyword, .symbol => {
            // callee is the KEY; args[0] is the collection.
            if (args.len < 1 or args.len > 2) return arityError("keyword/symbol", args.len, 1, 2, loc);
            return lookupWithDefault(args[0], callee, args.len == 2, if (args.len == 2) args[1] else Value.nil_val);
        },
        .array_map, .hash_map => {
            // callee is the MAP; args[0] is the key.
            if (args.len < 1 or args.len > 2) return arityError("map", args.len, 1, 2, loc);
            return lookupWithDefault(callee, args[0], args.len == 2, if (args.len == 2) args[1] else Value.nil_val);
        },
        .hash_set => {
            if (args.len != 1) return arityError("set", args.len, 1, 1, loc);
            return if (try set.contains(callee, args[0])) args[0] else Value.nil_val;
        },
        .vector => {
            if (args.len != 1) return arityError("vector", args.len, 1, 1, loc);
            return vectorIndex(callee, args[0], loc);
        },
        else => unreachable, // treeWalkCall routes only the tags above here
    }
}

// --- tests ---

const std_testing = std.testing;
const Runtime = @import("../runtime.zig").Runtime;
const keyword_mod = @import("../keyword.zig");

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    fn init() Fixture {
        var fix: Fixture = .{ .threaded = std.Io.Threaded.init(std_testing.allocator, .{}), .rt = undefined };
        fix.rt = Runtime.init(fix.threaded.io(), std_testing.allocator);
        return fix;
    }
    fn deinit(self: *Fixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

const noloc: SourceLocation = .{};

test "keyword-as-fn: (:k m) gets, (:k m default) falls back, (:k non-map) nil" {
    var fix = Fixture.init();
    defer fix.deinit();

    const kw = try keyword_mod.intern(&fix.rt, null, "k");
    const m = try map.assoc(&fix.rt, map.empty(), kw, Value.initInteger(42));
    try std_testing.expectEqual(@as(i48, 42), (try invoke(kw, &.{m}, noloc)).asInteger());

    const missing = try keyword_mod.intern(&fix.rt, null, "absent");
    try std_testing.expect((try invoke(missing, &.{m}, noloc)).isNil());
    try std_testing.expectEqual(@as(i48, 7), (try invoke(missing, &.{ m, Value.initInteger(7) }, noloc)).asInteger());
    // keyword on a non-map yields default / nil
    try std_testing.expect((try invoke(kw, &.{Value.initInteger(5)}, noloc)).isNil());
}

test "map-as-fn: (m k) gets; vector-as-fn: ([..] i) nth; OOB throws" {
    var fix = Fixture.init();
    defer fix.deinit();

    const kw = try keyword_mod.intern(&fix.rt, null, "a");
    const m = try map.assoc(&fix.rt, map.empty(), kw, Value.initInteger(9));
    try std_testing.expectEqual(@as(i48, 9), (try invoke(m, &.{kw}, noloc)).asInteger());

    var vec = vector.empty();
    vec = try vector.conj(&fix.rt, vec, Value.initInteger(10));
    vec = try vector.conj(&fix.rt, vec, Value.initInteger(20));
    try std_testing.expectEqual(@as(i48, 20), (try invoke(vec, &.{Value.initInteger(1)}, noloc)).asInteger());
    try std_testing.expectError(error.TypeError, invoke(vec, &.{Value.initInteger(5)}, noloc)); // OOB
    try std_testing.expectError(error.TypeError, invoke(vec, &.{Value.initInteger(-1)}, noloc)); // negative
}

test "set-as-fn: (#{..} x) returns x or nil; arity errors" {
    var fix = Fixture.init();
    defer fix.deinit();

    var s = set.empty();
    s = try set.conj(&fix.rt, s, Value.initInteger(3));
    try std_testing.expectEqual(@as(i48, 3), (try invoke(s, &.{Value.initInteger(3)}, noloc)).asInteger());
    try std_testing.expect((try invoke(s, &.{Value.initInteger(99)}, noloc)).isNil());
    // set is 1-arg only
    try std_testing.expectError(error.ArityError, invoke(s, &.{ Value.initInteger(3), Value.initInteger(4) }, noloc));
}
