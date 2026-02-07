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
    return switch (args[0].tag()) {
        .nil => Value.true_val,
        .list => Value.initBoolean(args[0].asList().count() == 0),
        .vector => Value.initBoolean(args[0].asVector().count() == 0),
        .map => Value.initBoolean(args[0].asMap().count() == 0),
        .set => Value.initBoolean(args[0].asSet().count() == 0),
        .string => Value.initBoolean(args[0].asString().len == 0),
        else => err.setErrorFmt(.eval, .type_error, .{}, "empty? not supported on {s}", .{@tagName(args[0].tag())}),
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
            item.* = Value.initInteger(@intFromFloat(v));
        } else {
            item.* = Value.initFloat(v);
        }
        v += step_val;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value.initList(lst);
}

/// (repeat n x) — returns a list of x repeated n times.
pub fn repeatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to repeat", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => if (args[0].asInteger() < 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "repeat count must be non-negative, got {d}", .{args[0].asInteger()}) else @as(usize, @intCast(args[0].asInteger())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "repeat expects integer count, got {s}", .{@tagName(args[0].tag())}),
    };
    if (n > 1_000_000) return error.OutOfMemory;

    const items = try allocator.alloc(Value, n);
    for (items) |*item| {
        item.* = args[1];
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value.initList(lst);
}

/// (contains? coll key) — true if key is present in coll.
/// For maps: key lookup. For sets: membership. For vectors: index in range.
pub fn containsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to contains?", .{args.len});
    return switch (args[0].tag()) {
        .map => Value.initBoolean(args[0].asMap().get(args[1]) != null),
        .hash_map => Value.initBoolean(args[0].asHashMap().containsKey(args[1])),
        .set => Value.initBoolean(args[0].asSet().contains(args[1])),
        .vector => switch (args[1].tag()) {
            .integer => Value.initBoolean(args[1].asInteger() >= 0 and @as(usize, @intCast(args[1].asInteger())) < args[0].asVector().count()),
            else => Value.false_val,
        },
        .transient_vector => switch (args[1].tag()) {
            .integer => Value.initBoolean(args[1].asInteger() >= 0 and @as(usize, @intCast(args[1].asInteger())) < args[0].asTransientVector().count()),
            else => Value.false_val,
        },
        .transient_map => blk: {
            const tm = args[0].asTransientMap();
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) break :blk Value.true_val;
            }
            break :blk Value.false_val;
        },
        .transient_set => blk: {
            const ts = args[0].asTransientSet();
            for (ts.items.items) |item| {
                if (item.eql(args[1])) break :blk Value.true_val;
            }
            break :blk Value.false_val;
        },
        .nil => Value.false_val,
        else => err.setErrorFmt(.eval, .type_error, .{}, "contains? not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (key e) — returns the key of the map entry (vector pair).
pub fn keyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to key", .{args.len});
    const vec = switch (args[0].tag()) {
        .vector => args[0].asVector(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "key expects a map entry (vector), got {s}", .{@tagName(args[0].tag())}),
    };
    if (vec.items.len != 2) return err.setErrorFmt(.eval, .value_error, .{}, "key expects a 2-element map entry, got {d} elements", .{vec.items.len});
    return vec.items[0];
}

/// (val e) — returns the val of the map entry (vector pair).
pub fn valFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to val", .{args.len});
    const vec = switch (args[0].tag()) {
        .vector => args[0].asVector(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "val expects a map entry (vector), got {s}", .{@tagName(args[0].tag())}),
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
        const hm = args[0].asHashMap();
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
        return Value.initList(lst);
    }
    const m = switch (args[0].tag()) {
        .map => args[0].asMap(),
        .list, .vector, .set, .string => return Value.nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "keys expects a map, got {s}", .{@tagName(args[0].tag())}),
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
    return Value.initList(lst);
}

/// (vals map) — returns a list of the map's values.
/// For non-map types, returns nil if empty (matches JVM behavior via RT.vals → seq).
pub fn valsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vals", .{args.len});
    if (args[0] == .nil) return Value.nil;
    if (args[0] == .hash_map) {
        const hm = args[0].asHashMap();
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
        return Value.initList(lst);
    }
    const m = switch (args[0].tag()) {
        .map => args[0].asMap(),
        .list, .vector, .set, .string => return Value.nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "vals expects a map, got {s}", .{@tagName(args[0].tag())}),
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
    return Value.initList(lst);
}

