// Collection intrinsic functions — first, rest, cons, conj, assoc, get, nth, count.
//
// Runtime functions (kind = .runtime_fn) dispatched via BuiltinFn.
// These operate on the persistent collection types defined in collections.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const PersistentVector = value_mod.PersistentVector;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashMap = value_mod.PersistentHashMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const collections_mod = @import("../collections.zig");
const HASH_MAP_THRESHOLD = collections_mod.HASH_MAP_THRESHOLD;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const bootstrap = @import("../bootstrap.zig");
const err = @import("../error.zig");

// ============================================================
// Implementations
// ============================================================

/// (first coll) — returns the first element, or nil if empty/nil.
pub fn firstFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to first", .{args.len});
    return switch (args[0].tag()) {
        .list => args[0].asList().first(),
        .vector => if (args[0].asVector().items.len > 0) args[0].asVector().items[0] else Value.nil_val,
        .nil => Value.nil_val,
        .cons => args[0].asCons().first,
        .map, .hash_map => {
            const s = try seqFn(allocator, args);
            if (s == Value.nil_val) return Value.nil_val;
            const seq_args = [1]Value{s};
            return firstFn(allocator, &seq_args);
        },
        .set => {
            const s = try seqFn(allocator, args);
            if (s == Value.nil_val) return Value.nil_val;
            const seq_args = [1]Value{s};
            return firstFn(allocator, &seq_args);
        },
        .lazy_seq => {
            const realized = try args[0].asLazySeq().realize(allocator);
            const realized_args = [1]Value{realized};
            return firstFn(allocator, &realized_args);
        },
        .chunked_cons => args[0].asChunkedCons().first(),
        .string => {
            const s = args[0].asString();
            if (s.len == 0) return Value.nil_val;
            const cp_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            const cp = std.unicode.utf8Decode(s[0..cp_len]) catch s[0];
            return Value.initChar(cp);
        },
        .array => if (args[0].asArray().items.len > 0) args[0].asArray().items[0] else Value.nil_val,
        else => err.setErrorFmt(.eval, .type_error, .{}, "first not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (rest coll) — returns everything after first, or empty list.
pub fn restFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rest", .{args.len});
    return switch (args[0].tag()) {
        .list => blk: {
            const r = args[0].asList().rest();
            const new_list = try allocator.create(PersistentList);
            new_list.* = r;
            break :blk Value.initList(new_list);
        },
        .vector => blk: {
            const vec = args[0].asVector();
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = if (vec.items.len > 0) vec.items[1..] else &.{} };
            break :blk Value.initList(new_list);
        },
        .nil => blk: {
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = &.{} };
            break :blk Value.initList(new_list);
        },
        .cons => args[0].asCons().rest,
        .map, .hash_map => {
            const s = try seqFn(allocator, args);
            if (s == Value.nil_val) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value.initList(empty);
            }
            const seq_args = [1]Value{s};
            return restFn(allocator, &seq_args);
        },
        .set => {
            const s = try seqFn(allocator, args);
            if (s == Value.nil_val) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value.initList(empty);
            }
            const seq_args = [1]Value{s};
            return restFn(allocator, &seq_args);
        },
        .lazy_seq => {
            const realized = try args[0].asLazySeq().realize(allocator);
            const realized_args = [1]Value{realized};
            return restFn(allocator, &realized_args);
        },
        .chunked_cons => {
            const rest_val = try args[0].asChunkedCons().next(allocator);
            if (rest_val == Value.nil_val) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value.initList(empty);
            }
            return rest_val;
        },
        .string => blk: {
            const s = args[0].asString();
            if (s.len == 0) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                break :blk Value.initList(empty);
            }
            const cp_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            const rest_str = s[cp_len..];
            // Convert remaining chars to list of characters
            var chars: std.ArrayList(Value) = .empty;
            var i: usize = 0;
            while (i < rest_str.len) {
                const cl = std.unicode.utf8ByteSequenceLength(rest_str[i]) catch 1;
                const cp = std.unicode.utf8Decode(rest_str[i..][0..cl]) catch rest_str[i];
                try chars.append(allocator, Value.initChar(cp));
                i += cl;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = try chars.toOwnedSlice(allocator) };
            break :blk Value.initList(lst);
        },
        .array => blk: {
            const arr = args[0].asArray();
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = if (arr.items.len > 0) arr.items[1..] else &.{} };
            break :blk Value.initList(new_list);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "rest not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (cons x seq) — prepend x to seq, returns a list or cons cell.
/// Returns a Cons cell when rest is lazy_seq or cons (preserves laziness).
pub fn consFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to cons", .{args.len});
    const x = args[0];
    const rest_arg = args[1];

    // JVM RT.cons: if rest is already ISeq (list/cons/lazy_seq/chunked_cons) or nil,
    // use directly. Otherwise call RT.seq() to convert (vector/set/map/string/etc).
    const rest = switch (rest_arg.tag()) {
        .nil, .list, .cons, .lazy_seq, .chunked_cons => rest_arg,
        .vector, .set, .map, .hash_map, .string => try seqFn(allocator, &.{rest_arg}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "cons expects a seq-able rest, got {s}", .{@tagName(rest_arg.tag())}),
    };

    const cell = try allocator.create(value_mod.Cons);
    cell.* = .{ .first = x, .rest = rest };
    return Value.initCons(cell);
}

/// (conj coll x) — add to collection (front for list, back for vector).
pub fn conjFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        // (conj) => []
        const empty = try allocator.alloc(Value, 0);
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = empty };
        return Value.initVector(vec);
    }
    if (args.len == 1) return args[0]; // (conj coll) => coll
    const coll = args[0];
    // conj adds remaining args one at a time
    var current = coll;
    for (args[1..]) |x| {
        current = try conjOne(allocator, current, x);
    }
    return current;
}

fn conjOne(allocator: Allocator, coll: Value, x: Value) anyerror!Value {
    switch (coll.tag()) {
        .list => {
            const lst = coll.asList();
            const new_items = try allocator.alloc(Value, lst.items.len + 1);
            new_items[0] = x;
            @memcpy(new_items[1..], lst.items);
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items, .meta = lst.meta };
            return Value.initList(new_list);
        },
        .vector => {
            const vec = coll.asVector();
            // Vector conj with geometric COW (Copy-on-Write) optimization (24C.4).
            //
            // Problem: Naive persistent vector conj copies the entire backing
            // array on every append — O(n) per conj, O(n^2) for n conj's.
            //
            // Solution: Vectors carry a generation tag in a hidden slot at
            // backing[_capacity]. The global _vec_gen_counter is monotonically
            // increasing. When conj is called:
            //
            //   1. If _capacity > 0 and there's room (len < capacity):
            //      Check if backing[_capacity].integer == vec._gen.
            //      - Match: This vector owns the tail of the backing array.
            //        Extend in-place (O(1)), bump the generation.
            //      - Mismatch: Another vector branched from this backing.
            //        Fall through to copy path.
            //
            //   2. Copy path: Allocate new backing with 2x capacity (geometric
            //      growth), copy existing items, append new element.
            //
            // This gives O(1) amortized conj for sequential appends (the common
            // case in reduce, into, etc.) while preserving persistent semantics
            // when vectors are shared (branching triggers a fresh copy).
            //
            // Impact: vector_ops 180ms -> 14ms (13x), list_build 178ms -> 13ms (14x).
            if (vec._capacity > 0 and vec.items.len < vec._capacity) {
                const gen_slot = vec.items.ptr[vec._capacity];
                if (gen_slot.tag() == .integer and gen_slot.asInteger() == vec._gen) {
                    // Gen match: extend in-place — this vector owns the tail
                    const mutable_ptr: [*]Value = @constCast(vec.items.ptr);
                    mutable_ptr[vec.items.len] = x;
                    collections_mod._vec_gen_counter += 1;
                    mutable_ptr[vec._capacity] = Value.initInteger(collections_mod._vec_gen_counter);
                    const new_vec = try allocator.create(PersistentVector);
                    new_vec.* = .{
                        .items = vec.items.ptr[0 .. vec.items.len + 1],
                        .meta = vec.meta,
                        ._capacity = vec._capacity,
                        ._gen = collections_mod._vec_gen_counter,
                    };
                    return Value.initVector(new_vec);
                }
            }
            // Gen mismatch or no capacity: allocate new backing with geometric growth
            const old_len = vec.items.len;
            const new_capacity = if (old_len < 4) 8 else old_len * 2;
            const backing = try allocator.alloc(Value, new_capacity + 1); // +1 for gen tag
            @memcpy(backing[0..old_len], vec.items);
            backing[old_len] = x;
            collections_mod._vec_gen_counter += 1;
            backing[new_capacity] = Value.initInteger(collections_mod._vec_gen_counter);
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{
                .items = backing[0 .. old_len + 1],
                .meta = vec.meta,
                ._capacity = new_capacity,
                ._gen = collections_mod._vec_gen_counter,
            };
            return Value.initVector(new_vec);
        },
        .set => {
            const s = coll.asSet();
            // Add element if not already present
            if (s.contains(x)) return coll;
            const new_items = try allocator.alloc(Value, s.items.len + 1);
            @memcpy(new_items[0..s.items.len], s.items);
            new_items[s.items.len] = x;
            // Re-sort if sorted set
            if (s.comparator) |comp| {
                try sortSetItems(allocator, new_items, comp);
            }
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = new_items, .meta = s.meta, .comparator = s.comparator };
            return Value.initSet(new_set);
        },
        .map, .hash_map => {
            // (conj map [k v]) => (assoc map k v)
            if (x.tag() == .vector) {
                const pair = x.asVector();
                if (pair.items.len != 2) return err.setErrorFmt(.eval, .value_error, .{}, "conj on map expects vector of 2 elements, got {d}", .{pair.items.len});
                const assoc_args = [_]Value{ coll, pair.items[0], pair.items[1] };
                return assocFn(allocator, &assoc_args);
            } else if (x.tag() == .map) {
                // (conj map1 map2) => merge map2 into map1
                var result = coll;
                const entries = x.asMap().entries;
                var i: usize = 0;
                while (i < entries.len) : (i += 2) {
                    const assoc_args = [_]Value{ result, entries[i], entries[i + 1] };
                    result = try assocFn(allocator, &assoc_args);
                }
                return result;
            } else if (x.tag() == .hash_map) {
                // (conj map1 hash_map2) => merge hash_map2 into map1
                var result = coll;
                const entries = try x.asHashMap().toEntries(allocator);
                var i: usize = 0;
                while (i < entries.len) : (i += 2) {
                    const assoc_args = [_]Value{ result, entries[i], entries[i + 1] };
                    result = try assocFn(allocator, &assoc_args);
                }
                return result;
            }
            return err.setErrorFmt(.eval, .type_error, .{}, "conj on map expects vector or map, got {s}", .{@tagName(x.tag())});
        },
        .cons => {
            // (conj cons-seq x) — prepend to seq (like list)
            const cell = try allocator.create(value_mod.Cons);
            cell.* = .{ .first = x, .rest = coll };
            return Value.initCons(cell);
        },
        .nil => {
            // (conj nil x) => (x) — returns a list
            const new_items = try allocator.alloc(Value, 1);
            new_items[0] = x;
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items };
            return Value.initList(new_list);
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "conj not supported on {s}", .{@tagName(coll.tag())}),
    }
}

/// (assoc map key val & kvs) — associate key(s) with val(s) in map or vector.
/// For maps: (assoc {:a 1} :b 2) => {:a 1 :b 2}
/// For vectors: (assoc [1 2 3] 1 99) => [1 99 3] (index must be <= count)
pub fn assocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to assoc", .{args.len});
    const base = args[0];

    // Handle vector case
    if (base.tag() == .vector) {
        return assocVector(allocator, base.asVector(), args[1..]);
    }

    // Handle hash_map case — use HAMT assoc directly
    if (base.tag() == .hash_map) {
        var hm = base.asHashMap();
        var i: usize = 0;
        while (i < args.len - 1) : (i += 2) {
            hm = try hm.assoc(allocator, args[i + 1], args[i + 2]);
        }
        return Value.initHashMap(hm);
    }

    // Handle map/nil case
    const base_entries = switch (base.tag()) {
        .map => base.asMap().entries,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "assoc expects a map, vector, or nil, got {s}", .{@tagName(base.tag())}),
    };

    // Fast path: single key-value pair on non-sorted ArrayMap (most common case)
    if (args.len == 3 and (base.tag() != .map or base.asMap().comparator == null)) {
        const key = args[1];
        const val = args[2];
        // Check if key exists — direct copy with replacement (no ArrayList)
        var j: usize = 0;
        while (j < base_entries.len) : (j += 2) {
            if (base_entries[j].eql(key)) {
                const new_entries = try allocator.alloc(Value, base_entries.len);
                @memcpy(new_entries, base_entries);
                new_entries[j + 1] = val;
                const new_map = try allocator.create(PersistentArrayMap);
                new_map.* = .{ .entries = new_entries, .meta = if (base.tag() == .map) base.asMap().meta else null, .comparator = null };
                return Value.initMap(new_map);
            }
        }
        // Key not found — append single new entry
        const new_entries = try allocator.alloc(Value, base_entries.len + 2);
        @memcpy(new_entries[0..base_entries.len], base_entries);
        new_entries[base_entries.len] = key;
        new_entries[base_entries.len + 1] = val;
        if (new_entries.len / 2 > HASH_MAP_THRESHOLD) {
            const hm = try PersistentHashMap.fromEntries(allocator, new_entries);
            // Preserve metadata from input map during ArrayMap→HashMap transition
            if (base.tag() == .map) {
                const base_meta = base.asMap().meta;
                if (base_meta != null) {
                    const hm_with_meta = try allocator.create(PersistentHashMap);
                    hm_with_meta.* = hm.*;
                    hm_with_meta.meta = base_meta;
                    return Value.initHashMap(hm_with_meta);
                }
            }
            return Value.initHashMap(hm);
        }
        const new_map = try allocator.create(PersistentArrayMap);
        new_map.* = .{ .entries = new_entries, .meta = if (base.tag() == .map) base.asMap().meta else null, .comparator = null };
        return Value.initMap(new_map);
    }

    // General path: multiple key-value pairs or sorted maps
    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, base_entries);

    var i: usize = 0;
    while (i < args.len - 1) : (i += 2) {
        const key = args[i + 1];
        const val = args[i + 2];
        var found = false;
        var j: usize = 0;
        while (j < entries.items.len) : (j += 2) {
            if (entries.items[j].eql(key)) {
                entries.items[j + 1] = val;
                found = true;
                break;
            }
        }
        if (!found) {
            try entries.append(allocator, key);
            try entries.append(allocator, val);
        }
    }

    const base_comp: ?Value = if (base.tag() == .map) base.asMap().comparator else null;

    if (base_comp) |comp| {
        try sortMapEntries(allocator, entries.items, comp);
    }

    if (base_comp == null and entries.items.len / 2 > HASH_MAP_THRESHOLD) {
        const hm = try PersistentHashMap.fromEntries(allocator, entries.items);
        // Preserve metadata during ArrayMap→HashMap transition
        if (base.tag() == .map) {
            const base_meta = base.asMap().meta;
            if (base_meta != null) {
                const hm_with_meta = try allocator.create(PersistentHashMap);
                hm_with_meta.* = hm.*;
                hm_with_meta.meta = base_meta;
                return Value.initHashMap(hm_with_meta);
            }
        }
        return Value.initHashMap(hm);
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = if (base.tag() == .map) base.asMap().meta else null, .comparator = base_comp };
    return Value.initMap(new_map);
}

