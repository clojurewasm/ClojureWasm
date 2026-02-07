// Multimethod operation builtins — methods, get-method, remove-method,
// remove-all-methods, prefers, prefer-method.
//
// These operate on MultiFn values created by defmulti/defmethod.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const MultiFn = value_mod.MultiFn;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");
const Env = @import("../env.zig").Env;

/// (methods multifn) => map of dispatch-val -> method-fn
pub fn methodsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to methods", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "methods expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };
    return Value.initMap(mf.methods);
}

/// (get-method multifn dispatch-val) => method-fn or nil
pub fn getMethodFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to get-method", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "get-method expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };
    return mf.methods.get(args[1]) orelse Value.nil_val;
}

/// (remove-method multifn dispatch-val) => multifn
/// Removes the method associated with dispatch-val.
pub fn removeMethodFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to remove-method", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "remove-method expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };
    const old_entries = mf.methods.entries;
    const dispatch_val = args[1];

    // Count entries to keep (skip matching key-value pair)
    var keep_count: usize = 0;
    var i: usize = 0;
    while (i < old_entries.len) : (i += 2) {
        if (!old_entries[i].eql(dispatch_val)) {
            keep_count += 2;
        }
    }

    if (keep_count == old_entries.len) {
        // Key not found — no change
        return args[0];
    }

    const new_entries = try allocator.alloc(Value, keep_count);
    var j: usize = 0;
    i = 0;
    while (i < old_entries.len) : (i += 2) {
        if (!old_entries[i].eql(dispatch_val)) {
            new_entries[j] = old_entries[i];
            new_entries[j + 1] = old_entries[i + 1];
            j += 2;
        }
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = new_entries };
    mf.methods = new_map;
    mf.invalidateCache();

    return args[0];
}

/// (remove-all-methods multifn) => multifn
/// Removes all methods from the multimethod.
pub fn removeAllMethodsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to remove-all-methods", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "remove-all-methods expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };

    const empty_map = try allocator.create(PersistentArrayMap);
    empty_map.* = .{ .entries = &.{} };
    mf.methods = empty_map;
    mf.invalidateCache();

    return args[0];
}

// ============================================================
// prefer-method / prefers
// ============================================================

/// (prefer-method multifn dispatch-val-x dispatch-val-y)
/// Causes the multimethod to prefer matches of dispatch-val-x over dispatch-val-y.
pub fn preferMethodFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prefer-method", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "prefer-method expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };
    const preferred = args[1];
    const over = args[2];

    // Get or create prefer table
    var pt = mf.prefer_table orelse blk: {
        const new_pt = try allocator.create(PersistentArrayMap);
        new_pt.* = .{ .entries = &.{} };
        break :blk new_pt;
    };

    // Get existing set for preferred value, or create new one
    var new_items: []Value = undefined;
    if (pt.get(preferred)) |existing| {
        if (existing.tag() == .set) {
            // Add 'over' to existing set (skip if already present)
            for (existing.asSet().items) |item| {
                if (item.eql(over)) {
                    // Already preferred, no-op
                    return args[0];
                }
            }
            const old = existing.asSet().items;
            new_items = try allocator.alloc(Value, old.len + 1);
            @memcpy(new_items[0..old.len], old);
            new_items[old.len] = over;
        } else {
            new_items = try allocator.alloc(Value, 1);
            new_items[0] = over;
        }
    } else {
        new_items = try allocator.alloc(Value, 1);
        new_items[0] = over;
    }

    const new_set = try allocator.create(PersistentHashSet);
    new_set.* = .{ .items = new_items };
    const set_val = Value.initSet(new_set);

    // Assoc into prefer table
    mf.prefer_table = try assocMap(allocator, pt, preferred, set_val);
    mf.invalidateCache();
    return args[0];
}

/// (prefers multifn) => map of preferred dispatch values
pub fn prefersFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prefers", .{args.len});
    const mf = switch (args[0].tag()) {
        .multi_fn => args[0].asMultiFn(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "prefers expects a multimethod, got {s}", .{@tagName(args[0].tag())}),
    };
    if (mf.prefer_table) |pt| {
        return Value.initMap(pt);
    }
    const empty_map = try allocator.create(PersistentArrayMap);
    empty_map.* = .{ .entries = &.{} };
    return Value.initMap(empty_map);
}

// ============================================================
// isa?-based multimethod dispatch
// ============================================================

/// Find the best method for a dispatch value, checking:
/// 1. Exact match
/// 2. isa?-based match (using global hierarchy)
/// 3. :default fallback
pub fn findBestMethod(mf: *const MultiFn, dispatch_val: Value, env: ?*Env) ?Value {
    // 1. Exact match
    if (mf.methods.get(dispatch_val)) |m| return m;

    // 2. isa?-based matching using custom or global hierarchy
    const hierarchy_val: ?Value = if (mf.hierarchy_var) |hv|
        blk: {
            const v = hv.deref();
            break :blk if (v == .nil) null else v;
        }
    else if (env) |e|
        getGlobalHierarchy(e)
    else
        null;
    if (hierarchy_val) |hv| {
        if (hv.tag() == .map) {
            if (findIsaMatch(mf, dispatch_val, hv.asMap())) |m| return m;
        }
    }

    // 3. :default
    return mf.methods.get(Value.initKeyword(.{ .ns = null, .name = "default" }));
}

