// Sequence utility functions — range, repeat, iterate, empty?, contains?, keys, vals.
//
// Runtime functions (kind = .runtime_fn) dispatched via BuiltinFn.
// Phase 6a additions to the standard library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const PersistentVector = value_mod.PersistentVector;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashMap = value_mod.PersistentHashMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");

// ============================================================
// Implementations
// ============================================================

/// (empty? coll) — returns true if coll has no items, or coll is nil.
pub fn emptyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to empty?", .{args.len});
    return switch (args[0]) {
        .nil => Value{ .boolean = true },
        .list => |lst| Value{ .boolean = lst.count() == 0 },
        .vector => |vec| Value{ .boolean = vec.count() == 0 },
        .map => |m| Value{ .boolean = m.count() == 0 },
        .set => |s| Value{ .boolean = s.count() == 0 },
        .string => |s| Value{ .boolean = s.len == 0 },
        else => err.setErrorFmt(.eval, .type_error, .{}, "empty? not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (range n), (range start end), (range start end step) — returns a list of numbers.
/// Eager implementation (not lazy). All-integer args produce integer results.
pub fn rangeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to range", .{args.len});

    // Extract numeric values as f64 for uniform handling
    const start_val: f64 = if (args.len == 1) 0.0 else try toFloat(args[0]);
    const end_val: f64 = if (args.len == 1) try toFloat(args[0]) else try toFloat(args[1]);
    const step_val: f64 = if (args.len == 3) try toFloat(args[2]) else 1.0;

    if (step_val == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "range step must not be zero", .{});

    // Determine if all inputs are integers (for integer output)
    const all_int = allIntegers(args);

    // Calculate count
    var count: usize = 0;
    if (step_val > 0) {
        var v = start_val;
        while (v < end_val) : (v += step_val) {
            count += 1;
            if (count > 1_000_000) return error.OutOfMemory; // safety limit
        }
    } else {
        var v = start_val;
        while (v > end_val) : (v += step_val) {
            count += 1;
            if (count > 1_000_000) return error.OutOfMemory;
        }
    }

    // Build list
    const items = try allocator.alloc(Value, count);
    var v = start_val;
    for (items) |*item| {
        if (all_int) {
            item.* = Value{ .integer = @intFromFloat(v) };
        } else {
            item.* = Value{ .float = v };
        }
        v += step_val;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (repeat n x) — returns a list of x repeated n times.
pub fn repeatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to repeat", .{args.len});
    const n = switch (args[0]) {
        .integer => |i| if (i < 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "repeat count must be non-negative, got {d}", .{i}) else @as(usize, @intCast(i)),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "repeat expects integer count, got {s}", .{@tagName(args[0])}),
    };
    if (n > 1_000_000) return error.OutOfMemory;

    const items = try allocator.alloc(Value, n);
    for (items) |*item| {
        item.* = args[1];
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (contains? coll key) — true if key is present in coll.
/// For maps: key lookup. For sets: membership. For vectors: index in range.
pub fn containsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to contains?", .{args.len});
    return switch (args[0]) {
        .map => |m| Value{ .boolean = m.get(args[1]) != null },
        .hash_map => |hm| Value{ .boolean = hm.containsKey(args[1]) },
        .set => |s| Value{ .boolean = s.contains(args[1]) },
        .vector => |vec| switch (args[1]) {
            .integer => |i| Value{ .boolean = i >= 0 and @as(usize, @intCast(i)) < vec.count() },
            else => Value{ .boolean = false },
        },
        .transient_vector => |tv| switch (args[1]) {
            .integer => |i| Value{ .boolean = i >= 0 and @as(usize, @intCast(i)) < tv.count() },
            else => Value{ .boolean = false },
        },
        .transient_map => |tm| blk: {
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) break :blk Value{ .boolean = true };
            }
            break :blk Value{ .boolean = false };
        },
        .transient_set => |ts| blk: {
            for (ts.items.items) |item| {
                if (item.eql(args[1])) break :blk Value{ .boolean = true };
            }
            break :blk Value{ .boolean = false };
        },
        .nil => Value{ .boolean = false },
        else => err.setErrorFmt(.eval, .type_error, .{}, "contains? not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (key e) — returns the key of the map entry (vector pair).
pub fn keyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to key", .{args.len});
    const vec = switch (args[0]) {
        .vector => |v| v,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "key expects a map entry (vector), got {s}", .{@tagName(args[0])}),
    };
    if (vec.items.len != 2) return err.setErrorFmt(.eval, .value_error, .{}, "key expects a 2-element map entry, got {d} elements", .{vec.items.len});
    return vec.items[0];
}

/// (val e) — returns the val of the map entry (vector pair).
pub fn valFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to val", .{args.len});
    const vec = switch (args[0]) {
        .vector => |v| v,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "val expects a map entry (vector), got {s}", .{@tagName(args[0])}),
    };
    if (vec.items.len != 2) return err.setErrorFmt(.eval, .value_error, .{}, "val expects a 2-element map entry, got {d} elements", .{vec.items.len});
    return vec.items[1];
}