/// Helper for assoc on vectors
fn assocVector(allocator: Allocator, vec: *const PersistentVector, kvs: []const Value) anyerror!Value {
    // Copy original items
    var items = std.ArrayList(Value).empty;
    try items.appendSlice(allocator, vec.items);

    var i: usize = 0;
    while (i < kvs.len) : (i += 2) {
        const idx_val = kvs[i];
        const val = kvs[i + 1];

        // Index must be integer
        const idx = switch (idx_val.tag()) {
            .integer => if (idx_val.asInteger() >= 0) @as(usize, @intCast(idx_val.asInteger())) else return err.setErrorFmt(.eval, .index_error, .{}, "assoc index out of bounds: {d}", .{idx_val.asInteger()}),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "assoc expects integer index, got {s}", .{@tagName(idx_val.tag())}),
        };

        // Index must be <= count (allows appending at exactly count position)
        if (idx > items.items.len) return err.setErrorFmt(.eval, .index_error, .{}, "assoc index {d} out of bounds for vector of size {d}", .{ idx, items.items.len });

        if (idx == items.items.len) {
            // Append at end
            try items.append(allocator, val);
        } else {
            // Replace at index
            items.items[idx] = val;
        }
    }

    const new_vec = try allocator.create(PersistentVector);
    new_vec.* = .{ .items = items.items, .meta = vec.meta };
    return Value.initVector(new_vec);
}

/// (get map key) or (get map key not-found) — lookup in map or set.
pub fn getFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to get", .{args.len});
    const not_found: Value = if (args.len == 3) args[2] else Value.nil_val;
    return switch (args[0].tag()) {
        .map => args[0].asMap().get(args[1]) orelse not_found,
        .hash_map => args[0].asHashMap().get(args[1]) orelse not_found,
        .vector => blk: {
            if (args[1].tag() != .integer) break :blk not_found;
            const idx = args[1].asInteger();
            if (idx < 0) break :blk not_found;
            break :blk args[0].asVector().nth(@intCast(idx)) orelse not_found;
        },
        .set => if (args[0].asSet().contains(args[1])) args[1] else not_found,
        .transient_vector => blk: {
            if (args[1].tag() != .integer) break :blk not_found;
            const tv = args[0].asTransientVector();
            const idx = args[1].asInteger();
            if (idx < 0 or @as(usize, @intCast(idx)) >= tv.items.items.len) break :blk not_found;
            break :blk tv.items.items[@intCast(idx)];
        },
        .transient_map => blk: {
            const tm = args[0].asTransientMap();
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) break :blk tm.entries.items[i + 1];
            }
            break :blk not_found;
        },
        .transient_set => blk: {
            const ts = args[0].asTransientSet();
            for (ts.items.items) |item| {
                if (item.eql(args[1])) break :blk args[1];
            }
            break :blk not_found;
        },
        .nil => not_found,
        else => not_found,
    };
}

/// (nth coll index) or (nth coll index not-found) — indexed access.
pub fn nthFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to nth", .{args.len});
    const idx_val = args[1];
    if (idx_val.tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "nth expects integer index, got {s}", .{@tagName(idx_val.tag())});
    const idx = idx_val.asInteger();
    if (idx < 0) {
        if (args.len == 3) return args[2];
        return err.setErrorFmt(.eval, .index_error, .{}, "nth index out of bounds: {d}", .{idx});
    }
    const uidx: usize = @intCast(idx);
    const not_found: ?Value = if (args.len == 3) args[2] else null;

    return switch (args[0].tag()) {
        .vector => args[0].asVector().nth(uidx) orelse not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for vector of size {d}", .{ uidx, args[0].asVector().items.len }),
        .list => if (uidx < args[0].asList().items.len) args[0].asList().items[uidx] else not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for list of size {d}", .{ uidx, args[0].asList().items.len }),
        .array_chunk => args[0].asArrayChunk().nth(uidx) orelse not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for chunk of size {d}", .{ uidx, args[0].asArrayChunk().count() }),
        .nil => not_found orelse Value.nil_val,
        .lazy_seq, .cons => nthSeq(allocator, args[0], uidx, not_found),
        .string => nthString(args[0].asString(), uidx, not_found),
        .array => if (uidx < args[0].asArray().items.len) args[0].asArray().items[uidx] else not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for array of size {d}", .{ uidx, args[0].asArray().items.len }),
        else => err.setErrorFmt(.eval, .type_error, .{}, "nth not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// Walk seq to find nth element.
fn nthSeq(allocator: Allocator, coll: Value, idx: usize, not_found: ?Value) anyerror!Value {
    var current = coll;
    var i: usize = 0;
    while (i <= idx) {
        const first_result = try firstFn(allocator, &.{current});
        if (i == idx) {
            // Check if we've exhausted the seq
            if (current == Value.nil_val or (current.tag() == .lazy_seq and current.asLazySeq().realized != null and current.asLazySeq().realized.? == Value.nil_val)) {
                return not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds", .{idx});
            }
            return first_result;
        }
        const rest_result = try restFn(allocator, &.{current});
        if (rest_result == Value.nil_val) {
            return not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds", .{idx});
        }
        current = rest_result;
        i += 1;
    }
    return not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds", .{idx});
}

/// nth on string returns character at index.
fn nthString(s: []const u8, idx: usize, not_found: ?Value) anyerror!Value {
    if (idx >= s.len) {
        return not_found orelse err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for string of length {d}", .{ idx, s.len });
    }
    return Value.initChar(s[idx]);
}

/// (count coll) — number of elements.
pub fn countFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to count", .{args.len});
    if (args[0].tag() == .lazy_seq) {
        const realized = try args[0].asLazySeq().realize(allocator);
        const realized_args = [1]Value{realized};
        return countFn(allocator, &realized_args);
    }
    if (args[0].tag() == .cons) {
        // Count by walking the cons chain
        var n: i64 = 0;
        var current = args[0];
        while (current.tag() == .cons) {
            n += 1;
            current = current.asCons().rest;
        }
        // Count remaining (list/vector/nil)
        const rest_args = [1]Value{current};
        const rest_count = try countFn(allocator, &rest_args);
        return Value.initInteger(n + rest_count.asInteger());
    }
    if (args[0].tag() == .chunked_cons) {
        // Count by walking chunked_cons chain
        var n: i64 = 0;
        var current = args[0];
        while (current.tag() == .chunked_cons) {
            n += @intCast(current.asChunkedCons().chunk.count());
            current = current.asChunkedCons().more;
        }
        const rest_args = [1]Value{current};
        const rest_count = try countFn(allocator, &rest_args);
        return Value.initInteger(n + rest_count.asInteger());
    }
    return Value.initInteger(@intCast(switch (args[0].tag()) {
        .list => args[0].asList().count(),
        .vector => args[0].asVector().count(),
        .map => args[0].asMap().count(),
        .hash_map => args[0].asHashMap().getCount(),
        .set => args[0].asSet().count(),
        .nil => @as(usize, 0),
        .string => args[0].asString().len,
        .transient_vector => args[0].asTransientVector().count(),
        .transient_map => args[0].asTransientMap().count(),
        .transient_set => args[0].asTransientSet().count(),
        .array_chunk => args[0].asArrayChunk().count(),
        .array => args[0].asArray().count(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "count not supported on {s}", .{@tagName(args[0].tag())}),
    }));
}

/// (list & items) — returns a new list containing the items.
pub fn listFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value.initList(lst);
}

/// (seq coll) — returns a seq on the collection. Returns nil if empty.
pub fn seqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to seq", .{args.len});
    return switch (args[0].tag()) {
        .nil => Value.nil_val,
        .list => if (args[0].asList().items.len == 0) Value.nil_val else args[0],
        .vector => {
            const vec = args[0].asVector();
            if (vec.items.len == 0) return Value.nil_val;
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = vec.items };
            return Value.initList(lst);
        },
        .cons => args[0], // cons is always non-empty
        .chunked_cons => args[0], // chunked_cons is always non-empty
        .map => {
            const m = args[0].asMap();
            const n = m.count();
            if (n == 0) return Value.nil_val;
            const entry_vecs = try allocator.alloc(Value, n);
            var idx: usize = 0;
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                const pair = try allocator.alloc(Value, 2);
                pair[0] = m.entries[i];
                pair[1] = m.entries[i + 1];
                const vec = try allocator.create(PersistentVector);
                vec.* = .{ .items = pair };
                entry_vecs[idx] = Value.initVector(vec);
                idx += 1;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = entry_vecs };
            return Value.initList(lst);
        },
        .hash_map => {
            const hm = args[0].asHashMap();
            const n = hm.getCount();
            if (n == 0) return Value.nil_val;
            const flat = try hm.toEntries(allocator);
            const entry_vecs = try allocator.alloc(Value, n);
            var idx: usize = 0;
            var i: usize = 0;
            while (i < flat.len) : (i += 2) {
                const pair = try allocator.alloc(Value, 2);
                pair[0] = flat[i];
                pair[1] = flat[i + 1];
                const vec = try allocator.create(PersistentVector);
                vec.* = .{ .items = pair };
                entry_vecs[idx] = Value.initVector(vec);
                idx += 1;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = entry_vecs };
            return Value.initList(lst);
        },
        .set => {
            const s = args[0].asSet();
            if (s.items.len == 0) return Value.nil_val;
            // Convert set items to list
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = s.items };
            return Value.initList(lst);
        },
        .lazy_seq => {
            const realized = try args[0].asLazySeq().realize(allocator);
            const realized_args = [1]Value{realized};
            return seqFn(allocator, &realized_args);
        },
        .string => {
            const s = args[0].asString();
            if (s.len == 0) return Value.nil_val;
            var chars: std.ArrayList(Value) = .empty;
            var i: usize = 0;
            while (i < s.len) {
                const cl = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                const cp = std.unicode.utf8Decode(s[i..][0..cl]) catch s[i];
                try chars.append(allocator, Value.initChar(cp));
                i += cl;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = try chars.toOwnedSlice(allocator) };
            return Value.initList(lst);
        },
        .array => {
            const arr = args[0].asArray();
            if (arr.items.len == 0) return Value.nil_val;
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = arr.items };
            return Value.initList(lst);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "seq not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (concat) / (concat x) / (concat x y ...) — concatenate sequences.
pub fn concatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = &.{} };
        return Value.initList(lst);
    }

    // Collect all items from all sequences using collectSeqItems
    var all: std.ArrayList(Value) = .empty;
    for (args) |arg| {
        if (arg == Value.nil_val) continue;
        const seq_items = try collectSeqItems(allocator, arg);
        for (seq_items) |item| try all.append(allocator, item);
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = try all.toOwnedSlice(allocator) };
    return Value.initList(lst);
}

/// (reverse coll) — returns a list of items in reverse order.
/// nil returns empty list. Works on any seqable collection.
pub fn reverseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reverse", .{args.len});
    if (args[0] == Value.nil_val) {
        const empty_lst = try allocator.create(PersistentList);
        empty_lst.* = .{ .items = &.{} };
        return Value.initList(empty_lst);
    }
    const items = try collectSeqItems(allocator, args[0]);
    if (items.len == 0) {
        const empty_lst = try allocator.create(PersistentList);
        empty_lst.* = .{ .items = &.{} };
        return Value.initList(empty_lst);
    }

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value.initList(lst);
}

/// (rseq rev) — returns a seq of items in reverse order, nil if empty.
pub fn rseqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rseq", .{args.len});
    const items = switch (args[0].tag()) {
        .nil => return Value.nil_val,
        .vector => args[0].asVector().items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "rseq not supported on {s}", .{@tagName(args[0].tag())}),
    };
    if (items.len == 0) return Value.nil_val;

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value.initList(lst);
}

/// (shuffle coll) — returns a random permutation of coll as a vector.
pub fn shuffleFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to shuffle", .{args.len});
    const items = try collectSeqItems(allocator, args[0]);
    if (items.len == 0) {
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = &.{} };
        return Value.initVector(vec);
    }

    // Fisher-Yates shuffle
    const mutable = try allocator.alloc(Value, items.len);
    @memcpy(mutable, items);
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    const random = prng.random();
    var i: usize = mutable.len - 1;
    while (i > 0) : (i -= 1) {
        const j = random.intRangeAtMost(usize, 0, i);
        const tmp = mutable[i];
        mutable[i] = mutable[j];
        mutable[j] = tmp;
    }

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = mutable };
    return Value.initVector(vec);
}

/// (into to from) — returns a new coll with items from `from` conj'd onto `to`.
pub fn intoFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to into", .{args.len});
    if (args[1] == Value.nil_val) return args[0];
    const from_items = try collectSeqItems(allocator, args[1]);
    if (from_items.len == 0) return args[0];

    var current = args[0];
    for (from_items) |item| {
        current = try conjFn(allocator, &.{ current, item });
    }
    return current;
}