const Match = struct { key: Value, method: Value };

fn getGlobalHierarchy(env: *Env) ?Value {
    const core_ns = env.findNamespace("clojure.core") orelse return null;
    const hier_var = core_ns.resolve("global-hierarchy") orelse return null;
    const val = hier_var.deref();
    if (val == .nil) return null;
    return val;
}

fn findIsaMatch(mf: *const MultiFn, dispatch_val: Value, hierarchy: *const PersistentArrayMap) ?Value {
    const ancestors_kw = Value.initKeyword(.{ .ns = null, .name = "ancestors" });
    const ancestors_map_val = hierarchy.get(ancestors_kw) orelse return null;
    if (ancestors_map_val.tag() != .map) return null;
    const ancestors_map = ancestors_map_val.asMap();

    // Collect isa? matches
    var matches_buf: [64]Match = undefined;
    var match_count: usize = 0;

    var i: usize = 0;
    while (i + 1 < mf.methods.entries.len) : (i += 2) {
        const method_key = mf.methods.entries[i];
        const method_val = mf.methods.entries[i + 1];
        // Skip exact match (already checked) and :default
        if (method_key.eql(dispatch_val)) continue;
        if (isDefaultKey(method_key)) continue;

        if (isaCheck(ancestors_map, dispatch_val, method_key)) {
            if (match_count < matches_buf.len) {
                matches_buf[match_count] = .{ .key = method_key, .method = method_val };
                match_count += 1;
            }
        }
    }

    if (match_count == 0) return null;
    if (match_count == 1) return matches_buf[0].method;

    // Multiple matches: use prefer_table to disambiguate
    const matches = matches_buf[0..match_count];
    if (mf.prefer_table) |pt| {
        return resolveWithPrefers(matches, pt, ancestors_map);
    }

    // No prefer table and multiple matches: ambiguous dispatch
    return null;
}

fn isaCheck(ancestors_map: *const PersistentArrayMap, child: Value, parent: Value) bool {
    // Equality
    if (child.eql(parent)) return true;

    // Vector isa?: element-wise
    if (child.tag() == .vector and parent.tag() == .vector) {
        const c = child.asVector().items;
        const p = parent.asVector().items;
        if (c.len != p.len) return false;
        for (c, p) |ci, pi| {
            if (!isaCheck(ancestors_map, ci, pi)) return false;
        }
        return true;
    }

    // Hierarchy check: is parent in ancestors(child)?
    if (ancestors_map.get(child)) |ancestor_set_val| {
        if (ancestor_set_val.tag() == .set) {
            for (ancestor_set_val.asSet().items) |item| {
                if (item.eql(parent)) return true;
            }
        }
    }
    return false;
}

fn isDefaultKey(key: Value) bool {
    if (key.tag() != .keyword) return false;
    if (key.asKeyword().ns != null) return false;
    return std.mem.eql(u8, key.asKeyword().name, "default");
}

fn resolveWithPrefers(matches: []const Match, pt: *const PersistentArrayMap, ancestors_map: *const PersistentArrayMap) ?Value {
    for (matches) |candidate| {
        var is_preferred = true;
        for (matches) |other| {
            if (candidate.key.eql(other.key)) continue;

            // Check if candidate is preferred over other (directly or indirectly)
            if (isPreferred(pt, candidate.key, other.key, ancestors_map)) continue;

            // Check if other is preferred over candidate
            if (isPreferred(pt, other.key, candidate.key, ancestors_map)) {
                is_preferred = false;
                break;
            }

            // Neither is preferred over the other: ambiguous
            is_preferred = false;
            break;
        }
        if (is_preferred) return candidate.method;
    }
    // No candidate is preferred over all others: ambiguous dispatch
    return null;
}

/// Check if `preferred` is preferred over `over`, including indirect
/// preferences through the hierarchy. JVM Clojure semantics:
/// - Direct: preferred is in prefer_table over `over`
/// - Indirect via over: preferred is in prefer_table over some ancestor of `over`
/// - Indirect via preferred: some ancestor of `preferred` is preferred over `over`
fn isPreferred(pt: *const PersistentArrayMap, preferred: Value, over: Value, ancestors_map: *const PersistentArrayMap) bool {
    // Direct preference check
    if (pt.get(preferred)) |set_val| {
        if (set_val.tag() == .set) {
            for (set_val.asSet().items) |item| {
                if (item.eql(over)) return true;
                // Indirect: preferred over an ancestor of `over`
                if (isaCheck(ancestors_map, over, item)) return true;
            }
        }
    }
    // Indirect via preferred: check if any ancestor of `preferred` is preferred over `over`
    if (ancestors_map.get(preferred)) |ancestor_set_val| {
        if (ancestor_set_val.tag() == .set) {
            for (ancestor_set_val.asSet().items) |anc| {
                if (isPreferred(pt, anc, over, ancestors_map)) return true;
            }
        }
    }
    return false;
}