fn toFloat(v: Value) !f64 {
    return switch (v.tag()) {
        .integer => @floatFromInt(v.asInteger()),
        .float => v.asFloat(),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(v.tag())}),
    };
}

fn allIntegers(args: []const Value) bool {
    for (args) |a| {
        switch (a.tag()) {
            .integer => {},
            else => return false,
        }
    }
    return true;
}

// ============================================================
// Fused reduce — lazy-seq chain optimization (24A.3, 24C.1, 24C.7)
// ============================================================
//
// The core optimization for lazy-seq performance. Instead of materializing
// each lazy-seq layer into cons cells (O(n) allocations per layer), fused
// reduce walks the chain of meta-annotated lazy-seqs at reduce time and
// executes all transforms in a single pass over the base source.
//
// Example: (reduce + 0 (take 1000 (filter even? (map #(* 3 %) (range 10000)))))
//
// Without fusion: range produces 10K lazy-seqs, map wraps each in another
//   lazy-seq, filter wraps again, take wraps again → 40K+ allocations.
//
// With fusion: fusedReduce walks the meta chain to extract:
//   transforms = [map(#(* 3 %)), filter(even?)]
//   take_n = 1000
//   base = range(0, 10000, 1)
// Then iterates range directly, applying transforms inline → 0 allocations.
//
// The meta annotations are set by __zig-lazy-map, __zig-lazy-filter, etc.
// (called from core.clj's map/filter/take). fusedReduce reads them back.
//
// Performance impact (cumulative):
//   lazy_chain: 21,375ms -> 16ms (1336x)
//   sieve:       2,152ms -> 16ms (134x)
//   transduce:   8,409ms -> 16ms (526x)

const LazySeq = value_mod.LazySeq;
const Cons = value_mod.Cons;
const Reduced = value_mod.Reduced;
const bootstrap = @import("../bootstrap.zig");
const collections_builtin = @import("collections.zig");
const vm_mod = @import("../../native/vm/vm.zig");

/// Call a function value efficiently, reusing the active VM if one exists.
///
/// When called from within a VM execution (e.g. reduce step function calling
/// a predicate), active_vm is set and we reuse the existing VM's stack via
/// callFunction(). This avoids allocating a new VM instance (~500KB) per
/// callback — critical for fused reduce which may call predicates millions
/// of times in a single reduce operation.
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
    return Value.initLazySeq(ls);
}

/// (__zig-lazy-filter pred coll) — creates a meta-annotated lazy-seq for filter.
///
/// Filter chain collapsing (24C.7): When the source is already a filter or
/// filter_chain lazy-seq, this function flattens the nesting into a single
/// lazy_filter_chain with an array of predicates. This is critical for the
/// sieve of Eratosthenes, which creates 168 nested filter layers — without
/// collapsing, realization would recurse 168 levels deep (each level creating
/// a new lazy-seq), consuming ~64MB of stack in Debug builds.
///
/// With collapsing: filter(p3, filter(p2, filter(p1, src)))
///   becomes: filter_chain([p1, p2, p3], src)
/// Fused reduce then applies all predicates in a flat loop.
pub fn zigLazyFilterFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-filter", .{args.len});
    const pred = args[0];
    const source = args[1];

    // Detect and collapse nested filter chains
    if (source == .lazy_seq) {
        const src_ls = source.asLazySeq();
        if (src_ls.realized == null) {
            if (src_ls.meta) |m| {
                switch (m.*) {
                    .lazy_filter => |inner| {
                        // Collapse: filter(pred, filter(inner_pred, src)) → chain([inner_pred, pred], src)
                        const preds = try allocator.alloc(Value, 2);
                        preds[0] = inner.pred;
                        preds[1] = pred;
                        const meta = try allocator.create(LazySeq.Meta);
                        meta.* = .{ .lazy_filter_chain = .{ .preds = preds, .source = inner.source } };
                        const ls = try allocator.create(LazySeq);
                        ls.* = .{ .thunk = null, .realized = null, .meta = meta };
                        return Value.initLazySeq(ls);
                    },
                    .lazy_filter_chain => |inner_chain| {
                        // Extend existing chain
                        const preds = try allocator.alloc(Value, inner_chain.preds.len + 1);
                        @memcpy(preds[0..inner_chain.preds.len], inner_chain.preds);
                        preds[inner_chain.preds.len] = pred;
                        const meta = try allocator.create(LazySeq.Meta);
                        meta.* = .{ .lazy_filter_chain = .{ .preds = preds, .source = inner_chain.source } };
                        const ls = try allocator.create(LazySeq);
                        ls.* = .{ .thunk = null, .realized = null, .meta = meta };
                        return Value.initLazySeq(ls);
                    },
                    else => {},
                }
            }
        }
    }

    // Default: single filter
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .lazy_filter = .{ .pred = pred, .source = source } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value.initLazySeq(ls);
}