/// (apply f args) / (apply f x y args) — calls f with args from final collection.
pub fn applyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to apply", .{args.len});

    const f = args[0];
    const last_arg = args[args.len - 1];

    // Collect spread args from last collection
    const spread_items: []const Value = if (last_arg == Value.nil_val)
        &.{}
    else
        try collectSeqItems(allocator, last_arg);

    // Build final args: middle args + spread items
    const middle_count = args.len - 2; // exclude f and last_arg
    const total = middle_count + spread_items.len;
    const call_args = try allocator.alloc(Value, total);
    if (middle_count > 0) {
        @memcpy(call_args[0..middle_count], args[1 .. args.len - 1]);
    }
    if (spread_items.len > 0) {
        @memcpy(call_args[middle_count..], spread_items);
    }

    // Call the function
    return switch (f.tag()) {
        .builtin_fn => f.asBuiltinFn()(allocator, call_args),
        .fn_val => bootstrap.callFnVal(allocator, f, call_args),
        .keyword => blk: {
            const kw = f.asKeyword();
            // keyword as function: (:kw map) or (:kw map default)
            if (call_args.len < 1 or call_args.len > 2) {
                if (call_args.len > 20) {
                    if (kw.ns) |ns| {
                        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (> 20) passed to: :{s}/{s}", .{ ns, kw.name });
                    } else {
                        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (> 20) passed to: :{s}", .{kw.name});
                    }
                }
                if (kw.ns) |ns| {
                    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: :{s}/{s}", .{ call_args.len, ns, kw.name });
                } else {
                    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: :{s}", .{ call_args.len, kw.name });
                }
            }
            const kw_val = Value.initKeyword(allocator, kw);
            if (call_args[0].tag() == .map) {
                break :blk call_args[0].asMap().get(kw_val) orelse
                    if (call_args.len == 2) call_args[1] else Value.nil_val;
            } else if (call_args[0].tag() == .hash_map) {
                break :blk call_args[0].asHashMap().get(kw_val) orelse
                    if (call_args.len == 2) call_args[1] else Value.nil_val;
            } else {
                break :blk if (call_args.len == 2) call_args[1] else Value.nil_val;
            }
        },
        .map => blk: {
            // map as function: ({:a 1} :a) or ({:a 1} :a default)
            if (call_args.len < 1 or call_args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map lookup", .{call_args.len});
            break :blk f.asMap().get(call_args[0]) orelse
                if (call_args.len == 2) call_args[1] else Value.nil_val;
        },
        .hash_map => blk: {
            // hash_map as function
            if (call_args.len < 1 or call_args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map lookup", .{call_args.len});
            break :blk f.asHashMap().get(call_args[0]) orelse
                if (call_args.len == 2) call_args[1] else Value.nil_val;
        },
        .set => blk: {
            // set as function: (#{:a :b} :a)
            if (call_args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set lookup", .{call_args.len});
            break :blk if (f.asSet().contains(call_args[0])) call_args[0] else Value.nil_val;
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "apply expects a function, got {s}", .{@tagName(f.tag())}),
    };
}

/// (vector & items) — creates a vector from arguments.
pub fn vectorFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (hash-map & kvs) — creates a map from key-value pairs.
pub fn hashMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "hash-map requires even number of args, got {d}", .{args.len});
    // Deduplicate: later values win for duplicate keys (JVM semantics)
    var entries = std.ArrayList(Value).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const key = args[i];
        const val = args[i + 1];
        // Check if key already exists, update if so
        var found = false;
        var j: usize = 0;
        while (j < entries.items.len) : (j += 2) {
            if (entries.items[j].eql(key)) {
                entries.items[j + 1] = val;
                found = true;
                break;
            }
        }
        if (!found) {
            try entries.append(allocator, key);
            try entries.append(allocator, val);
        }
    }
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries.items };
    return Value.initMap(map);
}

/// (__seq-to-map x) — coerce seq-like values to maps for map destructuring.
/// Implements Clojure 1.11 seq-to-map-for-destructuring semantics:
/// - If seq has exactly 1 element that's a map: return that map directly
/// - If seq has odd elements and last is a map: merge trailing map into key-value pairs
/// - Otherwise: treat as key-value pairs and create map
/// - Non-seqs pass through unchanged
pub fn seqToMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __seq-to-map", .{args.len});
    return switch (args[0].tag()) {
        .nil => Value.nil_val, // JVM: (seq? nil) → false, passes through
        .list => seqToMapFromSlice(allocator, args[0].asList().items),
        .cons, .lazy_seq => seqToMapFromSlice(allocator, try collectSeqItems(allocator, args[0])),
        else => args[0], // maps, vectors, etc. pass through
    };
}

/// Helper for seqToMapFn: convert slice to map with Clojure 1.11 semantics.
/// Matches JVM (seq-to-map-for-destructuring s):
/// - (next s) truthy → createAsIfByAssoc (handles trailing map)
/// - (seq s) truthy (1 element) → (first s)
/// - otherwise → empty map
fn seqToMapFromSlice(allocator: Allocator, items: []const Value) anyerror!Value {
    if (items.len == 0) {
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = &.{} };
        return Value.initMap(map);
    }
    // Clojure 1.11: single element → return it directly (even if nil)
    if (items.len == 1) {
        return items[0];
    }
    // Clojure 1.11: if odd elements and last is a map, merge trailing map
    if (items.len % 2 == 1 and (items[items.len - 1].tag() == .map or items[items.len - 1].tag() == .hash_map)) {
        // Create map from preceding key-value pairs
        const base_map = try hashMapFn(allocator, items[0 .. items.len - 1]);
        if (items[items.len - 1].tag() == .hash_map) {
            // Convert hash_map to flat entries and merge via assoc
            const hm_entries = try items[items.len - 1].asHashMap().toEntries(allocator);
            var result = base_map;
            var k: usize = 0;
            while (k < hm_entries.len) : (k += 2) {
                const assoc_args = [_]Value{ result, hm_entries[k], hm_entries[k + 1] };
                result = try assocFn(allocator, &assoc_args);
            }
            return result;
        }
        // Merge trailing ArrayMap into base map
        const trailing = items[items.len - 1].asMap();
        return mergeInto(allocator, base_map, trailing);
    }
    return hashMapFn(allocator, items);
}

/// Merge entries from src map into dst map (like Clojure's merge).
/// Maps store flat arrays: [k1,v1,k2,v2,...]
fn mergeInto(allocator: Allocator, base: Value, src: *const PersistentArrayMap) anyerror!Value {
    if (base.tag() == .hash_map) {
        // Merge src entries into hash_map using HAMT assoc
        var hm = base.asHashMap();
        var i: usize = 0;
        while (i < src.entries.len) : (i += 2) {
            hm = try hm.assoc(allocator, src.entries[i], src.entries[i + 1]);
        }
        return Value.initHashMap(hm);
    }
    if (base.tag() != .map) return base;
    var entries: std.ArrayList(Value) = .empty;
    // Add all entries from base
    for (base.asMap().entries) |v| {
        entries.append(allocator, v) catch return error.OutOfMemory;
    }
    // Merge entries from src (overwrite existing keys)
    var i: usize = 0;
    while (i < src.entries.len) : (i += 2) {
        const src_key = src.entries[i];
        const src_val = src.entries[i + 1];
        var found = false;
        var j: usize = 0;
        while (j < entries.items.len) : (j += 2) {
            if (entries.items[j].eql(src_key)) {
                entries.items[j + 1] = src_val;
                found = true;
                break;
            }
        }
        if (!found) {
            entries.append(allocator, src_key) catch return error.OutOfMemory;
            entries.append(allocator, src_val) catch return error.OutOfMemory;
        }
    }
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries.items };
    return Value.initMap(map);
}

/// (merge & maps) — returns a map that consists of the rest of the maps conj-ed onto the first.
/// If a key occurs in more than one map, the mapping from the latter (left-to-right) will be the mapping in the result.
pub fn mergeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.nil_val;

    // Skip leading nils, find first map
    var start: usize = 0;
    while (start < args.len and args[start] == Value.nil_val) : (start += 1) {}
    if (start >= args.len) return Value.nil_val;

    // Start with entries from first map
    const first_entries: []const Value = if (args[start].tag() == .map)
        args[start].asMap().entries
    else if (args[start].tag() == .hash_map)
        try args[start].asHashMap().toEntries(allocator)
    else
        return err.setErrorFmt(.eval, .type_error, .{}, "merge expects a map, got {s}", .{@tagName(args[start].tag())});

    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, first_entries);

    // Merge remaining maps left-to-right
    for (args[start + 1 ..]) |arg| {
        if (arg == Value.nil_val) continue;
        const src: []const Value = if (arg.tag() == .map)
            arg.asMap().entries
        else if (arg.tag() == .hash_map)
            try arg.asHashMap().toEntries(allocator)
        else
            return err.setErrorFmt(.eval, .type_error, .{}, "merge expects a map, got {s}", .{@tagName(arg.tag())});
        var i: usize = 0;
        while (i < src.len) : (i += 2) {
            const key = src[i];
            const val = src[i + 1];
            var found = false;
            var j: usize = 0;
            while (j < entries.items.len) : (j += 2) {
                if (entries.items[j].eql(key)) {
                    entries.items[j + 1] = val;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try entries.append(allocator, key);
                try entries.append(allocator, val);
            }
        }
    }

    // If result is large enough, return as hash_map
    const n_pairs = entries.items.len / 2;
    if (n_pairs > HASH_MAP_THRESHOLD) {
        const hm = try PersistentHashMap.fromEntries(allocator, entries.items);
        return Value.initHashMap(hm);
    }
    const first_meta: ?*const Value = if (args[start].tag() == .map) args[start].asMap().meta else args[start].asHashMap().meta;
    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = first_meta };
    return Value.initMap(new_map);
}

/// (merge-with f & maps) — merge maps, calling (f old new) on key conflicts.
pub fn mergeWithFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to merge-with", .{args.len});

    const f = args[0];
    const maps = args[1..];

    if (maps.len == 0) return Value.nil_val;

    // Skip leading nils
    var start: usize = 0;
    while (start < maps.len and maps[start] == Value.nil_val) : (start += 1) {}
    if (start >= maps.len) return Value.nil_val;

    const first_entries: []const Value = if (maps[start].tag() == .map)
        maps[start].asMap().entries
    else if (maps[start].tag() == .hash_map)
        try maps[start].asHashMap().toEntries(allocator)
    else
        return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a map, got {s}", .{@tagName(maps[start].tag())});

    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, first_entries);

    for (maps[start + 1 ..]) |arg| {
        if (arg == Value.nil_val) continue;
        const src: []const Value = if (arg.tag() == .map)
            arg.asMap().entries
        else if (arg.tag() == .hash_map)
            try arg.asHashMap().toEntries(allocator)
        else
            return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a map, got {s}", .{@tagName(arg.tag())});
        var i: usize = 0;
        while (i < src.len) : (i += 2) {
            const key = src[i];
            const val = src[i + 1];
            var found = false;
            var j: usize = 0;
            while (j < entries.items.len) : (j += 2) {
                if (entries.items[j].eql(key)) {
                    // Key conflict: call f(old_val, new_val)
                    entries.items[j + 1] = switch (f.tag()) {
                        .builtin_fn => try f.asBuiltinFn()(allocator, &.{ entries.items[j + 1], val }),
                        else => return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a function, got {s}", .{@tagName(f.tag())}),
                    };
                    found = true;
                    break;
                }
            }
            if (!found) {
                try entries.append(allocator, key);
                try entries.append(allocator, val);
            }
        }
    }

    // If result is large enough, return as hash_map
    const n_pairs = entries.items.len / 2;
    if (n_pairs > HASH_MAP_THRESHOLD) {
        const hm = try PersistentHashMap.fromEntries(allocator, entries.items);
        return Value.initHashMap(hm);
    }
    const first_meta: ?*const Value = if (maps[start].tag() == .map) maps[start].asMap().meta else maps[start].asHashMap().meta;
    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = first_meta };
    return Value.initMap(new_map);
}

/// Generic value comparison returning std.math.Order.
/// Supports: nil, booleans, integers, floats, strings, keywords, symbols.
/// Cross-type numeric comparison supported. Non-comparable types return TypeError.
pub fn compareValues(a: Value, b: Value) anyerror!std.math.Order {
    // nil sorts before everything
    if (a == Value.nil_val and b == Value.nil_val) return .eq;
    if (a == Value.nil_val) return .lt;
    if (b == Value.nil_val) return .gt;

    // booleans: false < true
    if (a.tag() == .boolean and b.tag() == .boolean) {
        if (a.asBoolean() == b.asBoolean()) return .eq;
        return if (!a.asBoolean()) .lt else .gt;
    }

    // numeric: int/float cross-comparison
    if ((a.tag() == .integer or a.tag() == .float) and (b.tag() == .integer or b.tag() == .float)) {
        const fa: f64 = if (a.tag() == .integer) @floatFromInt(a.asInteger()) else a.asFloat();
        const fb: f64 = if (b.tag() == .integer) @floatFromInt(b.asInteger()) else b.asFloat();
        return std.math.order(fa, fb);
    }

    // chars: compare by code point
    if (a.tag() == .char and b.tag() == .char) {
        return std.math.order(a.asChar(), b.asChar());
    }

    // strings
    if (a.tag() == .string and b.tag() == .string) {
        return std.mem.order(u8, a.asString(), b.asString());
    }

    // keywords: compare by namespace then name
    if (a.tag() == .keyword and b.tag() == .keyword) {
        const ans = a.asKeyword().ns orelse "";
        const bns = b.asKeyword().ns orelse "";
        const ns_ord = std.mem.order(u8, ans, bns);
        if (ns_ord != .eq) return ns_ord;
        return std.mem.order(u8, a.asKeyword().name, b.asKeyword().name);
    }

    // symbols: compare by namespace then name
    if (a.tag() == .symbol and b.tag() == .symbol) {
        const ans = a.asSymbol().ns orelse "";
        const bns = b.asSymbol().ns orelse "";
        const ns_ord = std.mem.order(u8, ans, bns);
        if (ns_ord != .eq) return ns_ord;
        return std.mem.order(u8, a.asSymbol().name, b.asSymbol().name);
    }

    // vectors: element-by-element comparison
    if (a.tag() == .vector and b.tag() == .vector) {
        const av = a.asVector().items;
        const bv = b.asVector().items;
        const min_len = @min(av.len, bv.len);
        for (0..min_len) |i| {
            const elem_ord = try compareValues(av[i], bv[i]);
            if (elem_ord != .eq) return elem_ord;
        }
        return std.math.order(av.len, bv.len);
    }

    return err.setErrorFmt(.eval, .type_error, .{}, "compare: cannot compare {s} and {s}", .{ @tagName(a.tag()), @tagName(b.tag()) });
}