/// Assoc a key-value pair into a PersistentArrayMap, returning a new map.
fn assocMap(allocator: Allocator, m: *PersistentArrayMap, key: Value, val: Value) !*PersistentArrayMap {
    // Check if key already exists — update in place
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        if (m.entries[i].eql(key)) {
            const new_entries = try allocator.alloc(Value, m.entries.len);
            @memcpy(new_entries, m.entries);
            new_entries[i + 1] = val;
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = new_entries };
            return new_map;
        }
    }
    // Key not found — append
    const new_entries = try allocator.alloc(Value, m.entries.len + 2);
    @memcpy(new_entries[0..m.entries.len], m.entries);
    new_entries[m.entries.len] = key;
    new_entries[m.entries.len + 1] = val;
    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = new_entries };
    return new_map;
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "methods",
        .func = &methodsFn,
        .doc = "Given a multimethod, returns a map of dispatch values -> dispatch fns",
        .arglists = "([multifn])",
        .added = "1.0",
    },
    .{
        .name = "get-method",
        .func = &getMethodFn,
        .doc = "Given a multimethod and a dispatch value, returns the dispatch fn that would apply to that value, or nil if none apply and no default",
        .arglists = "([multifn dispatch-val])",
        .added = "1.0",
    },
    .{
        .name = "remove-method",
        .func = &removeMethodFn,
        .doc = "Removes the method of multimethod associated with dispatch-value.",
        .arglists = "([multifn dispatch-val])",
        .added = "1.0",
    },
    .{
        .name = "remove-all-methods",
        .func = &removeAllMethodsFn,
        .doc = "Removes all of the methods of multimethod.",
        .arglists = "([multifn])",
        .added = "1.0",
    },
    .{
        .name = "prefer-method",
        .func = &preferMethodFn,
        .doc = "Causes the multimethod to prefer matches of dispatch-val-x over dispatch-val-y when there is a conflict",
        .arglists = "([multifn dispatch-val-x dispatch-val-y])",
        .added = "1.0",
    },
    .{
        .name = "prefers",
        .func = &prefersFn,
        .doc = "Given a multimethod, returns a map of preferred value -> set of other values",
        .arglists = "([multifn])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "methods - returns method map" {
    var entries = [_]Value{
        Value.initKeyword(.{ .name = "a", .ns = null }),
        Value.initInteger(1),
        Value.initKeyword(.{ .name = "b", .ns = null }),
        Value.initInteger(2),
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = Value.nil_val,
        .methods = &map,
    };

    const args = [_]Value{Value.initMultiFn(&mf)};
    const result = try methodsFn(testing.allocator, &args);
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 4), result.asMap().entries.len);
}

test "get-method - returns method or nil" {
    var entries = [_]Value{
        Value.initKeyword(.{ .name = "a", .ns = null }),
        Value.initInteger(42),
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = Value.nil_val,
        .methods = &map,
    };

    // Found
    const args1 = [_]Value{ Value.initMultiFn(&mf), Value.initKeyword(.{ .name = "a", .ns = null }) };
    const r1 = try getMethodFn(testing.allocator, &args1);
    try testing.expectEqual(Value.initInteger(42), r1);

    // Not found
    const args2 = [_]Value{ Value.initMultiFn(&mf), Value.initKeyword(.{ .name = "b", .ns = null }) };
    const r2 = try getMethodFn(testing.allocator, &args2);
    try testing.expectEqual(Value.nil_val, r2);
}

test "remove-method - removes dispatch entry" {
    var entries = [_]Value{
        Value.initKeyword(.{ .name = "a", .ns = null }),
        Value.initInteger(1),
        Value.initKeyword(.{ .name = "b", .ns = null }),
        Value.initInteger(2),
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = Value.nil_val,
        .methods = &map,
    };

    const args = [_]Value{ Value.initMultiFn(&mf), Value.initKeyword(.{ .name = "a", .ns = null }) };
    const result = try removeMethodFn(testing.allocator, &args);
    try testing.expect(result.tag() == .multi_fn);
    try testing.expectEqual(@as(usize, 2), mf.methods.entries.len);

    // Verify :b remains
    const get_args = [_]Value{ Value.initMultiFn(&mf), Value.initKeyword(.{ .name = "b", .ns = null }) };
    const b_val = try getMethodFn(testing.allocator, &get_args);
    try testing.expectEqual(Value.initInteger(2), b_val);

    // Clean up
    testing.allocator.free(mf.methods.entries);
    testing.allocator.destroy(mf.methods);
}

test "remove-all-methods - clears all methods" {
    var entries = [_]Value{
        Value.initKeyword(.{ .name = "a", .ns = null }),
        Value.initInteger(1),
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = Value.nil_val,
        .methods = &map,
    };

    const args = [_]Value{Value.initMultiFn(&mf)};
    const result = try removeAllMethodsFn(testing.allocator, &args);
    try testing.expect(result.tag() == .multi_fn);
    try testing.expectEqual(@as(usize, 0), mf.methods.entries.len);

    testing.allocator.destroy(mf.methods);
}