/// (__zig-lazy-take n coll) — creates a meta-annotated lazy-seq for take.
pub fn zigLazyTakeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-take", .{args.len});
    const n_val = args[0];
    const n: usize = switch (n_val.tag()) {
        .integer => if (n_val.asInteger() <= 0) 0 else @intCast(n_val.asInteger()),
        .float => if (n_val.asFloat() <= 0) 0 else @intFromFloat(n_val.asFloat()),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-take requires numeric n", .{}),
    };
    if (n == 0) return Value.nil;
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .lazy_take = .{ .n = n, .source = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value.initLazySeq(ls);
}

/// (__zig-lazy-range start end step) — creates a meta-annotated lazy-seq for range.
pub fn zigLazyRangeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-range", .{args.len});
    const start = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    const end_val = switch (args[1].tag()) {
        .integer => args[1].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    const step = switch (args[2].tag()) {
        .integer => args[2].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__zig-lazy-range requires integer args", .{}),
    };
    // Empty range check
    if (step == 0 or (step > 0 and start >= end_val) or (step < 0 and start <= end_val))
        return Value.nil;
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .range = .{ .current = start, .end = end_val, .step = step } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value.initLazySeq(ls);
}

/// (__zig-lazy-iterate f x) — creates a meta-annotated lazy-seq for iterate.
pub fn zigLazyIterateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __zig-lazy-iterate", .{args.len});
    const meta = try allocator.create(LazySeq.Meta);
    meta.* = .{ .iterate = .{ .f = args[0], .current = args[1] } };
    const ls = try allocator.create(LazySeq);
    ls.* = .{ .thunk = null, .realized = null, .meta = meta };
    return Value.initLazySeq(ls);
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
        if (coll.asLazySeq().meta != null) {
            return fusedReduce(allocator, f, init, coll);
        }
    }

    // Direct iteration for concrete collections
    return reduceGeneric(allocator, f, init, coll);
}

/// A single transform extracted from the lazy-seq meta chain.
/// Transforms are stored outermost-first and applied in reverse order
/// (innermost first) during iteration, matching lazy-seq evaluation semantics.
const Transform = struct {
    kind: enum { map, filter },
    fn_val: Value,
};