/// (compare x y) — comparator returning negative, zero, or positive integer.
pub fn compareFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to compare", .{args.len});
    const ord = try compareValues(args[0], args[1]);
    return Value.initInteger(switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

/// (sort coll) or (sort comp coll) — returns a sorted list.
/// With 1 arg: sorts using natural ordering (compare).
/// With 2 args: first arg is comparator function (not yet supported in unit tests).
pub fn sortFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sort", .{args.len});

    // Get the collection (last arg)
    const coll = args[args.len - 1];
    const items = switch (coll.tag()) {
        .list => coll.asList().items,
        .vector => coll.asVector().items,
        .set => coll.asSet().items,
        .nil => @as([]const Value, &.{}),
        .lazy_seq, .cons => try collectSeqItems(allocator, coll),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "sort not supported on {s}", .{@tagName(coll.tag())}),
    };

    // Copy items so we can sort in place
    const sorted = try allocator.alloc(Value, items.len);
    @memcpy(sorted, items);

    if (args.len == 1) {
        // Natural ordering using compareValues
        std.mem.sortUnstable(Value, sorted, {}, struct {
            fn lessThan(_: void, a: Value, b: Value) bool {
                const ord = compareValues(a, b) catch return false;
                return ord == .lt;
            }
        }.lessThan);
    } else {
        // Custom comparator (builtin_fn only in unit tests)
        // For now, only support builtin_fn comparators
        // Full fn_val support requires evaluator context
        return err.setErrorFmt(.eval, .type_error, .{}, "sort with custom comparator not yet supported", .{});
    }

    // Preserve metadata from input collection
    const input_meta: ?*const Value = switch (coll.tag()) {
        .list => coll.asList().meta,
        .vector => coll.asVector().meta,
        .set => coll.asSet().meta,
        else => null,
    };
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = sorted, .meta = input_meta };
    return Value.initList(lst);
}

/// (sort-by keyfn coll) or (sort-by keyfn comp coll) — sort by key extraction.
pub fn sortByFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sort-by", .{args.len});

    const keyfn = args[0];
    const coll = args[args.len - 1];
    const items = switch (coll.tag()) {
        .list => coll.asList().items,
        .vector => coll.asVector().items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "sort-by not supported on {s}", .{@tagName(coll.tag())}),
    };

    if (items.len == 0) {
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = &.{} };
        return Value.initList(lst);
    }

    // Compute keys for each element
    const keys = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        keys[i] = switch (keyfn.tag()) {
            .builtin_fn => try keyfn.asBuiltinFn()(allocator, &.{item}),
            .fn_val, .multi_fn, .keyword => try bootstrap.callFnVal(allocator, keyfn, &.{item}),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "sort-by expects a function as keyfn, got {s}", .{@tagName(keyfn.tag())}),
        };
    }

    // Build index array and sort by keys
    const indices = try allocator.alloc(usize, items.len);
    for (0..items.len) |i| indices[i] = i;

    const SortCtx = struct {
        keys_slice: []const Value,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ord = compareValues(ctx.keys_slice[a], ctx.keys_slice[b]) catch return false;
            return ord == .lt;
        }
    };

    std.mem.sortUnstable(usize, indices, SortCtx{ .keys_slice = keys }, SortCtx.lessThan);

    // Build result list in sorted order
    const sorted = try allocator.alloc(Value, items.len);
    for (indices, 0..) |idx, i| sorted[i] = items[idx];

    // Preserve metadata from input collection
    const input_meta: ?*const Value = switch (coll.tag()) {
        .list => coll.asList().meta,
        .vector => coll.asVector().meta,
        else => null,
    };
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = sorted, .meta = input_meta };
    return Value.initList(lst);
}

/// (zipmap keys vals) — returns a map with keys mapped to corresponding vals.
pub fn zipmapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to zipmap", .{args.len});

    const key_items = try collectSeqItems(allocator, args[0]);
    const val_items = try collectSeqItems(allocator, args[1]);

    const pair_count = @min(key_items.len, val_items.len);
    const entries = try allocator.alloc(Value, pair_count * 2);
    for (0..pair_count) |i| {
        entries[i * 2] = key_items[i];
        entries[i * 2 + 1] = val_items[i];
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries };
    return Value.initMap(new_map);
}

/// Realize a lazy_seq/cons value into a PersistentList.
/// Non-sequential values are returned as-is.
/// Used by eqFn and print builtins for transparent lazy seq support.
pub fn realizeValue(allocator: Allocator, val: Value) anyerror!Value {
    if (val.tag() != .lazy_seq and val.tag() != .cons) return val;
    const items = try collectSeqItems(allocator, val);
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value.initList(lst);
}

/// Collect all items from a seq-like value (list, vector, cons, lazy_seq)
/// into a flat slice. Handles cons chains and lazy realization.
pub fn collectSeqItems(allocator: Allocator, val: Value) anyerror![]const Value {
    var items: std.ArrayList(Value) = .empty;
    var current = val;
    while (true) {
        switch (current.tag()) {
            .cons => {
                const c = current.asCons();
                try items.append(allocator, c.first);
                current = c.rest;
            },
            .lazy_seq => {
                current = try current.asLazySeq().realize(allocator);
            },
            .list => {
                for (current.asList().items) |item| try items.append(allocator, item);
                break;
            },
            .vector => {
                for (current.asVector().items) |item| try items.append(allocator, item);
                break;
            },
            .set => {
                for (current.asSet().items) |item| try items.append(allocator, item);
                break;
            },
            .map => {
                const m = current.asMap();
                var i: usize = 0;
                while (i < m.entries.len) : (i += 2) {
                    const pair = try allocator.alloc(Value, 2);
                    pair[0] = m.entries[i];
                    pair[1] = m.entries[i + 1];
                    const vec = try allocator.create(PersistentVector);
                    vec.* = .{ .items = pair };
                    try items.append(allocator, Value.initVector(vec));
                }
                break;
            },
            .hash_map => {
                const flat = try current.asHashMap().toEntries(allocator);
                var i: usize = 0;
                while (i < flat.len) : (i += 2) {
                    const pair = try allocator.alloc(Value, 2);
                    pair[0] = flat[i];
                    pair[1] = flat[i + 1];
                    const vec = try allocator.create(PersistentVector);
                    vec.* = .{ .items = pair };
                    try items.append(allocator, Value.initVector(vec));
                }
                break;
            },
            .string => {
                const s = current.asString();
                var i: usize = 0;
                while (i < s.len) {
                    const cl = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                    const cp = std.unicode.utf8Decode(s[i..][0..cl]) catch s[i];
                    try items.append(allocator, Value.initChar(cp));
                    i += cl;
                }
                break;
            },
            .array => {
                const arr = current.asArray();
                for (arr.items) |item| try items.append(allocator, item);
                break;
            },
            .nil => break,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "don't know how to create seq from {s}", .{@tagName(current.tag())}),
        }
    }
    return items.toOwnedSlice(allocator);
}

/// (vec coll) — coerce a collection to a vector.
pub fn vecFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vec", .{args.len});
    if (args[0].tag() == .vector) return args[0];
    const items = try collectSeqItems(allocator, args[0]);
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (set coll) — coerce a collection to a set (removing duplicates).
pub fn setCoerceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set", .{args.len});

    // Handle lazy_seq: realize then recurse
    if (args[0].tag() == .lazy_seq) {
        const realized = try args[0].asLazySeq().realize(allocator);
        const realized_args = [1]Value{realized};
        return setCoerceFn(allocator, &realized_args);
    }

    // Handle cons: walk chain and collect items
    if (args[0].tag() == .cons) {
        var result = std.ArrayList(Value).empty;
        var current = args[0];
        while (true) {
            if (current.tag() == .cons) {
                const item = current.asCons().first;
                var dup = false;
                for (result.items) |existing| {
                    if (existing.eql(item)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try result.append(allocator, item);
                current = current.asCons().rest;
            } else if (current.tag() == .lazy_seq) {
                current = try current.asLazySeq().realize(allocator);
            } else if (current == Value.nil_val) {
                break;
            } else if (current.tag() == .list) {
                for (current.asList().items) |item| {
                    var dup = false;
                    for (result.items) |existing| {
                        if (existing.eql(item)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) try result.append(allocator, item);
                }
                break;
            } else {
                break;
            }
        }
        const new_set = try allocator.create(PersistentHashSet);
        new_set.* = .{ .items = result.items };
        return Value.initSet(new_set);
    }

    // Handle map: convert to set of [k v] vectors
    if (args[0].tag() == .map or args[0].tag() == .hash_map) {
        const flat: []const Value = if (args[0].tag() == .map)
            args[0].asMap().entries
        else
            try args[0].asHashMap().toEntries(allocator);
        const n = flat.len / 2;
        if (n == 0) {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{} };
            return Value.initSet(new_set);
        }
        var result = std.ArrayList(Value).empty;
        var i: usize = 0;
        while (i < flat.len) : (i += 2) {
            const pair = try allocator.alloc(Value, 2);
            pair[0] = flat[i];
            pair[1] = flat[i + 1];
            const vec = try allocator.create(PersistentVector);
            vec.* = .{ .items = pair };
            try result.append(allocator, Value.initVector(vec));
        }
        const new_set = try allocator.create(PersistentHashSet);
        new_set.* = .{ .items = result.items };
        return Value.initSet(new_set);
    }

    // Handle string: convert to set of characters
    if (args[0].tag() == .string) {
        const s = args[0].asString();
        if (s.len == 0) {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{} };
            return Value.initSet(new_set);
        }
        var result = std.ArrayList(Value).empty;
        for (s) |c| {
            const char_val = Value.initChar(c);
            // Deduplicate
            var dup = false;
            for (result.items) |existing| {
                if (existing.eql(char_val)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try result.append(allocator, char_val);
        }
        const new_set = try allocator.create(PersistentHashSet);
        new_set.* = .{ .items = result.items };
        return Value.initSet(new_set);
    }

    const items = switch (args[0].tag()) {
        .set => return args[0], // already a set
        .list => args[0].asList().items,
        .vector => args[0].asVector().items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "set not supported on {s}", .{@tagName(args[0].tag())}),
    };

    // Deduplicate
    var result = std.ArrayList(Value).empty;
    for (items) |item| {
        var dup = false;
        for (result.items) |existing| {
            if (existing.eql(item)) {
                dup = true;
                break;
            }
        }
        if (!dup) try result.append(allocator, item);
    }

    const new_set = try allocator.create(PersistentHashSet);
    new_set.* = .{ .items = result.items };
    return Value.initSet(new_set);
}

/// (list* args... coll) — creates a list with args prepended to the final collection.
pub fn listStarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to list*", .{args.len});
    if (args.len == 1) {
        // (list* coll) — just return as seq
        return switch (args[0].tag()) {
            .list => args[0],
            .vector => blk: {
                const lst = try allocator.create(PersistentList);
                lst.* = .{ .items = args[0].asVector().items };
                break :blk Value.initList(lst);
            },
            .nil => Value.nil_val,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "list* not supported on {s}", .{@tagName(args[0].tag())}),
        };
    }

    // Last arg is the tail collection
    const tail_items = switch (args[args.len - 1].tag()) {
        .list => args[args.len - 1].asList().items,
        .vector => args[args.len - 1].asVector().items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "list* expects a collection as last arg, got {s}", .{@tagName(args[args.len - 1].tag())}),
    };

    const prefix_count = args.len - 1;
    const total = prefix_count + tail_items.len;
    const new_items = try allocator.alloc(Value, total);
    @memcpy(new_items[0..prefix_count], args[0..prefix_count]);
    @memcpy(new_items[prefix_count..], tail_items);

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value.initList(lst);
}

/// (dissoc map key & ks) — remove key(s) from map.
pub fn dissocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to dissoc", .{args.len});
    if (args.len == 1) {
        // (dissoc map) — identity
        return switch (args[0].tag()) {
            .map, .hash_map => args[0],
            .nil => Value.nil_val,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "dissoc expects a map, got {s}", .{@tagName(args[0].tag())}),
        };
    }

    // Handle hash_map case — use HAMT dissoc directly
    if (args[0].tag() == .hash_map) {
        var hm = args[0].asHashMap();
        var ki: usize = 1;
        while (ki < args.len) : (ki += 1) {
            hm = try hm.dissoc(allocator, args[ki]);
        }
        return Value.initHashMap(hm);
    }

    const base_entries = switch (args[0].tag()) {
        .map => args[0].asMap().entries,
        .nil => return Value.nil_val,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "dissoc expects a map, got {s}", .{@tagName(args[0].tag())}),
    };

    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, base_entries);

    // Remove each key
    var ki: usize = 1;
    while (ki < args.len) : (ki += 1) {
        const key = args[ki];
        var j: usize = 0;
        while (j < entries.items.len) {
            if (entries.items[j].eql(key)) {
                // Remove k-v pair (j and j+1)
                _ = entries.orderedRemove(j);
                _ = entries.orderedRemove(j);
            } else {
                j += 2;
            }
        }
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = if (args[0].tag() == .map) args[0].asMap().meta else null, .comparator = if (args[0].tag() == .map) args[0].asMap().comparator else null };
    return Value.initMap(new_map);
}

