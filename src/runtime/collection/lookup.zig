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
const sorted = @import("sorted.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const tagged_literal_mod = @import("../tagged_literal.zig");
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const td_mod = @import("../type_descriptor.zig");
const dispatch = @import("../dispatch.zig");
const keyword_mod = @import("../keyword.zig");

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
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
    }
    if (idx >= vector.count(v)) {
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
    }
    return vector.nth(v, @intCast(idx));
}

/// Declared-field read for a `defrecord` TypedInstance (pure): walks
/// `descriptor.field_layout`, returns the matching field value or null
/// when the key is not a declared field. deftype instances return null
/// (no implicit map surface).
fn recordFieldGet(rec: Value, k: Value) ?Value {
    const inst = rec.decodePtr(*const td_mod.TypedInstance);
    if (inst.descriptor.kind != .defrecord) return null;
    if (k.tag() != .keyword) return null;
    const layout = inst.descriptor.field_layout orelse return null;
    const key_name = keyword_mod.asKeyword(k).name;
    for (layout) |fe| {
        if (std.mem.eql(u8, fe.name, key_name)) return inst.fields()[fe.index];
    }
    return null;
}

/// `(get rec k default)` for a TypedInstance receiver: declared field
/// first, then the ILookup `-lookup` slow-path (extend-type), then
/// `default`. The single source for record associative read — both the
/// `get` primitive (collection.zig) and the keyword-as-fn `(:k rec)` path
/// below call it, so `(:k rec)` ≡ `(get rec :k)` by construction.
/// `has_default` mirrors clj's RT.get arity split: a 3-arity get consults
/// the 3-arity `valAt(k, nf)` impl (a deftype like data.priority-map
/// returns its not-found THERE, not via a nil from the 2-arity), falling
/// back to the 2-arity impl when the type declared only that.
pub fn recordGet(rt: *Runtime, env: *Env, rec: Value, k: Value, has_default: bool, default: Value, loc: SourceLocation) !Value {
    if (recordFieldGet(rec, k)) |v| return v;
    // D-086 / ADR-0154: a non-declared key may live in the extmap (consulted
    // after the declared-field miss, before the ILookup slow-path).
    const ext = rec.decodePtr(*const td_mod.TypedInstance).extmap;
    if (!ext.isNil() and try map.contains(ext, k)) return map.get(ext, k);
    return lookupDispatch(rt, env, rec, k, has_default, default, loc);
}

/// `(get x k [default])` via the ILookup `-lookup` slow-path, for ANY value
/// carrying an `-lookup` extension that has no declared field layout — a reify
/// instance (`.reified_instance`) or an extend-type'd native. Shared by
/// `recordGet` (after its field read) and `getFn`'s catch-all arm so the
/// 3-arity default semantic is identical everywhere: a 3-arity `(get x k d)`
/// consults the 3-arity `-lookup` first, then falls back to the 2-arity impl
/// applying `default` on a nil result (a 2-arity `valAt` cannot express
/// absent-vs-present-nil). Before this was extracted, `getFn`'s catch-all arm
/// did a 2-arity-only consult and returned the raw nil, ignoring `default`.
pub fn lookupDispatch(rt: *Runtime, env: *Env, coll: Value, k: Value, has_default: bool, default: Value, loc: SourceLocation) !Value {
    var cs: dispatch.CallSite = .{};
    if (has_default) {
        const slow3 = [_]Value{ coll, k, default };
        if (dispatch.dispatchOrNull(rt, env, &cs, coll, "ILookup", "-lookup", &slow3, loc)) |maybe| {
            if (maybe) |v| return v;
        } else |_| {
            // 3-arity call failed (the type declared only the 2-arity valAt)
            // — fall through to the 2-arity consult below.
        }
    }
    var cs2: dispatch.CallSite = .{};
    const slow_args = [_]Value{ coll, k };
    if (try dispatch.dispatchOrNull(rt, env, &cs2, coll, "ILookup", "-lookup", &slow_args, loc)) |v| {
        if (has_default and v.isNil()) return default;
        return v;
    }
    return default;
}