/// (keys map) — returns a list of the map's keys.
/// For non-map types, returns nil if empty (matches JVM behavior via RT.keys → seq).
pub fn keysFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keys", .{args.len});
    if (args[0] == .nil) return Value.nil;
    if (args[0] == .hash_map) {
        const hm = args[0].hash_map;
        const n = hm.getCount();
        if (n == 0) return Value.nil;
        const flat = try hm.toEntries(allocator);
        const items = try allocator.alloc(Value, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            items[i] = flat[i * 2];
        }
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = items };
        return Value{ .list = lst };
    }
    const m = switch (args[0]) {
        .map => |m| m,
        .list, .vector, .set, .string => return Value.nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "keys expects a map, got {s}", .{@tagName(args[0])}),
    };
    const n = m.count();
    if (n == 0) return Value.nil;
    const items = try allocator.alloc(Value, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        items[i] = m.entries[i * 2];
    }
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (vals map) — returns a list of the map's values.
/// For non-map types, returns nil if empty (matches JVM behavior via RT.vals → seq).
pub fn valsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vals", .{args.len});
    if (args[0] == .nil) return Value.nil;
    if (args[0] == .hash_map) {
        const hm = args[0].hash_map;
        const n = hm.getCount();
        if (n == 0) return Value.nil;
        const flat = try hm.toEntries(allocator);
        const items = try allocator.alloc(Value, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            items[i] = flat[i * 2 + 1];
        }
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = items };
        return Value{ .list = lst };
    }
    const m = switch (args[0]) {
        .map => |m| m,
        .list, .vector, .set, .string => return Value.nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "vals expects a map, got {s}", .{@tagName(args[0])}),
    };
    const n = m.count();
    if (n == 0) return Value.nil;
    const items = try allocator.alloc(Value, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        items[i] = m.entries[i * 2 + 1];
    }
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

fn toFloat(v: Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(v)}),
    };
}

fn allIntegers(args: []const Value) bool {
    for (args) |a| {
        switch (a) {
            .integer => {},
            else => return false,
        }
    }
    return true;
}

// ============================================================
// Fused reduce — lazy-seq chain optimization (24A.3)
// ============================================================

const LazySeq = value_mod.LazySeq;
const Cons = value_mod.Cons;
const Reduced = value_mod.Reduced;
const bootstrap = @import("../bootstrap.zig");
const collections_builtin = @import("collections.zig");
const vm_mod = @import("../../native/vm/vm.zig");

/// Call a function efficiently: use active VM if available (avoids ~500KB VM allocation),
/// otherwise fall back to bootstrap.callFnVal.
fn callFn(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    if (vm_mod.active_vm) |vm| {
        return vm.callFunction(fn_val, args) catch |e| {
            return @as(anyerror, @errorCast(e));
        };
    }
    return bootstrap.callFnVal(allocator, fn_val, args);
}

/// (__zig-lazy-map f coll) — creates a meta-annotated lazy-seq for map.
pub fn zigLazyMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-map", .{args.len});
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .lazy_map = .{ .f = args[0], .source = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value{ .lazy_seq = ls };
}