/// (disj set val & vals) — remove value(s) from set.
pub fn disjFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to disj", .{args.len});
    if (args.len == 1) {
        return switch (args[0].tag()) {
            .set => args[0],
            .nil => Value.nil_val,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "disj expects a set, got {s}", .{@tagName(args[0].tag())}),
        };
    }
    const base_items = switch (args[0].tag()) {
        .set => args[0].asSet().items,
        .nil => return Value.nil_val,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "disj expects a set, got {s}", .{@tagName(args[0].tag())}),
    };

    var items = std.ArrayList(Value).empty;
    try items.appendSlice(allocator, base_items);

    var ki: usize = 1;
    while (ki < args.len) : (ki += 1) {
        const val = args[ki];
        var j: usize = 0;
        while (j < items.items.len) {
            if (items.items[j].eql(val)) {
                _ = items.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }

    const new_set = try allocator.create(PersistentHashSet);
    new_set.* = .{ .items = items.items, .meta = if (args[0].tag() == .set) args[0].asSet().meta else null, .comparator = if (args[0].tag() == .set) args[0].asSet().comparator else null };
    return Value.initSet(new_set);
}

/// (find map key) — returns [key value] (MapEntry) or nil.
pub fn findFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find", .{args.len});
    return switch (args[0].tag()) {
        .map => {
            const v = args[0].asMap().get(args[1]) orelse return Value.nil_val;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = v;
            const vec = try allocator.create(PersistentVector);
            vec.* = .{ .items = pair };
            return Value.initVector(vec);
        },
        .hash_map => {
            const v = args[0].asHashMap().get(args[1]) orelse return Value.nil_val;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = v;
            const vec = try allocator.create(PersistentVector);
            vec.* = .{ .items = pair };
            return Value.initVector(vec);
        },
        .vector => {
            if (args[1].tag() != .integer) return Value.nil_val;
            const idx = args[1].asInteger();
            if (idx < 0 or @as(usize, @intCast(idx)) >= args[0].asVector().items.len) return Value.nil_val;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = args[0].asVector().items[@intCast(idx)];
            const v = try allocator.create(PersistentVector);
            v.* = .{ .items = pair };
            return Value.initVector(v);
        },
        .transient_vector => {
            const tv = args[0].asTransientVector();
            if (args[1].tag() != .integer) return Value.nil_val;
            const idx = args[1].asInteger();
            if (idx < 0 or @as(usize, @intCast(idx)) >= tv.items.items.len) return Value.nil_val;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = tv.items.items[@intCast(idx)];
            const v = try allocator.create(PersistentVector);
            v.* = .{ .items = pair };
            return Value.initVector(v);
        },
        .transient_map => {
            const tm = args[0].asTransientMap();
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) {
                    const pair = try allocator.alloc(Value, 2);
                    pair[0] = args[1];
                    pair[1] = tm.entries.items[i + 1];
                    const v = try allocator.create(PersistentVector);
                    v.* = .{ .items = pair };
                    return Value.initVector(v);
                }
            }
            return Value.nil_val;
        },
        .nil => Value.nil_val,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "find expects a map or vector, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (peek coll) — stack top: last of vector, first of list.
pub fn peekFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to peek", .{args.len});
    return switch (args[0].tag()) {
        .vector => if (args[0].asVector().items.len > 0) args[0].asVector().items[args[0].asVector().items.len - 1] else Value.nil_val,
        .list => if (args[0].asList().items.len > 0) args[0].asList().items[0] else Value.nil_val,
        .nil => Value.nil_val,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "peek not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (pop coll) — stack pop: vector without last, list without first.
pub fn popFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop", .{args.len});
    return switch (args[0].tag()) {
        .vector => {
            const vec = args[0].asVector();
            if (vec.items.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Can't pop empty vector", .{});
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = vec.items[0 .. vec.items.len - 1], .meta = vec.meta };
            return Value.initVector(new_vec);
        },
        .list => {
            const lst = args[0].asList();
            if (lst.items.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Can't pop empty list", .{});
            const new_lst = try allocator.create(PersistentList);
            new_lst.* = .{ .items = lst.items[1..], .meta = lst.meta };
            return Value.initList(new_lst);
        },
        .nil => return Value.nil_val,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "pop not supported on {s}", .{@tagName(args[0].tag())}),
    };
}

/// (subvec v start) or (subvec v start end) — returns a subvector of v from start (inclusive) to end (exclusive).
pub fn subvecFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subvec", .{args.len});
    if (args[0].tag() != .vector) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects a vector, got {s}", .{@tagName(args[0].tag())});
    if (args[1].tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects integer start, got {s}", .{@tagName(args[1].tag())});
    const v = args[0].asVector();
    const start: usize = if (args[1].asInteger() < 0) return err.setErrorFmt(.eval, .index_error, .{}, "subvec start index out of bounds: {d}", .{args[1].asInteger()}) else @intCast(args[1].asInteger());
    const end: usize = if (args.len == 3) blk: {
        if (args[2].tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects integer end, got {s}", .{@tagName(args[2].tag())});
        break :blk if (args[2].asInteger() < 0) return err.setErrorFmt(.eval, .index_error, .{}, "subvec end index out of bounds: {d}", .{args[2].asInteger()}) else @intCast(args[2].asInteger());
    } else v.items.len;

    if (start > end or end > v.items.len) return err.setErrorFmt(.eval, .index_error, .{}, "subvec index out of bounds: start={d}, end={d}, size={d}", .{ start, end, v.items.len });
    const result = try allocator.create(PersistentVector);
    result.* = .{ .items = try allocator.dupe(Value, v.items[start..end]) };
    return Value.initVector(result);
}

/// (array-map & kvs) — creates an array map from key-value pairs.
/// Like hash-map but guarantees insertion order (which our PersistentArrayMap already preserves).
pub fn arrayMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "array-map requires even number of args, got {d}", .{args.len});
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value.initMap(map);
}

/// (hash-set & vals) — creates a set from the given values, deduplicating.
pub fn hashSetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    // Deduplicate: build list of unique items
    var items = std.ArrayList(Value).empty;
    for (args) |arg| {
        var found = false;
        for (items.items) |existing| {
            if (existing.eql(arg)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try items.append(allocator, arg);
        }
    }
    const set = try allocator.create(PersistentHashSet);
    set.* = .{ .items = try allocator.dupe(Value, items.items) };
    items.deinit(allocator);
    return Value.initSet(set);
}

/// (sorted-set & vals) — creates a sorted set with natural ordering.
pub fn sortedSetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    // Deduplicate
    var items = std.ArrayList(Value).empty;
    for (args) |arg| {
        var found = false;
        for (items.items) |existing| {
            if (existing.eql(arg)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try items.append(allocator, arg);
        }
    }
    // Sort with natural ordering
    if (items.items.len > 1) try sortSetItems(allocator, items.items, Value.nil_val);
    const set = try allocator.create(PersistentHashSet);
    set.* = .{ .items = try allocator.dupe(Value, items.items), .comparator = Value.nil_val };
    items.deinit(allocator);
    return Value.initSet(set);
}

/// (sorted-set-by comp & vals) — creates a sorted set with custom comparator.
pub fn sortedSetByFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "sorted-set-by requires a comparator", .{});
    const comp = args[0];
    const vals = args[1..];
    // Deduplicate
    var items = std.ArrayList(Value).empty;
    for (vals) |arg| {
        var found = false;
        for (items.items) |existing| {
            if (existing.eql(arg)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try items.append(allocator, arg);
        }
    }
    // Sort with custom comparator
    if (items.items.len > 1) try sortSetItems(allocator, items.items, comp);
    const set = try allocator.create(PersistentHashSet);
    set.* = .{ .items = try allocator.dupe(Value, items.items), .comparator = comp };
    items.deinit(allocator);
    return Value.initSet(set);
}

/// (sorted-map & kvs) — creates a map with entries sorted by key.
/// Uses natural ordering (compareValues). Stores comparator=.nil for natural ordering.
pub fn sortedMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "sorted-map requires even number of args, got {d}", .{args.len});
    if (args.len == 0) {
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = &.{}, .comparator = Value.nil_val };
        return Value.initMap(map);
    }
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);

    try sortMapEntries(allocator, entries, Value.nil_val);

    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries, .comparator = Value.nil_val };
    return Value.initMap(map);
}

/// (sorted-map-by comp & kvs) — creates a map sorted by custom comparator.
/// comp is a fn of 2 args returning negative/zero/positive.
pub fn sortedMapByFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "sorted-map-by requires a comparator", .{});
    const comp = args[0];
    const kvs = args[1..];
    if (kvs.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "sorted-map-by requires even number of key-value args, got {d}", .{kvs.len});
    if (kvs.len == 0) {
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = &.{}, .comparator = comp };
        return Value.initMap(map);
    }
    const entries = try allocator.alloc(Value, kvs.len);
    @memcpy(entries, kvs);

    try sortMapEntries(allocator, entries, comp);

    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries, .comparator = comp };
    return Value.initMap(map);
}

/// Sort map entries (flat [k1,v1,k2,v2,...]) using comparator.
/// comparator=.nil means natural ordering; otherwise call as Clojure fn.
fn sortMapEntries(allocator: Allocator, entries: []Value, comparator: Value) anyerror!void {
    const n_pairs = entries.len / 2;
    // Insertion sort (stable, simple for small maps)
    var i: usize = 1;
    while (i < n_pairs) : (i += 1) {
        const key_i = entries[i * 2];
        const val_i = entries[i * 2 + 1];
        var j: usize = i;
        while (j > 0) {
            const ord = try compareWithComparator(allocator, comparator, entries[(j - 1) * 2], key_i);
            if (ord != .gt) break;
            entries[j * 2] = entries[(j - 1) * 2];
            entries[j * 2 + 1] = entries[(j - 1) * 2 + 1];
            j -= 1;
        }
        entries[j * 2] = key_i;
        entries[j * 2 + 1] = val_i;
    }
}

/// Sort set items using comparator.
fn sortSetItems(allocator: Allocator, items: []Value, comparator: Value) anyerror!void {
    // Insertion sort
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item_i = items[i];
        var j: usize = i;
        while (j > 0) {
            const ord = try compareWithComparator(allocator, comparator, items[j - 1], item_i);
            if (ord != .gt) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = item_i;
    }
}

/// Compare two values using a comparator.
/// .nil = natural ordering (compareValues), otherwise call as Clojure fn.
/// Boolean comparators follow JVM AFunction.compare() semantics:
///   (comp a b) → true  ⇒ -1 (a before b)
///   (comp a b) → false ⇒ check (comp b a): true → 1 (b before a), false → 0 (equal)
fn compareWithComparator(allocator: Allocator, comparator: Value, a: Value, b: Value) anyerror!std.math.Order {
    if (comparator == Value.nil_val) {
        return compareValues(a, b);
    }
    // Custom comparator: call as Clojure function
    const result = try bootstrap.callFnVal(allocator, comparator, &.{ a, b });
    const n: i64 = switch (result.tag()) {
        .integer => result.asInteger(),
        .float => @intFromFloat(result.asFloat()),
        .boolean => {
            if (result.asBoolean()) return .lt;
            // JVM AFunction.compare: false → call (comp b a) to distinguish gt from eq
            const rev = try bootstrap.callFnVal(allocator, comparator, &.{ b, a });
            return if (rev.tag() == .boolean and rev.asBoolean()) .gt else .eq;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "comparator must return a number, got {s}", .{@tagName(result.tag())}),
    };
    if (n < 0) return .lt;
    if (n > 0) return .gt;
    return .eq;
}

/// (subseq sc test key) or (subseq sc start-test start-key end-test end-key)
/// Returns a seq of entries from sorted collection matching test(s).
pub fn subseqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3 and args.len != 5)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subseq", .{args.len});
    return subseqImpl(allocator, args, false);
}

/// (rsubseq sc test key) or (rsubseq sc start-test start-key end-test end-key)
/// Returns a reverse seq of entries from sorted collection matching test(s).
pub fn rsubseqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3 and args.len != 5)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rsubseq", .{args.len});
    return subseqImpl(allocator, args, true);
}

/// Shared implementation for subseq and rsubseq.
fn subseqImpl(allocator: Allocator, args: []const Value, reverse: bool) anyerror!Value {
    const sc = args[0];

    // Get comparator — must be sorted collection
    const comp: Value = switch (sc.tag()) {
        .map => sc.asMap().comparator orelse return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection", .{}),
        .set => sc.asSet().comparator orelse return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection", .{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection, got {s}", .{@tagName(sc.tag())}),
    };

    var result = std.ArrayList(Value).empty;

    if (sc.tag() == .map) {
        const entries = sc.asMap().entries;
        var i: usize = 0;
        while (i < entries.len) : (i += 2) {
            const entry_key = entries[i];
            if (try testEntry(allocator, comp, entry_key, args)) {
                // Create [key val] vector
                const pair = try allocator.alloc(Value, 2);
                pair[0] = entries[i];
                pair[1] = entries[i + 1];
                const vec = try allocator.create(PersistentVector);
                vec.* = .{ .items = pair };
                try result.append(allocator, Value.initVector(vec));
            }
        }
    } else {
        // set
        const items = sc.asSet().items;
        for (items) |item| {
            if (try testEntry(allocator, comp, item, args)) {
                try result.append(allocator, item);
            }
        }
    }
    if (result.items.len == 0) return Value.nil_val;

    if (reverse) {
        // Reverse in place
        var lo: usize = 0;
        var hi: usize = result.items.len - 1;
        while (lo < hi) {
            const tmp = result.items[lo];
            result.items[lo] = result.items[hi];
            result.items[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }

    const list = try allocator.create(PersistentList);
    list.* = .{ .items = result.items };
    return Value.initList(list);
}

/// Test whether an entry key passes the subseq test(s).
/// For 3-arg: (test (compare entry-key key) 0)
/// For 5-arg: (start-test (compare entry-key start-key) 0) AND (end-test (compare entry-key end-key) 0)
fn testEntry(allocator: Allocator, comp: Value, entry_key: Value, args: []const Value) anyerror!bool {
    const zero = Value.initInteger(0);

    if (args.len == 3) {
        const test_fn = args[1];
        const key = args[2];
        const cmp = try compareWithComparator(allocator, comp, entry_key, key);
        const cmp_int = Value.initInteger(switch (cmp) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
        const test_result = try bootstrap.callFnVal(allocator, test_fn, &.{ cmp_int, zero });
        return isTruthy(test_result);
    } else {
        // 5 args: sc start-test start-key end-test end-key
        const start_test = args[1];
        const start_key = args[2];
        const end_test = args[3];
        const end_key = args[4];

        const cmp_start = try compareWithComparator(allocator, comp, entry_key, start_key);
        const cmp_start_int = Value.initInteger(switch (cmp_start) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
        const start_result = try bootstrap.callFnVal(allocator, start_test, &.{ cmp_start_int, zero });
        if (!isTruthy(start_result)) return false;

        const cmp_end = try compareWithComparator(allocator, comp, entry_key, end_key);
        const cmp_end_int = Value.initInteger(switch (cmp_end) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
        const end_result = try bootstrap.callFnVal(allocator, end_test, &.{ cmp_end_int, zero });
        return isTruthy(end_result);
    }
}

fn isTruthy(v: Value) bool {
    return switch (v.tag()) {
        .nil => false,
        .boolean => v.asBoolean(),
        else => true,
    };
}

/// (empty coll) — empty collection of same type, or nil.
pub fn emptyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to empty", .{args.len});
    return switch (args[0].tag()) {
        .vector => blk: {
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = &.{}, .meta = args[0].asVector().meta };
            break :blk Value.initVector(new_vec);
        },
        .list => blk: {
            const new_lst = try allocator.create(PersistentList);
            new_lst.* = .{ .items = &.{}, .meta = args[0].asList().meta };
            break :blk Value.initList(new_lst);
        },
        .map => blk: {
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = &.{}, .meta = args[0].asMap().meta, .comparator = args[0].asMap().comparator };
            break :blk Value.initMap(new_map);
        },
        .hash_map => blk: {
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = &.{}, .meta = args[0].asHashMap().meta };
            break :blk Value.initMap(new_map);
        },
        .set => blk: {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{}, .meta = args[0].asSet().meta, .comparator = args[0].asSet().comparator };
            break :blk Value.initSet(new_set);
        },
        .nil => Value.nil_val,
        else => Value.nil_val,
    };
}