/// Fused reduce: walk the lazy-seq meta chain, extract transforms + take + base
/// source, then iterate the base source applying all transforms inline.
///
/// Algorithm:
///   1. Walk the meta chain from outermost to innermost, collecting transforms
///      into a fixed-size buffer (max 16 — sufficient for all practical cases).
///      Also extract take_n limit if present.
///   2. Identify the base source (range, iterate, or generic seq).
///   3. Iterate the base source directly, applying transforms in reverse order
///      (innermost first) to each element before accumulating with the reduce fn.
///
/// The fixed-size transform buffer avoids heap allocation. If the chain exceeds
/// 16 transforms or has unsupported structure, we fall back to reduceGeneric.
fn fusedReduce(allocator: Allocator, f: Value, init: Value, coll: Value) anyerror!Value {
    // Phase 1: Walk the chain to extract transforms[], take_n, base_source.
    // Transforms are pushed outermost-first; applied innermost-first in Phase 2.
    var transforms: [16]Transform = undefined;
    var transform_count: usize = 0;
    var take_n: ?usize = null;
    var current = coll;

    while (current == .lazy_seq) {
        const ls = current.asLazySeq();
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
            .lazy_filter_chain => |lfc| {
                for (lfc.preds) |pred| {
                    if (transform_count >= 16) break;
                    transforms[transform_count] = .{ .kind = .filter, .fn_val = pred };
                    transform_count += 1;
                }
                current = lfc.source;
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

    // Phase 2: Fused iteration over the base source with inline transforms.
    // For each element from the base source, apply transforms in reverse order
    // (innermost first), then accumulate with the reduce function.
    var acc = init;
    var remaining: usize = take_n orelse std.math.maxInt(usize);
    var call_buf: [2]Value = undefined; // Reused buffer for reduce fn calls

    // Dispatch on base source type for zero-allocation iteration
    if (current == .lazy_seq) {
        if (current.asLazySeq().meta) |m| {
            switch (m.*) {
                .range => |r| {
                    // Direct range iteration (no lazy-seq allocation)
                    var cur = r.current;
                    while (remaining > 0) {
                        if ((r.step > 0 and cur >= r.end) or (r.step < 0 and cur <= r.end)) break;
                        var elem: Value = Value.initInteger(cur);
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
                        if (acc == .reduced) return acc.asReduced().value;
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
                        if (acc == .reduced) return acc.asReduced().value;
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
        if (acc == .reduced) return acc.asReduced().value;
        remaining -= 1;
    }

    return acc;
}

/// Generic reduce: iterate any collection type.
///
/// Provides fast paths for concrete collection types (vector, list, range,
/// iterate) that avoid the overhead of seq/first/rest protocol dispatch.
/// Vector and list iterate their backing slices directly; range and iterate
/// compute elements inline without any lazy-seq allocation.
///
/// Falls back to seq/first/rest iteration for other types (maps, sets,
/// lazy-seqs without meta, cons cells, etc.).
fn reduceGeneric(allocator: Allocator, f: Value, init: Value, coll: Value) anyerror!Value {
    var acc = init;
    var call_buf: [2]Value = undefined;

    // Fast path: direct iteration for slice-backed and meta-annotated types
    switch (coll.tag()) {
        .vector => {
            for (coll.asVector().items) |item| {
                call_buf[0] = acc;
                call_buf[1] = item;
                acc = try callFn(allocator,f, &call_buf);
                if (acc == .reduced) return acc.asReduced().value;
            }
            return acc;
        },
        .list => {
            for (coll.asList().items) |item| {
                call_buf[0] = acc;
                call_buf[1] = item;
                acc = try callFn(allocator,f, &call_buf);
                if (acc == .reduced) return acc.asReduced().value;
            }
            return acc;
        },
        .lazy_seq => {
            if (coll.asLazySeq().meta) |m| {
                switch (m.*) {
                    .range => |r| {
                        // Direct range iteration (no lazy-seq allocation)
                        var cur = r.current;
                        while (true) {
                            if ((r.step > 0 and cur >= r.end) or (r.step < 0 and cur <= r.end)) break;
                            call_buf[0] = acc;
                            call_buf[1] = Value.initInteger(cur);
                            acc = try callFn(allocator, f, &call_buf);
                            if (acc == .reduced) return acc.asReduced().value;
                            cur += r.step;
                        }
                        return acc;
                    },
                    .iterate => |it| {
                        // Direct iterate iteration
                        var cur = it.current;
                        while (true) {
                            call_buf[0] = acc;
                            call_buf[1] = cur;
                            acc = try callFn(allocator, f, &call_buf);
                            if (acc == .reduced) return acc.asReduced().value;
                            cur = try callFn(allocator, it.f, &[1]Value{cur});
                        }
                    },
                    else => {},
                }
            }
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
        if (acc == .reduced) return acc.asReduced().value;
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
    try testing.expectEqual(Value.true_val, result);
}

test "empty? on empty list returns true" {
    var lst = PersistentList{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value.initList(&lst)});
    try testing.expectEqual(Value.true_val, result);
}

test "empty? on non-empty list returns false" {
    const items = [_]Value{Value.initInteger(1)};
    var lst = PersistentList{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value.initList(&lst)});
    try testing.expectEqual(Value.false_val, result);
}

test "empty? on empty vector returns true" {
    var vec = PersistentVector{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expectEqual(Value.true_val, result);
}

test "empty? on non-empty vector returns false" {
    const items = [_]Value{Value.initInteger(1)};
    var vec = PersistentVector{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expectEqual(Value.false_val, result);
}

test "empty? on empty string returns true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try emptyFn(alloc, &.{Value.initString(alloc, "")});
    try testing.expectEqual(Value.true_val, result);
}

test "empty? on non-empty string returns false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try emptyFn(alloc, &.{Value.initString(alloc, "hello")});
    try testing.expectEqual(Value.false_val, result);
}

test "empty? arity check" {
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{}));
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{ Value.nil, Value.nil }));
}

// --- range tests ---

test "range with single arg (range 5)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{Value.initInteger(5)});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.asList().count());
    // Should be 0, 1, 2, 3, 4
    try testing.expectEqual(Value.initInteger(0), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(4), result.asList().items[4]);
}

test "range with two args (range 2 6)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{ Value.initInteger(2), Value.initInteger(6) });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.asList().count());
    try testing.expectEqual(Value.initInteger(2), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(5), result.asList().items[3]);
}