/// (__zig-lazy-filter pred coll) — creates a meta-annotated lazy-seq for filter.
pub fn zigLazyFilterFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-filter", .{args.len});
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .lazy_filter = .{ .pred = args[0], .source = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value{ .lazy_seq = ls };
}

/// (__zig-lazy-take n coll) — creates a meta-annotated lazy-seq for take.
pub fn zigLazyTakeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-take", .{args.len});
    const n_val = args[0];
    const n: usize = switch (n_val) {
        .integer => |i| if (i <= 0) 0 else @intCast(i),
        .float => |f| if (f <= 0) 0 else @intFromFloat(f),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-take requires numeric n", .{}),
    };
    if (n == 0) return Value.nil;
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .lazy_take = .{ .n = n, .source = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value{ .lazy_seq = ls };
}

/// (__zig-lazy-range start end step) — creates a meta-annotated lazy-seq for range.
pub fn zigLazyRangeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-range", .{args.len});
    const start = switch (args[0]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    const end_val = switch (args[1]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    const step = switch (args[2]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    // Empty range check
    if (step == 0 or (step > 0 and start >= end_val) or (step < 0 and start <= end_val))
        return Value.nil;
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .range = .{ .current = start, .end = end_val, .step = step } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value{ .lazy_seq = ls };
}

/// (__zig-lazy-iterate f x) — creates a meta-annotated lazy-seq for iterate.
pub fn zigLazyIterateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-iterate", .{args.len});
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .iterate = .{ .f = args[0], .current = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value{ .lazy_seq = ls };
}

/// (__zig-reduce f init coll) — fused reduce with lazy-seq chain optimization.
/// Detects meta-annotated lazy-seq chains and fuses map/filter/take/range
/// into a single pass without intermediate lazy-seq allocations.
pub fn zigReduceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-reduce", .{args.len});
    const f = args[0];
    const init = args[1];
    const coll = args[2];

    // Try fused path for meta-annotated lazy-seq chains
    if (coll == .lazy_seq) {
        if (coll.lazy_seq.meta != null) {
            return fusedReduce(allocator, f, init, coll);
        }
    }

    // Direct iteration for concrete collections
    return reduceGeneric(allocator, f, init, coll);
}

const Transform = struct {
    kind: enum { map, filter },
    fn_val: Value,
};

/// Fused reduce: walk the lazy-seq meta chain, extract transforms + take + base source,
/// then iterate the base source applying transforms inline.
fn fusedReduce(allocator: Allocator, f: Value, init: Value, coll: Value) anyerror!Value {
    // Walk the chain to extract: transforms[], take_n, base_source
    var transforms: [16]Transform = undefined;
    var transform_count: usize = 0;
    var take_n: ?usize = null;
    var current = coll;

    while (current == .lazy_seq) {
        const ls = current.lazy_seq;
        const m = ls.meta orelse break;
        switch (m.*) {
            .lazy_map => |lm| {
                if (transform_count >= 16) break;
                transforms[transform_count] = .{ .kind = .map, .fn_val = lm.f };
                transform_count += 1;
                current = lm.source;
            },
            .lazy_filter => |lf| {
                if (transform_count >= 16) break;
                transforms[transform_count] = .{ .kind = .filter, .fn_val = lf.pred };
                transform_count += 1;
                current = lf.source;
            },
            .lazy_take => |lt| {
                if (take_n != null) break; // nested takes not supported
                take_n = lt.n;
                current = lt.source;
            },
            .range, .iterate => break, // base source found
        }
    }

    // If no transforms and no take, fallback to generic reduce
    if (transform_count == 0 and take_n == null) {
        return reduceGeneric(allocator, f, init, current);
    }

    // Fused iteration
    var acc = init;
    var remaining: usize = take_n orelse std.math.maxInt(usize);
    var call_buf: [2]Value = undefined;

    // Detect base source type
    if (current == .lazy_seq) {
        if (current.lazy_seq.meta) |m| {
            switch (m.*) {
                .range => |r| {
                    // Direct range iteration (no lazy-seq allocation)
                    var cur = r.current;
                    while (remaining > 0) {
                        if ((r.step > 0 and cur >= r.end) or (r.step < 0 and cur <= r.end)) break;
                        var elem: Value = .{ .integer = cur };
                        var skip = false;

                        // Apply transforms in reverse (outermost was pushed first)
                        var ti: usize = transform_count;
                        while (ti > 0) {
                            ti -= 1;
                            switch (transforms[ti].kind) {
                                .filter => {
                                    const pred_result = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                                    if (!pred_result.isTruthy()) {
                                        skip = true;
                                        break;
                                    }
                                },
                                .map => {
                                    elem = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                                },
                            }
                        }

                        cur += r.step;
                        if (skip) continue;

                        call_buf[0] = acc;
                        call_buf[1] = elem;
                        acc = try callFn(allocator,f, &call_buf);
                        if (acc == .reduced) return acc.reduced.value;
                        remaining -= 1;
                    }
                    return acc;
                },
                .iterate => |it| {
                    // Direct iterate source
                    var iter_cur = it.current;
                    while (remaining > 0) {
                        var elem = iter_cur;
                        var skip = false;

                        var ti: usize = transform_count;
                        while (ti > 0) {
                            ti -= 1;
                            switch (transforms[ti].kind) {
                                .filter => {
                                    const pred_result = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                                    if (!pred_result.isTruthy()) {
                                        skip = true;
                                        break;
                                    }
                                },
                                .map => {
                                    elem = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                                },
                            }
                        }

                        iter_cur = try callFn(allocator,it.f, &[1]Value{iter_cur});
                        if (skip) continue;

                        call_buf[0] = acc;
                        call_buf[1] = elem;
                        acc = try callFn(allocator,f, &call_buf);
                        if (acc == .reduced) return acc.reduced.value;
                        remaining -= 1;
                    }
                    return acc;
                },
                else => {},
            }
        }
    }

    // Fallback: iterate base source via seq/first/rest with transforms applied
    var seq_cur = current;
    while (remaining > 0) {
        const seq_val = try collections_builtin.seqFn(allocator, &[1]Value{seq_cur});
        if (seq_val == .nil) break;
        var elem = try collections_builtin.firstFn(allocator, &[1]Value{seq_val});
        seq_cur = try collections_builtin.restFn(allocator, &[1]Value{seq_val});
        var skip = false;

        var ti: usize = transform_count;
        while (ti > 0) {
            ti -= 1;
            switch (transforms[ti].kind) {
                .filter => {
                    const pred_result = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                    if (!pred_result.isTruthy()) {
                        skip = true;
                        break;
                    }
                },
                .map => {
                    elem = try callFn(allocator,transforms[ti].fn_val, &[1]Value{elem});
                },
            }
        }

        if (skip) continue;

        call_buf[0] = acc;
        call_buf[1] = elem;
        acc = try callFn(allocator,f, &call_buf);
        if (acc == .reduced) return acc.reduced.value;
        remaining -= 1;
    }

    return acc;
}

/// Generic reduce: iterate any collection via seq/first/rest.
fn reduceGeneric(allocator: Allocator, f: Value, init: Value, coll: Value) anyerror!Value {
    var acc = init;
    var call_buf: [2]Value = undefined;

    // Fast path for vectors and lists: direct slice iteration
    switch (coll) {
        .vector => |v| {
            for (v.items) |item| {
                call_buf[0] = acc;
                call_buf[1] = item;
                acc = try callFn(allocator,f, &call_buf);
                if (acc == .reduced) return acc.reduced.value;
            }
            return acc;
        },
        .list => |l| {
            for (l.items) |item| {
                call_buf[0] = acc;
                call_buf[1] = item;
                acc = try callFn(allocator,f, &call_buf);
                if (acc == .reduced) return acc.reduced.value;
            }
            return acc;
        },
        .nil => return acc,
        else => {},
    }

    // Generic path: seq/first/rest iteration
    var seq_cur = coll;
    while (true) {
        const seq_val = try collections_builtin.seqFn(allocator, &[1]Value{seq_cur});
        if (seq_val == .nil) break;
        const elem = try collections_builtin.firstFn(allocator, &[1]Value{seq_val});
        seq_cur = try collections_builtin.restFn(allocator, &[1]Value{seq_val});

        call_buf[0] = acc;
        call_buf[1] = elem;
        acc = try callFn(allocator,f, &call_buf);
        if (acc == .reduced) return acc.reduced.value;
    }

    return acc;
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "empty?",
        .func = &emptyFn,
        .doc = "Returns true if coll has no items - same as (not (seq coll)). Please use the idiom (seq x) rather than (not (empty? x)).",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "range",
        .func = &rangeFn,
        .doc = "Returns a list of nums from start (inclusive) to end (exclusive), by step.",
        .arglists = "([end] [start end] [start end step])",
        .added = "1.0",
    },
    .{
        .name = "repeat",
        .func = &repeatFn,
        .doc = "Returns a list of xs repeated n times.",
        .arglists = "([n x])",
        .added = "1.0",
    },
    .{
        .name = "contains?",
        .func = &containsFn,
        .doc = "Returns true if key is present in the given collection, otherwise returns false.",
        .arglists = "([coll key])",
        .added = "1.0",
    },
    .{
        .name = "key",
        .func = &keyFn,
        .doc = "Returns the key of the map entry.",
        .arglists = "([e])",
        .added = "1.0",
    },
    .{
        .name = "val",
        .func = &valFn,
        .doc = "Returns the value in the map entry.",
        .arglists = "([e])",
        .added = "1.0",
    },
    .{
        .name = "keys",
        .func = &keysFn,
        .doc = "Returns a sequence of the map's keys, in the same order as (seq map).",
        .arglists = "([map])",
        .added = "1.0",
    },
    .{
        .name = "vals",
        .func = &valsFn,
        .doc = "Returns a sequence of the map's values, in the same order as (seq map).",
        .arglists = "([map])",
        .added = "1.0",
    },
    // Fused reduce builtins (24A.3) — internal, called by core.clj
    .{
        .name = "__zig-lazy-map",
        .func = &zigLazyMapFn,
        .doc = "Internal: creates meta-annotated lazy-seq for map (fused reduce).",
        .arglists = "([f coll])",
        .added = "1.0",
    },
    .{
        .name = "__zig-lazy-filter",
        .func = &zigLazyFilterFn,
        .doc = "Internal: creates meta-annotated lazy-seq for filter (fused reduce).",
        .arglists = "([pred coll])",
        .added = "1.0",
    },
    .{
        .name = "__zig-lazy-take",
        .func = &zigLazyTakeFn,
        .doc = "Internal: creates meta-annotated lazy-seq for take (fused reduce).",
        .arglists = "([n coll])",
        .added = "1.0",
    },
    .{
        .name = "__zig-lazy-range",
        .func = &zigLazyRangeFn,
        .doc = "Internal: creates meta-annotated lazy-seq for range (fused reduce).",
        .arglists = "([start end step])",
        .added = "1.0",
    },
    .{
        .name = "__zig-lazy-iterate",
        .func = &zigLazyIterateFn,
        .doc = "Internal: creates meta-annotated lazy-seq for iterate (fused reduce).",
        .arglists = "([f x])",
        .added = "1.0",
    },
    .{
        .name = "__zig-reduce",
        .func = &zigReduceFn,
        .doc = "Internal: fused reduce with lazy-seq chain optimization.",
        .arglists = "([f init coll])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "empty? on nil returns true" {
    const result = try emptyFn(test_alloc, &.{Value.nil});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on empty list returns true" {
    var lst = PersistentList{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty list returns false" {
    const items = [_]Value{.{ .integer = 1 }};
    var lst = PersistentList{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? on empty vector returns true" {
    var vec = PersistentVector{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty vector returns false" {
    const items = [_]Value{.{ .integer = 1 }};
    var vec = PersistentVector{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? on empty string returns true" {
    const result = try emptyFn(test_alloc, &.{Value{ .string = "" }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty string returns false" {
    const result = try emptyFn(test_alloc, &.{Value{ .string = "hello" }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? arity check" {
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{}));
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{ Value.nil, Value.nil }));
}

// --- range tests ---

test "range with single arg (range 5)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{Value{ .integer = 5 }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.count());
    // Should be 0, 1, 2, 3, 4
    try testing.expectEqual(Value{ .integer = 0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[4]);
}

test "range with two args (range 2 6)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{ Value{ .integer = 2 }, Value{ .integer = 6 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.list.count());
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 5 }, result.list.items[3]);
}

test "range with three args (range 0 10 3)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 0 },
        Value{ .integer = 10 },
        Value{ .integer = 3 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.list.count());
    // 0, 3, 6, 9
    try testing.expectEqual(Value{ .integer = 0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 9 }, result.list.items[3]);
}

test "range with negative step" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 5 },
        Value{ .integer = 0 },
        Value{ .integer = -1 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.count());
    try testing.expectEqual(Value{ .integer = 5 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[4]);
}