// ============================================================
// BuiltinDef table
// ============================================================

// ============================================================
// Zig builtins for nested map operations (24C.9)
// ============================================================
//
// get-in, assoc-in, update-in are implemented as Zig builtins that traverse
// the path and rebuild the map structure in a single function, eliminating
// per-level VM frame overhead. The Clojure versions require a recursive
// function call per path segment, each pushing a new VM frame (~1KB).
//
// For a path of depth 3, the Clojure version pushes 3 VM frames with
// associated stack manipulation; the Zig version does the same work in
// a single native call with direct Zig recursion.
//
// Impact: nested_update 39ms -> 23ms (1.7x).

/// Helper: extract path items from a value as a slice.
/// Vectors and lists provide zero-copy access to their backing arrays;
/// other seq types are materialized into a temporary slice.
fn getPathItems(allocator: Allocator, ks: Value) anyerror![]const Value {
    return switch (ks.tag()) {
        .vector => ks.asVector().items,
        .list => ks.asList().items,
        else => {
            // Realize seq into slice
            var items = std.ArrayList(Value).empty;
            var s = try seqFn(allocator, &[1]Value{ks});
            while (s != Value.nil_val) {
                try items.append(allocator, try firstFn(allocator, &[1]Value{s}));
                s = try restFn(allocator, &[1]Value{s});
                s = try seqFn(allocator, &[1]Value{s});
            }
            return items.items;
        },
    };
}

/// (__zig-get-in m ks) or (__zig-get-in m ks not-found)
fn zigGetInFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to get-in", .{args.len});
    const not_found: Value = if (args.len == 3) args[2] else Value.nil_val;
    const path = try getPathItems(allocator, args[1]);
    var current = args[0];
    for (path) |k| {
        current = getFn(allocator, &[2]Value{ current, k }) catch return not_found;
        if (current == Value.nil_val and not_found != Value.nil_val) {
            // Check if key actually maps to nil vs key not found
            // For simplicity, treat nil as "not found" when not-found is provided
        }
    }
    return current;
}

/// (__zig-assoc-in m ks v)
fn zigAssocInFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to assoc-in", .{args.len});
    const path = try getPathItems(allocator, args[1]);
    if (path.len == 0) return args[0];
    return assocInImpl(allocator, args[0], path, args[2]);
}

fn assocInImpl(allocator: Allocator, m: Value, path: []const Value, v: Value) anyerror!Value {
    const k = path[0];
    if (path.len == 1) {
        return assocFn(allocator, &[3]Value{ m, k, v });
    }
    const inner = getFn(allocator, &[2]Value{ m, k }) catch Value.nil_val;
    const new_inner = try assocInImpl(allocator, inner, path[1..], v);
    return assocFn(allocator, &[3]Value{ m, k, new_inner });
}

/// (__zig-update-in m ks f) or (__zig-update-in m ks f & args)
fn zigUpdateInFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to update-in", .{args.len});
    const path = try getPathItems(allocator, args[1]);
    if (path.len == 0) return args[0];
    const f = args[2];
    const extra_args = if (args.len > 3) args[3..] else &[0]Value{};
    return updateInImpl(allocator, args[0], path, f, extra_args);
}

fn updateInImpl(allocator: Allocator, m: Value, path: []const Value, f: Value, extra_args: []const Value) anyerror!Value {
    const k = path[0];
    if (path.len == 1) {
        const old_val = getFn(allocator, &[2]Value{ m, k }) catch Value.nil_val;
        // Call (f old_val extra_args...)
        const new_val = if (extra_args.len == 0)
            try bootstrap.callFnVal(allocator, f, &[1]Value{old_val})
        else blk: {
            const call_args = try allocator.alloc(Value, 1 + extra_args.len);
            call_args[0] = old_val;
            @memcpy(call_args[1..], extra_args);
            break :blk try bootstrap.callFnVal(allocator, f, call_args);
        };
        return assocFn(allocator, &[3]Value{ m, k, new_val });
    }
    const inner = getFn(allocator, &[2]Value{ m, k }) catch Value.nil_val;
    const new_inner = try updateInImpl(allocator, inner, path[1..], f, extra_args);
    return assocFn(allocator, &[3]Value{ m, k, new_inner });
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "first",
        .func = &firstFn,
        .doc = "Returns the first item in the collection. Calls seq on its argument. If coll is nil, returns nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "rest",
        .func = &restFn,
        .doc = "Returns a possibly empty seq of the items after the first. Calls seq on its argument.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "cons",
        .func = &consFn,
        .doc = "Returns a new seq where x is the first element and seq is the rest.",
        .arglists = "([x seq])",
        .added = "1.0",
    },
    .{
        .name = "conj",
        .func = &conjFn,
        .doc = "conj[oin]. Returns a new collection with the xs 'added'.",
        .arglists = "([coll x] [coll x & xs])",
        .added = "1.0",
    },
    .{
        .name = "assoc",
        .func = &assocFn,
        .doc = "assoc[iate]. When applied to a map, returns a new map that contains the mapping of key(s) to val(s).",
        .arglists = "([map key val] [map key val & kvs])",
        .added = "1.0",
    },
    .{
        .name = "get",
        .func = &getFn,
        .doc = "Returns the value mapped to key, not-found or nil if key not present.",
        .arglists = "([map key] [map key not-found])",
        .added = "1.0",
    },
    .{
        .name = "nth",
        .func = &nthFn,
        .doc = "Returns the value at the index.",
        .arglists = "([coll index] [coll index not-found])",
        .added = "1.0",
    },
    .{
        .name = "count",
        .func = &countFn,
        .doc = "Returns the number of items in the collection.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "list",
        .func = &listFn,
        .doc = "Creates a new list containing the items.",
        .arglists = "([& items])",
        .added = "1.0",
    },
    .{
        .name = "seq",
        .func = &seqFn,
        .doc = "Returns a seq on the collection. If the collection is empty, returns nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "concat",
        .func = &concatFn,
        .doc = "Returns a lazy seq representing the concatenation of the elements in the supplied colls.",
        .arglists = "([] [x] [x y] [x y & zs])",
        .added = "1.0",
    },
    .{
        .name = "reverse",
        .func = &reverseFn,
        .doc = "Returns a seq of the items in coll in reverse order.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "into",
        .func = &intoFn,
        .doc = "Returns a new coll consisting of to-coll with all of the items of from-coll conjoined.",
        .arglists = "([to from])",
        .added = "1.0",
    },
    .{
        .name = "apply",
        .func = &applyFn,
        .doc = "Applies fn f to the argument list formed by prepending intervening arguments to args.",
        .arglists = "([f args] [f x args] [f x y args] [f x y z args])",
        .added = "1.0",
    },
    .{
        .name = "vector",
        .func = &vectorFn,
        .doc = "Creates a new vector containing the args.",
        .arglists = "([& args])",
        .added = "1.0",
    },
    .{
        .name = "hash-map",
        .func = &hashMapFn,
        .doc = "Returns a new hash map with supplied mappings.",
        .arglists = "([& keyvals])",
        .added = "1.0",
    },
    .{
        .name = "merge",
        .func = &mergeFn,
        .doc = "Returns a map that consists of the rest of the maps conj-ed onto the first. If a key occurs in more than one map, the mapping from the latter will be the mapping in the result.",
        .arglists = "([& maps])",
        .added = "1.0",
    },
    .{
        .name = "merge-with",
        .func = &mergeWithFn,
        .doc = "Returns a map that consists of the rest of the maps conj-ed onto the first. If a key occurs in more than one map, the mapping(s) from the latter will be combined with the mapping in the result by calling (f val-in-result val-in-latter).",
        .arglists = "([f & maps])",
        .added = "1.0",
    },
    .{
        .name = "zipmap",
        .func = &zipmapFn,
        .doc = "Returns a map with the keys mapped to the corresponding vals.",
        .arglists = "([keys vals])",
        .added = "1.0",
    },
    .{
        .name = "compare",
        .func = &compareFn,
        .doc = "Comparator. Returns a negative number, zero, or a positive number when x is logically 'less than', 'equal to', or 'greater than' y.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "sort",
        .func = &sortFn,
        .doc = "Returns a sorted sequence of the items in coll.",
        .arglists = "([coll] [comp coll])",
        .added = "1.0",
    },
    .{
        .name = "sort-by",
        .func = &sortByFn,
        .doc = "Returns a sorted sequence of the items in coll, where the sort order is determined by comparing (keyfn item).",
        .arglists = "([keyfn coll] [keyfn comp coll])",
        .added = "1.0",
    },
    .{
        .name = "vec",
        .func = &vecFn,
        .doc = "Creates a new vector containing the contents of coll.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "set",
        .func = &setCoerceFn,
        .doc = "Returns a set of the distinct elements of coll.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "list*",
        .func = &listStarFn,
        .doc = "Creates a new seq containing the items prepended to the rest, the last of which will be treated as a sequence.",
        .arglists = "([args] [a args] [a b args] [a b c args])",
        .added = "1.0",
    },
    .{
        .name = "dissoc",
        .func = &dissocFn,
        .doc = "dissoc[iate]. Returns a new map of the same (hashed/sorted) type, that does not contain a mapping for key(s).",
        .arglists = "([map] [map key] [map key & ks])",
        .added = "1.0",
    },
    .{
        .name = "disj",
        .func = &disjFn,
        .doc = "disj[oin]. Returns a new set of the same (hashed/sorted) type, that does not contain key(s).",
        .arglists = "([set] [set key] [set key & ks])",
        .added = "1.0",
    },
    .{
        .name = "find",
        .func = &findFn,
        .doc = "Returns the map entry for key, or nil if key not present.",
        .arglists = "([map key])",
        .added = "1.0",
    },
    .{
        .name = "peek",
        .func = &peekFn,
        .doc = "For a list or queue, same as first, for a vector, same as, but much more efficient than, last. If the collection is empty, returns nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "pop",
        .func = &popFn,
        .doc = "For a list or queue, returns a new list/queue without the first item, for a vector, returns a new vector without the last item.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "empty",
        .func = &emptyFn,
        .doc = "Returns an empty collection of the same category as coll, or nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "subvec",
        .func = &subvecFn,
        .doc = "Returns a persistent vector of the items in vector from start (inclusive) to end (exclusive). If end is not supplied, defaults to (count vector).",
        .arglists = "([v start] [v start end])",
        .added = "1.0",
    },
    .{
        .name = "array-map",
        .func = &arrayMapFn,
        .doc = "Constructs an array-map. If any keys are equal, they are handled as if by repeated uses of assoc.",
        .arglists = "([& keyvals])",
        .added = "1.0",
    },
    .{
        .name = "hash-set",
        .func = &hashSetFn,
        .doc = "Returns a new hash set with supplied keys. Any equal keys are handled as if by repeated uses of conj.",
        .arglists = "([& keys])",
        .added = "1.0",
    },
    .{
        .name = "sorted-set",
        .func = &sortedSetFn,
        .doc = "Returns a new sorted set with supplied keys.",
        .arglists = "([& keys])",
        .added = "1.0",
    },
    .{
        .name = "sorted-map",
        .func = &sortedMapFn,
        .doc = "keyval => key val. Returns a new sorted map with supplied mappings.",
        .arglists = "([& keyvals])",
        .added = "1.0",
    },
    .{
        .name = "sorted-map-by",
        .func = &sortedMapByFn,
        .doc = "keyval => key val. Returns a new sorted map with supplied mappings, using the supplied comparator.",
        .arglists = "([comparator & keyvals])",
        .added = "1.0",
    },
    .{
        .name = "sorted-set-by",
        .func = &sortedSetByFn,
        .doc = "Returns a new sorted set with supplied keys, using the supplied comparator.",
        .arglists = "([comparator & keys])",
        .added = "1.1",
    },
    .{
        .name = "subseq",
        .func = &subseqFn,
        .doc = "sc must be a sorted collection, test(s) one of <, <=, > or >=. Returns a seq of those entries with keys ek for which (test (.. sc comparator (compare ek key)) 0) is true.",
        .arglists = "([sc test key] [sc start-test start-key end-test end-key])",
        .added = "1.0",
    },
    .{
        .name = "rsubseq",
        .func = &rsubseqFn,
        .doc = "sc must be a sorted collection, test(s) one of <, <=, > or >=. Returns a reverse seq of those entries with keys ek for which (test (.. sc comparator (compare ek key)) 0) is true.",
        .arglists = "([sc test key] [sc start-test start-key end-test end-key])",
        .added = "1.0",
    },
    .{
        .name = "rseq",
        .func = &rseqFn,
        .doc = "Returns, in constant time, a seq of the items in rev (which can be a vector), in reverse order. If rev is empty returns nil.",
        .arglists = "([rev])",
        .added = "1.0",
    },
    .{
        .name = "shuffle",
        .func = &shuffleFn,
        .doc = "Returns a random permutation of coll.",
        .arglists = "([coll])",
        .added = "1.2",
    },
    .{
        .name = "__seq-to-map",
        .func = &seqToMapFn,
        .doc = "Coerces seq to map for map destructuring.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "seq-to-map-for-destructuring",
        .func = &seqToMapFn,
        .doc = "Builds a map from a seq as described in https://clojure.org/reference/special_forms#keyword-arguments",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "__zig-get-in",
        .func = &zigGetInFn,
        .doc = "Fast Zig builtin for get-in.",
        .arglists = "([m ks] [m ks not-found])",
        .added = "1.0",
    },
    .{
        .name = "__zig-assoc-in",
        .func = &zigAssocInFn,
        .doc = "Fast Zig builtin for assoc-in.",
        .arglists = "([m ks v])",
        .added = "1.0",
    },
    .{
        .name = "__zig-update-in",
        .func = &zigUpdateInFn,
        .doc = "Fast Zig builtin for update-in.",
        .arglists = "([m ks f] [m ks f & args])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

/// Simple addition for testing merge-with.
fn testAddFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].tag() != .integer or args[1].tag() != .integer) return error.TypeError;
    return Value.initInteger(args[0].asInteger() + args[1].asInteger());
}