test "range with three args (range 0 10 3)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value.initInteger(0),
        Value.initInteger(10),
        Value.initInteger(3),
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.asList().count());
    // 0, 3, 6, 9
    try testing.expectEqual(Value.initInteger(0), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(9), result.asList().items[3]);
}

test "range with negative step" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value.initInteger(5),
        Value.initInteger(0),
        Value.initInteger(-1),
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.asList().count());
    try testing.expectEqual(Value.initInteger(5), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(1), result.asList().items[4]);
}

test "range with float produces floats" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value.initFloat(0.0),
        Value.initFloat(1.0),
        Value.initFloat(0.5),
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().count());
    try testing.expectEqual(Value.initFloat(0.0), result.asList().items[0]);
    try testing.expectEqual(Value.initFloat(0.5), result.asList().items[1]);
}

test "range empty when start >= end" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value.initInteger(5),
        Value.initInteger(3),
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.asList().count());
}

test "range zero step is error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try testing.expectError(error.ArithmeticError, rangeFn(arena.allocator(), &.{
        Value.initInteger(0),
        Value.initInteger(10),
        Value.initInteger(0),
    }));
}

test "range arity check" {
    try testing.expectError(error.ArityError, rangeFn(test_alloc, &.{}));
}

// --- repeat tests ---

test "repeat 3 times" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try repeatFn(arena.allocator(), &.{ Value.initInteger(3), Value.initInteger(42) });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().count());
    try testing.expectEqual(Value.initInteger(42), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(42), result.asList().items[2]);
}

test "repeat 0 times" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try repeatFn(alloc, &.{ Value.initInteger(0), Value.initString(alloc, "x") });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.asList().count());
}

test "repeat arity check" {
    try testing.expectError(error.ArityError, repeatFn(test_alloc, &.{Value.initInteger(3)}));
}

// --- contains? tests ---

test "contains? on map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const yes = try containsFn(alloc, &.{ Value.initMap(&m), Value.initKeyword(alloc, .{ .name = "a", .ns = null }) });
    try testing.expectEqual(Value.true_val, yes);
    const no = try containsFn(alloc, &.{ Value.initMap(&m), Value.initKeyword(alloc, .{ .name = "z", .ns = null }) });
    try testing.expectEqual(Value.false_val, no);
}

test "contains? on vector checks index" {
    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20) };
    var vec = PersistentVector{ .items = &items };
    const yes = try containsFn(test_alloc, &.{ Value.initVector(&vec), Value.initInteger(0) });
    try testing.expectEqual(Value.true_val, yes);
    const no = try containsFn(test_alloc, &.{ Value.initVector(&vec), Value.initInteger(5) });
    try testing.expectEqual(Value.false_val, no);
}

test "contains? on nil returns false" {
    const result = try containsFn(test_alloc, &.{ Value.nil, Value.initInteger(0) });
    try testing.expectEqual(Value.false_val, result);
}

// --- keys/vals tests ---

test "keys on map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try keysFn(alloc, &.{Value.initMap(&m)});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().count());
    try testing.expect(result.asList().items[0].eql(Value.initKeyword(alloc, .{ .name = "a", .ns = null })));
}

test "keys on nil returns nil" {
    const result = try keysFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "vals on map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try valsFn(alloc, &.{Value.initMap(&m)});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().count());
    try testing.expectEqual(Value.initInteger(1), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(2), result.asList().items[1]);
}

test "vals on nil returns nil" {
    const result = try valsFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "key on map entry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = [_]Value{ Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };
    const result = try keyFn(alloc, &.{Value.initVector(vec)});
    try testing.expect(result == .keyword);
    try testing.expectEqualStrings("a", result.asKeyword().name);
}

test "val on map entry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = [_]Value{ Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(42) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };
    const result = try valFn(alloc, &.{Value.initVector(vec)});
    try testing.expectEqual(Value.initInteger(42), result);
}