/// Invoke a data-structure / keyword `callee` with `args` (the call's
/// arguments, callee excluded). The caller (`treeWalkCall`) guarantees
/// `callee.tag()` is one of keyword/symbol/array_map/hash_map/hash_set/
/// vector.
pub fn invoke(rt: *Runtime, env: *Env, callee: Value, args: []const Value, loc: SourceLocation) !Value {
    switch (callee.tag()) {
        .keyword, .symbol => {
            // callee is the KEY; args[0] is the collection.
            if (args.len < 1 or args.len > 2) return arityError("keyword/symbol", args.len, 1, 2, loc);
            const default = if (args.len == 2) args[1] else Value.nil_val;
            // A defrecord receiver routes through the record get (declared
            // field → ILookup → default), same as the `get` primitive, so
            // `(:k rec)` ≡ `(get rec :k)`. map.get cannot see record fields.
            if (args[0].tag() == .typed_instance)
                return recordGet(rt, env, args[0], callee, args.len == 2, default, loc);
            // `(:tag t)` / `(:form t)` on a TaggedLiteral ≡ `(get t :tag)`.
            if (args[0].tag() == .tagged_literal)
                return tagged_literal_mod.valAt(args[0], callee, default);
            // A host_instance with an ILookup `-lookup` (java.util.HashMap/TreeMap)
            // routes through the dispatch so `(:k hm)` ≡ `(get hm :k)` — lookupWithDefault
            // is a native-map fast-path with no rt/env, so it cannot dispatch -lookup.
            if (args[0].tag() == .host_instance)
                return lookupDispatch(rt, env, args[0], callee, args.len == 2, default, loc);
            return lookupWithDefault(args[0], callee, args.len == 2, default);
        },
        .array_map, .hash_map => {
            // callee is the MAP; args[0] is the key.
            if (args.len < 1 or args.len > 2) return arityError("map", args.len, 1, 2, loc);
            return lookupWithDefault(callee, args[0], args.len == 2, if (args.len == 2) args[1] else Value.nil_val);
        },
        .sorted_map => {
            // callee is the sorted MAP; args[0] is the key. Needs rt+env (the
            // comparator may be a user fn invoked via vtable.callFn).
            if (args.len < 1 or args.len > 2) return arityError("sorted-map", args.len, 1, 2, loc);
            if (try sorted.contains(rt, env, callee, args[0], loc)) return try sorted.get(rt, env, callee, args[0], loc);
            return if (args.len == 2) args[1] else Value.nil_val;
        },
        .hash_set => {
            if (args.len != 1) return arityError("set", args.len, 1, 1, loc);
            return if (try set.contains(callee, args[0])) args[0] else Value.nil_val;
        },
        .sorted_set => {
            if (args.len != 1) return arityError("sorted-set", args.len, 1, 1, loc);
            return if (try sorted.setContains(rt, env, callee, args[0], loc)) args[0] else Value.nil_val;
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
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const kw = try keyword_mod.intern(&fix.rt, null, "k");
    const m = try map.assoc(&fix.rt, map.empty(), kw, Value.initInteger(42));
    try std_testing.expectEqual(@as(i48, 42), (try invoke(&fix.rt, &env,kw, &.{m}, noloc)).asInteger());

    const missing = try keyword_mod.intern(&fix.rt, null, "absent");
    try std_testing.expect((try invoke(&fix.rt, &env,missing, &.{m}, noloc)).isNil());
    try std_testing.expectEqual(@as(i48, 7), (try invoke(&fix.rt, &env,missing, &.{ m, Value.initInteger(7) }, noloc)).asInteger());
    // keyword on a non-map yields default / nil
    try std_testing.expect((try invoke(&fix.rt, &env,kw, &.{Value.initInteger(5)}, noloc)).isNil());
}

test "map-as-fn: (m k) gets; vector-as-fn: ([..] i) nth; OOB throws" {
    var fix = Fixture.init();
    defer fix.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const kw = try keyword_mod.intern(&fix.rt, null, "a");
    const m = try map.assoc(&fix.rt, map.empty(), kw, Value.initInteger(9));
    try std_testing.expectEqual(@as(i48, 9), (try invoke(&fix.rt, &env,m, &.{kw}, noloc)).asInteger());

    var vec = vector.empty();
    vec = try vector.conj(&fix.rt, vec, Value.initInteger(10));
    vec = try vector.conj(&fix.rt, vec, Value.initInteger(20));
    try std_testing.expectEqual(@as(i48, 20), (try invoke(&fix.rt, &env,vec, &.{Value.initInteger(1)}, noloc)).asInteger());
    // ADR-0060: nth index errors are index_error Kind → error.IndexError
    // (→ IndexOutOfBoundsException), not type_error.
    try std_testing.expectError(error.IndexError, invoke(&fix.rt, &env,vec, &.{Value.initInteger(5)}, noloc)); // OOB
    try std_testing.expectError(error.IndexError, invoke(&fix.rt, &env,vec, &.{Value.initInteger(-1)}, noloc)); // negative
}

test "set-as-fn: (#{..} x) returns x or nil; arity errors" {
    var fix = Fixture.init();
    defer fix.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    var s = set.empty();
    s = try set.conj(&fix.rt, s, Value.initInteger(3));
    try std_testing.expectEqual(@as(i48, 3), (try invoke(&fix.rt, &env,s, &.{Value.initInteger(3)}, noloc)).asInteger());
    try std_testing.expect((try invoke(&fix.rt, &env,s, &.{Value.initInteger(99)}, noloc)).isNil());
    // set is 1-arg only
    try std_testing.expectError(error.ArityError, invoke(&fix.rt, &env,s, &.{ Value.initInteger(3), Value.initInteger(4) }, noloc));
}