test "first on list" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    var lst = PersistentList{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value.initList(&lst)});
    try testing.expect(result.eql(Value.initInteger(1)));
}

test "first on empty list" {
    var lst = PersistentList{ .items = &.{} };
    const result = try firstFn(test_alloc, &.{Value.initList(&lst)});
    try testing.expect(result.isNil());
}

test "first on nil" {
    const result = try firstFn(test_alloc, &.{Value.nil_val});
    try testing.expect(result.isNil());
}

test "first on vector" {
    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20) };
    var vec = PersistentVector{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expect(result.eql(Value.initInteger(10)));
}

test "rest on list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var lst = PersistentList{ .items = &items };
    const result = try restFn(arena.allocator(), &.{Value.initList(&lst)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().count());
}

test "rest on nil returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try restFn(arena.allocator(), &.{Value.nil_val});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 0), result.asList().count());
}

test "cons prepends to list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ Value.initInteger(2), Value.initInteger(3) };
    var lst = PersistentList{ .items = &items };
    const result = try consFn(arena.allocator(), &.{ Value.initInteger(1), Value.initList(&lst) });
    // cons always returns Cons cell (JVM Clojure semantics)
    try testing.expect(result.tag() == .cons);
    try testing.expect(result.asCons().first.eql(Value.initInteger(1)));
    try testing.expect(result.asCons().rest.tag() == .list);
}

test "cons onto nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try consFn(arena.allocator(), &.{ Value.initInteger(1), Value.nil_val });
    // cons onto nil returns Cons cell with nil rest
    try testing.expect(result.tag() == .cons);
    try testing.expect(result.asCons().first.eql(Value.initInteger(1)));
    try testing.expect(result.asCons().rest == Value.nil_val);
}

test "conj to list prepends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ Value.initInteger(2), Value.initInteger(3) };
    var lst = PersistentList{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value.initList(&lst), Value.initInteger(1) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().count());
    try testing.expect(result.asList().first().eql(Value.initInteger(1)));
}

test "conj to vector appends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    var vec = PersistentVector{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value.initVector(&vec), Value.initInteger(3) });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().count());
    try testing.expect(result.asVector().nth(2).?.eql(Value.initInteger(3)));
}

test "conj nil returns list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try conjFn(arena.allocator(), &.{ Value.nil_val, Value.initInteger(1) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 1), result.asList().count());
}

test "assoc adds to map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(alloc, &.{
        Value.initMap(&m),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }),
        Value.initInteger(2),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 2), result.asMap().count());
}

test "assoc replaces existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(alloc, &.{
        Value.initMap(&m),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
        Value.initInteger(99),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 1), result.asMap().count());
    const v = result.asMap().get(Value.initKeyword(alloc, .{ .name = "a", .ns = null }));
    try testing.expect(v.?.eql(Value.initInteger(99)));
}

test "assoc on vector replaces at index" {
    // (assoc [1 2 3] 1 99) => [1 99 3]
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var v = PersistentVector{ .items = &items };
    const result = try assocFn(arena.allocator(), &.{
        Value.initVector(&v),
        Value.initInteger(1),
        Value.initInteger(99),
    });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expect(result.asVector().items[0].eql(Value.initInteger(1)));
    try testing.expect(result.asVector().items[1].eql(Value.initInteger(99)));
    try testing.expect(result.asVector().items[2].eql(Value.initInteger(3)));
}

test "assoc on empty vector at index 0" {
    // (assoc [] 0 4) => [4]
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var v = PersistentVector{ .items = &.{} };
    const result = try assocFn(arena.allocator(), &.{
        Value.initVector(&v),
        Value.initInteger(0),
        Value.initInteger(4),
    });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 1), result.asVector().items.len);
    try testing.expect(result.asVector().items[0].eql(Value.initInteger(4)));
}

test "assoc on vector out of bounds fails" {
    // (assoc [] 1 4) => error (index must be <= count)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var v = PersistentVector{ .items = &.{} };
    const result = assocFn(arena.allocator(), &.{
        Value.initVector(&v),
        Value.initInteger(1),
        Value.initInteger(4),
    });
    try testing.expectError(error.IndexError, result);
}

test "get from map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(alloc, &.{
        Value.initMap(&m),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
    });
    try testing.expect(result.eql(Value.initInteger(1)));
}

test "get missing key returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(alloc, &.{
        Value.initMap(&m),
        Value.initKeyword(alloc, .{ .name = "z", .ns = null }),
    });
    try testing.expect(result.isNil());
}

test "get with not-found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = [_]Value{};
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(alloc, &.{
        Value.initMap(&m),
        Value.initKeyword(alloc, .{ .name = "z", .ns = null }),
        Value.initInteger(-1),
    });
    try testing.expect(result.eql(Value.initInteger(-1)));
}

test "nth on vector" {
    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20), Value.initInteger(30) };
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value.initVector(&vec),
        Value.initInteger(1),
    });
    try testing.expect(result.eql(Value.initInteger(20)));
}

test "nth out of bounds" {
    const items = [_]Value{Value.initInteger(10)};
    var vec = PersistentVector{ .items = &items };
    try testing.expectError(error.IndexError, nthFn(test_alloc, &.{
        Value.initVector(&vec),
        Value.initInteger(5),
    }));
}

test "nth with not-found" {
    const items = [_]Value{Value.initInteger(10)};
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value.initVector(&vec),
        Value.initInteger(5),
        Value.initInteger(-1),
    });
    try testing.expect(result.eql(Value.initInteger(-1)));
}

test "count on various types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    var lst = PersistentList{ .items = &items };
    var vec = PersistentVector{ .items = &items };

    try testing.expectEqual(Value.initInteger(2), try countFn(alloc, &.{Value.initList(&lst)}));
    try testing.expectEqual(Value.initInteger(2), try countFn(alloc, &.{Value.initVector(&vec)}));
    try testing.expectEqual(Value.initInteger(0), try countFn(alloc, &.{Value.nil_val}));
    try testing.expectEqual(Value.initInteger(5), try countFn(alloc, &.{Value.initString(alloc, "hello")}));
}

test "builtins table has 47 entries" {
    // 46 + 1 (seq-to-map-for-destructuring)
    try testing.expectEqual(47, builtins.len);
}

test "reverse list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var lst = PersistentList{ .items = &items };
    const result = try reverseFn(alloc, &.{Value.initList(&lst)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(3), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(1), result.asList().items[2]);
}

test "reverse nil returns empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try reverseFn(arena.allocator(), &.{Value.nil_val});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 0), result.asList().items.len);
}

test "apply with builtin_fn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (apply count [[1 2 3]]) -> 3
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var inner_vec = PersistentVector{ .items = &items };
    const arg_items = [_]Value{Value.initVector(&inner_vec)};
    var arg_list = PersistentList{ .items = &arg_items };
    const result = try applyFn(alloc, &.{
        Value.initBuiltinFn(&countFn),
        Value.initList(&arg_list),
    });
    try testing.expectEqual(Value.initInteger(3), result);
}

test "merge two maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    const result = try mergeFn(alloc, &.{ Value.initMap(&m1), Value.initMap(&m2) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 2), result.asMap().count());
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "a", .ns = null })).?.eql(Value.initInteger(1)));
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "b", .ns = null })).?.eql(Value.initInteger(2)));
}

test "merge with nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };

    // (merge nil {:a 1}) => {:a 1}
    const r1 = try mergeFn(alloc, &.{ Value.nil_val, Value.initMap(&m1) });
    try testing.expect(r1.tag() == .map);
    try testing.expectEqual(@as(usize, 1), r1.asMap().count());

    // (merge {:a 1} nil) => {:a 1}
    const r2 = try mergeFn(alloc, &.{ Value.initMap(&m1), Value.nil_val });
    try testing.expect(r2.tag() == .map);
    try testing.expectEqual(@as(usize, 1), r2.asMap().count());

    // (merge nil nil) => nil
    const r3 = try mergeFn(alloc, &.{ Value.nil_val, Value.nil_val });
    try testing.expect(r3 == Value.nil_val);

    // (merge) => nil
    const r4 = try mergeFn(alloc, &.{});
    try testing.expect(r4 == Value.nil_val);
}

test "merge overlapping keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(99),
        Value.initKeyword(alloc, .{ .name = "c", .ns = null }), Value.initInteger(3),
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    const result = try mergeFn(alloc, &.{ Value.initMap(&m1), Value.initMap(&m2) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 3), result.asMap().count());
    // :b should be overwritten by m2's value
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "b", .ns = null })).?.eql(Value.initInteger(99)));
}

test "merge-with merges with function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(10),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    // (merge-with + {:a 1} {:a 10 :b 2}) => {:a 11 :b 2}
    const result = try mergeWithFn(alloc, &.{
        Value.initBuiltinFn(&testAddFn),
        Value.initMap(&m1),
        Value.initMap(&m2),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 2), result.asMap().count());
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "a", .ns = null })).?.eql(Value.initInteger(11)));
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "b", .ns = null })).?.eql(Value.initInteger(2)));
}

test "zipmap basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (zipmap [:a :b :c] [1 2 3]) => {:a 1 :b 2 :c 3}
    const keys = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }),
        Value.initKeyword(alloc, .{ .name = "c", .ns = null }),
    };
    var key_vec = PersistentVector{ .items = &keys };
    const vals = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var val_vec = PersistentVector{ .items = &vals };

    const result = try zipmapFn(alloc, &.{ Value.initVector(&key_vec), Value.initVector(&val_vec) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 3), result.asMap().count());
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "a", .ns = null })).?.eql(Value.initInteger(1)));
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "c", .ns = null })).?.eql(Value.initInteger(3)));
}

test "zipmap unequal lengths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (zipmap [:a :b] [1]) => {:a 1} — stops at shorter
    const keys = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }),
    };
    var key_vec = PersistentVector{ .items = &keys };
    const vals = [_]Value{Value.initInteger(1)};
    var val_vec = PersistentVector{ .items = &vals };

    const result = try zipmapFn(alloc, &.{ Value.initVector(&key_vec), Value.initVector(&val_vec) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 1), result.asMap().count());
}

test "zipmap empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var empty_vec = PersistentVector{ .items = &.{} };
    const result = try zipmapFn(alloc, &.{ Value.initVector(&empty_vec), Value.initVector(&empty_vec) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 0), result.asMap().count());
}

test "compare integers" {
    const r1 = try compareFn(test_alloc, &.{ Value.initInteger(1), Value.initInteger(2) });
    try testing.expectEqual(Value.initInteger(-1), r1);
    const r2 = try compareFn(test_alloc, &.{ Value.initInteger(2), Value.initInteger(1) });
    try testing.expectEqual(Value.initInteger(1), r2);
    const r3 = try compareFn(test_alloc, &.{ Value.initInteger(5), Value.initInteger(5) });
    try testing.expectEqual(Value.initInteger(0), r3);
}

test "compare strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try compareFn(alloc, &.{ Value.initString(alloc, "apple"), Value.initString(alloc, "banana") });
    try testing.expect(r1.asInteger() < 0);
    const r2 = try compareFn(alloc, &.{ Value.initString(alloc, "banana"), Value.initString(alloc, "apple") });
    try testing.expect(r2.asInteger() > 0);
    const r3 = try compareFn(alloc, &.{ Value.initString(alloc, "abc"), Value.initString(alloc, "abc") });
    try testing.expectEqual(Value.initInteger(0), r3);
}

test "sort integers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(3), Value.initInteger(1), Value.initInteger(2) };
    var vec = PersistentVector{ .items = &items };
    const result = try sortFn(alloc, &.{Value.initVector(&vec)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(1), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(2), result.asList().items[1]);
    try testing.expectEqual(Value.initInteger(3), result.asList().items[2]);
}

test "sort empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var empty_vec = PersistentVector{ .items = &.{} };
    const result = try sortFn(alloc, &.{Value.initVector(&empty_vec)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 0), result.asList().items.len);
}

test "sort-by with keyfn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // sort-by count ["bb" "a" "ccc"] => ["a" "bb" "ccc"]
    const items = [_]Value{ Value.initString(alloc, "bb"), Value.initString(alloc, "a"), Value.initString(alloc, "ccc") };
    var vec = PersistentVector{ .items = &items };
    const result = try sortByFn(alloc, &.{
        Value.initBuiltinFn(&countFn),
        Value.initVector(&vec),
    });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expect(result.asList().items[0].eql(Value.initString(alloc, "a")));
    try testing.expect(result.asList().items[1].eql(Value.initString(alloc, "bb")));
    try testing.expect(result.asList().items[2].eql(Value.initString(alloc, "ccc")));
}

test "vec converts list to vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var lst = PersistentList{ .items = &items };
    const result = try vecFn(alloc, &.{Value.initList(&lst)});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expectEqual(Value.initInteger(1), result.asVector().items[0]);
}

test "vec on nil returns empty vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try vecFn(arena.allocator(), &.{Value.nil_val});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 0), result.asVector().items.len);
}

test "set converts vector to set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (set [1 2 2 3]) => #{1 2 3}
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(2), Value.initInteger(3) };
    var vec = PersistentVector{ .items = &items };
    const result = try setCoerceFn(alloc, &.{Value.initVector(&vec)});
    try testing.expect(result.tag() == .set);
    try testing.expectEqual(@as(usize, 3), result.asSet().items.len);
}

test "list* creates list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (list* 1 2 [3 4]) => (1 2 3 4)
    const tail_items = [_]Value{ Value.initInteger(3), Value.initInteger(4) };
    var tail_vec = PersistentVector{ .items = &tail_items };
    const result = try listStarFn(alloc, &.{ Value.initInteger(1), Value.initInteger(2), Value.initVector(&tail_vec) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 4), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(1), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(4), result.asList().items[3]);
}