test "range with float produces floats" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .float = 0.0 },
        Value{ .float = 1.0 },
        Value{ .float = 0.5 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expectEqual(Value{ .float = 0.0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .float = 0.5 }, result.list.items[1]);
}

test "range empty when start >= end" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 5 },
        Value{ .integer = 3 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "range zero step is error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try testing.expectError(error.ArithmeticError, rangeFn(arena.allocator(), &.{
        Value{ .integer = 0 },
        Value{ .integer = 10 },
        Value{ .integer = 0 },
    }));
}

test "range arity check" {
    try testing.expectError(error.ArityError, rangeFn(test_alloc, &.{}));
}

// --- repeat tests ---

test "repeat 3 times" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try repeatFn(arena.allocator(), &.{ Value{ .integer = 3 }, Value{ .integer = 42 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expectEqual(Value{ .integer = 42 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 42 }, result.list.items[2]);
}

test "repeat 0 times" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try repeatFn(arena.allocator(), &.{ Value{ .integer = 0 }, Value{ .string = "x" } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "repeat arity check" {
    try testing.expectError(error.ArityError, repeatFn(test_alloc, &.{Value{ .integer = 3 }}));
}

// --- contains? tests ---

test "contains? on map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const yes = try containsFn(test_alloc, &.{ Value{ .map = &m }, Value{ .keyword = .{ .name = "a", .ns = null } } });
    try testing.expectEqual(Value{ .boolean = true }, yes);
    const no = try containsFn(test_alloc, &.{ Value{ .map = &m }, Value{ .keyword = .{ .name = "z", .ns = null } } });
    try testing.expectEqual(Value{ .boolean = false }, no);
}

test "contains? on vector checks index" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 } };
    var vec = PersistentVector{ .items = &items };
    const yes = try containsFn(test_alloc, &.{ Value{ .vector = &vec }, Value{ .integer = 0 } });
    try testing.expectEqual(Value{ .boolean = true }, yes);
    const no = try containsFn(test_alloc, &.{ Value{ .vector = &vec }, Value{ .integer = 5 } });
    try testing.expectEqual(Value{ .boolean = false }, no);
}

test "contains? on nil returns false" {
    const result = try containsFn(test_alloc, &.{ Value.nil, Value{ .integer = 0 } });
    try testing.expectEqual(Value{ .boolean = false }, result);
}

// --- keys/vals tests ---

test "keys on map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try keysFn(arena.allocator(), &.{Value{ .map = &m }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expect(result.list.items[0].eql(Value{ .keyword = .{ .name = "a", .ns = null } }));
}

test "keys on nil returns nil" {
    const result = try keysFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "vals on map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try valsFn(arena.allocator(), &.{Value{ .map = &m }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[1]);
}

test "vals on nil returns nil" {
    const result = try valsFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "key on map entry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };
    const result = try keyFn(alloc, &.{Value{ .vector = vec }});
    try testing.expect(result == .keyword);
    try testing.expectEqualStrings("a", result.keyword.name);
}

test "val on map entry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 42 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };
    const result = try valFn(alloc, &.{Value{ .vector = vec }});
    try testing.expectEqual(Value{ .integer = 42 }, result);
}