test "seq on map returns list of entry vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try seqFn(alloc, &.{Value.initMap(m)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().items.len);

    // First entry: [:a 1]
    const e1 = result.asList().items[0];
    try testing.expect(e1.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), e1.asVector().items.len);
    try testing.expect(e1.asVector().items[0].eql(Value.initKeyword(alloc, .{ .name = "a", .ns = null })));
    try testing.expectEqual(Value.initInteger(1), e1.asVector().items[1]);

    // Second entry: [:b 2]
    const e2 = result.asList().items[1];
    try testing.expect(e2.tag() == .vector);
    try testing.expectEqual(Value.initInteger(2), e2.asVector().items[1]);
}

test "seq on empty map returns nil" {
    const alloc = testing.allocator;
    const m = try alloc.create(PersistentArrayMap);
    defer alloc.destroy(m);
    m.* = .{ .entries = &.{} };

    const result = try seqFn(alloc, &.{Value.initMap(m)});
    try testing.expectEqual(Value.nil_val, result);
}

test "seq on set returns list of elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    var s = PersistentHashSet{ .items = &items };
    const result = try seqFn(alloc, &.{Value.initSet(&s)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
}

test "seq on empty set returns nil" {
    const alloc = testing.allocator;
    const s = try alloc.create(PersistentHashSet);
    defer alloc.destroy(s);
    s.* = .{ .items = &.{} };

    const result = try seqFn(alloc, &.{Value.initSet(s)});
    try testing.expectEqual(Value.nil_val, result);
}

test "builtins all have func" {
    for (builtins) |b| {
        try testing.expect(b.func != null);
    }
}

// --- dissoc tests ---

test "dissoc removes key from map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "a" }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .ns = null, .name = "b" }), Value.initInteger(2),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try dissocFn(alloc, &.{ Value.initMap(m), Value.initKeyword(alloc, .{ .ns = null, .name = "a" }) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 1), result.asMap().count());
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .ns = null, .name = "b" })) != null);
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .ns = null, .name = "a" })) == null);
}

test "dissoc on nil returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try dissocFn(alloc, &.{ Value.nil_val, Value.initKeyword(alloc, .{ .ns = null, .name = "a" }) });
    try testing.expectEqual(Value.nil_val, result);
}

test "dissoc missing key is identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "a" }), Value.initInteger(1),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try dissocFn(alloc, &.{ Value.initMap(m), Value.initKeyword(alloc, .{ .ns = null, .name = "z" }) });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 1), result.asMap().count());
}

// --- disj tests ---

test "disj removes value from set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const s = try alloc.create(PersistentHashSet);
    s.* = .{ .items = &items };

    const result = try disjFn(alloc, &.{ Value.initSet(s), Value.initInteger(2) });
    try testing.expect(result.tag() == .set);
    try testing.expectEqual(@as(usize, 2), result.asSet().count());
    try testing.expect(!result.asSet().contains(Value.initInteger(2)));
    try testing.expect(result.asSet().contains(Value.initInteger(1)));
    try testing.expect(result.asSet().contains(Value.initInteger(3)));
}

test "disj on nil returns nil" {
    const result = try disjFn(test_alloc, &.{ Value.nil_val, Value.initInteger(1) });
    try testing.expectEqual(Value.nil_val, result);
}

// --- find tests ---

test "find returns MapEntry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "a" }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .ns = null, .name = "b" }), Value.initInteger(2),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try findFn(alloc, &.{ Value.initMap(m), Value.initKeyword(alloc, .{ .ns = null, .name = "a" }) });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().items.len);
    try testing.expect(result.asVector().items[0].eql(Value.initKeyword(alloc, .{ .ns = null, .name = "a" })));
    try testing.expect(result.asVector().items[1].eql(Value.initInteger(1)));
}

test "find returns nil for missing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .ns = null, .name = "a" }), Value.initInteger(1),
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try findFn(alloc, &.{ Value.initMap(m), Value.initKeyword(alloc, .{ .ns = null, .name = "z" }) });
    try testing.expectEqual(Value.nil_val, result);
}

// --- peek tests ---

test "peek on vector returns last element" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const vec = PersistentVector{ .items = &items };
    const result = try peekFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expect(result.eql(Value.initInteger(3)));
}

test "peek on list returns first element" {
    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20) };
    const lst = PersistentList{ .items = &items };
    const result = try peekFn(test_alloc, &.{Value.initList(&lst)});
    try testing.expect(result.eql(Value.initInteger(10)));
}

test "peek on nil returns nil" {
    const result = try peekFn(test_alloc, &.{Value.nil_val});
    try testing.expectEqual(Value.nil_val, result);
}

test "peek on empty vector returns nil" {
    const vec = PersistentVector{ .items = &.{} };
    const result = try peekFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expectEqual(Value.nil_val, result);
}

// --- pop tests ---

test "pop on vector removes last element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try popFn(alloc, &.{Value.initVector(vec)});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().items.len);
    try testing.expect(result.asVector().items[0].eql(Value.initInteger(1)));
    try testing.expect(result.asVector().items[1].eql(Value.initInteger(2)));
}

test "pop on list removes first element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20), Value.initInteger(30) };
    const lst = try alloc.create(PersistentList);
    lst.* = .{ .items = &items };

    const result = try popFn(alloc, &.{Value.initList(lst)});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().items.len);
    try testing.expect(result.asList().items[0].eql(Value.initInteger(20)));
    try testing.expect(result.asList().items[1].eql(Value.initInteger(30)));
}

test "pop on empty vector is error" {
    const vec = PersistentVector{ .items = &.{} };
    const result = popFn(test_alloc, &.{Value.initVector(&vec)});
    try testing.expectError(error.ValueError, result);
}

test "pop on nil returns nil" {
    const result = try popFn(test_alloc, &.{Value.nil_val});
    try testing.expectEqual(Value.nil_val, result);
}

// --- empty tests ---

test "empty on vector returns empty vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try emptyFn(alloc, &.{Value.initVector(vec)});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 0), result.asVector().items.len);
}

test "empty on nil returns nil" {
    const result = try emptyFn(test_alloc, &.{Value.nil_val});
    try testing.expectEqual(Value.nil_val, result);
}

test "empty on string returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try emptyFn(alloc, &.{Value.initString(alloc, "abc")});
    try testing.expectEqual(Value.nil_val, result);
}

// --- subvec tests ---

test "subvec with start and end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3), Value.initInteger(4), Value.initInteger(5) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try subvecFn(alloc, &.{ Value.initVector(vec), Value.initInteger(1), Value.initInteger(4) });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().count());
    try testing.expect(result.asVector().nth(0).?.eql(Value.initInteger(2)));
    try testing.expect(result.asVector().nth(1).?.eql(Value.initInteger(3)));
    try testing.expect(result.asVector().nth(2).?.eql(Value.initInteger(4)));
}

test "subvec with start only (end defaults to length)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20), Value.initInteger(30) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try subvecFn(alloc, &.{ Value.initVector(vec), Value.initInteger(1) });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().count());
    try testing.expect(result.asVector().nth(0).?.eql(Value.initInteger(20)));
}

test "subvec out of bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    try testing.expectError(error.IndexError, subvecFn(alloc, &.{ Value.initVector(vec), Value.initInteger(0), Value.initInteger(5) }));
}

test "subvec on non-vector is error" {
    try testing.expectError(error.TypeError, subvecFn(test_alloc, &.{ Value.initInteger(42), Value.initInteger(0) }));
}

// --- array-map tests ---

test "array-map creates map from key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try arrayMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 2), result.asMap().count());
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "a", .ns = null })).?.eql(Value.initInteger(1)));
    try testing.expect(result.asMap().get(Value.initKeyword(alloc, .{ .name = "b", .ns = null })).?.eql(Value.initInteger(2)));
}

test "array-map with no args returns empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try arrayMapFn(arena.allocator(), &.{});
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 0), result.asMap().count());
}

test "array-map with odd args is error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectError(error.ArityError, arrayMapFn(alloc, &.{Value.initKeyword(alloc, .{ .name = "a", .ns = null })}));
}

// --- hash-set tests ---

test "hash-set creates set from values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try hashSetFn(alloc, &.{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) });
    try testing.expect(result.tag() == .set);
    try testing.expectEqual(@as(usize, 3), result.asSet().count());
    try testing.expect(result.asSet().contains(Value.initInteger(1)));
    try testing.expect(result.asSet().contains(Value.initInteger(2)));
    try testing.expect(result.asSet().contains(Value.initInteger(3)));
}

test "hash-set deduplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try hashSetFn(alloc, &.{ Value.initInteger(1), Value.initInteger(1), Value.initInteger(2) });
    try testing.expect(result.tag() == .set);
    try testing.expectEqual(@as(usize, 2), result.asSet().count());
}

test "hash-set with no args returns empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try hashSetFn(arena.allocator(), &.{});
    try testing.expect(result.tag() == .set);
    try testing.expectEqual(@as(usize, 0), result.asSet().count());
}

// --- sorted-map tests ---

test "sorted-map creates map with sorted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "c", .ns = null }), Value.initInteger(3),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 3), result.asMap().count());
    // Keys should be sorted: :a, :b, :c
    // Entries are [k1,v1,k2,v2,...] so sorted order means entries[0]=:a, entries[2]=:b, entries[4]=:c
    try testing.expect(result.asMap().entries[0].eql(Value.initKeyword(alloc, .{ .name = "a", .ns = null })));
    try testing.expect(result.asMap().entries[2].eql(Value.initKeyword(alloc, .{ .name = "b", .ns = null })));
    try testing.expect(result.asMap().entries[4].eql(Value.initKeyword(alloc, .{ .name = "c", .ns = null })));
}

test "sorted-map with no args returns empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try sortedMapFn(arena.allocator(), &.{});
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 0), result.asMap().count());
}

test "sorted-map with odd args is error" {
    try testing.expectError(error.ArityError, sortedMapFn(test_alloc, &.{Value.initInteger(1)}));
}

test "sorted-map stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    });
    try testing.expect(result.tag() == .map);
    // sorted-map stores .nil as natural ordering sentinel
    try testing.expect(result.asMap().comparator != null);
    try testing.expect(result.asMap().comparator.? == Value.nil_val);
}

test "sorted-map empty stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try sortedMapFn(arena.allocator(), &.{});
    try testing.expect(result.tag() == .map);
    try testing.expect(result.asMap().comparator != null);
    try testing.expect(result.asMap().comparator.? == Value.nil_val);
}

test "assoc on sorted-map maintains sort order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create sorted map with :a and :c
    const sm = try sortedMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "c", .ns = null }), Value.initInteger(3),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    });
    // assoc :b — should sort into the middle
    const result = try assocFn(alloc, &.{
        sm,
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }),
        Value.initInteger(2),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 3), result.asMap().count());
    // Keys should be sorted: :a, :b, :c
    try testing.expect(result.asMap().entries[0].eql(Value.initKeyword(alloc, .{ .name = "a", .ns = null })));
    try testing.expect(result.asMap().entries[2].eql(Value.initKeyword(alloc, .{ .name = "b", .ns = null })));
    try testing.expect(result.asMap().entries[4].eql(Value.initKeyword(alloc, .{ .name = "c", .ns = null })));
    // Comparator propagated
    try testing.expect(result.asMap().comparator != null);
    try testing.expect(result.asMap().comparator.? == Value.nil_val);
}

test "dissoc on sorted-map preserves comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sm = try sortedMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    });
    const result = try dissocFn(alloc, &.{
        sm,
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }),
    });
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 1), result.asMap().count());
    try testing.expect(result.asMap().comparator != null);
}

test "sorted-set stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedSetFn(alloc, &.{
        Value.initInteger(3), Value.initInteger(1), Value.initInteger(2),
    });
    try testing.expect(result.tag() == .set);
    // Items should be sorted: 1, 2, 3
    try testing.expectEqual(@as(usize, 3), result.asSet().count());
    try testing.expect(result.asSet().items[0].eql(Value.initInteger(1)));
    try testing.expect(result.asSet().items[1].eql(Value.initInteger(2)));
    try testing.expect(result.asSet().items[2].eql(Value.initInteger(3)));
    // Comparator stored
    try testing.expect(result.asSet().comparator != null);
    try testing.expect(result.asSet().comparator.? == Value.nil_val);
}

// --- subseq / rsubseq tests ---

const arith = @import("arithmetic.zig");

test "subseq on sorted-map with >" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-map :a 1 :b 2 :c 3)
    const sm = try sortedMapFn(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "c", .ns = null }), Value.initInteger(3),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    });

    // (subseq sm > :a) => ([:b 2] [:c 3])
    const gt_fn = Value.initBuiltinFn(arith.builtins[9].func.?); // ">"
    const result = try subseqFn(alloc, &.{ sm, gt_fn, Value.initKeyword(alloc, .{ .name = "a", .ns = null }) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().items.len);
    // First entry should be [:b 2]
    try testing.expect(result.asList().items[0].tag() == .vector);
    try testing.expect(result.asList().items[0].asVector().items[0].eql(Value.initKeyword(alloc, .{ .name = "b", .ns = null })));
}

test "subseq on sorted-set with >=" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-set 1 2 3 4 5)
    const ss = try sortedSetFn(alloc, &.{
        Value.initInteger(3), Value.initInteger(1), Value.initInteger(5),
        Value.initInteger(2), Value.initInteger(4),
    });

    // (subseq ss >= 3) => (3 4 5)
    const ge_fn = Value.initBuiltinFn(arith.builtins[11].func.?); // ">="
    const result = try subseqFn(alloc, &.{ ss, ge_fn, Value.initInteger(3) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expect(result.asList().items[0].eql(Value.initInteger(3)));
    try testing.expect(result.asList().items[1].eql(Value.initInteger(4)));
    try testing.expect(result.asList().items[2].eql(Value.initInteger(5)));
}

test "rsubseq on sorted-set with <=" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-set 1 2 3 4 5)
    const ss = try sortedSetFn(alloc, &.{
        Value.initInteger(3), Value.initInteger(1), Value.initInteger(5),
        Value.initInteger(2), Value.initInteger(4),
    });

    // (rsubseq ss <= 3) => (3 2 1)
    const le_fn = Value.initBuiltinFn(arith.builtins[10].func.?); // "<="
    const result = try rsubseqFn(alloc, &.{ ss, le_fn, Value.initInteger(3) });
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expect(result.asList().items[0].eql(Value.initInteger(3)));
    try testing.expect(result.asList().items[1].eql(Value.initInteger(2)));
    try testing.expect(result.asList().items[2].eql(Value.initInteger(1)));
}
