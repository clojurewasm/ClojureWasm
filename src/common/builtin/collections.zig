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
const PersistentHashSet = value_mod.PersistentHashSet;
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
    return switch (args[0]) {
        .list => |lst| lst.first(),
        .vector => |vec| if (vec.items.len > 0) vec.items[0] else .nil,
        .nil => .nil,
        .cons => |c| c.first,
        .map => {
            const s = try seqFn(allocator, args);
            if (s == .nil) return .nil;
            const seq_args = [1]Value{s};
            return firstFn(allocator, &seq_args);
        },
        .set => {
            const s = try seqFn(allocator, args);
            if (s == .nil) return .nil;
            const seq_args = [1]Value{s};
            return firstFn(allocator, &seq_args);
        },
        .lazy_seq => |ls| {
            const realized = try ls.realize(allocator);
            const realized_args = [1]Value{realized};
            return firstFn(allocator, &realized_args);
        },
        .chunked_cons => |cc| cc.first(),
        .string => |s| {
            if (s.len == 0) return .nil;
            const cp_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            const cp = std.unicode.utf8Decode(s[0..cp_len]) catch s[0];
            return Value{ .char = cp };
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "first not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (rest coll) — returns everything after first, or empty list.
pub fn restFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rest", .{args.len});
    return switch (args[0]) {
        .list => |lst| blk: {
            const r = lst.rest();
            const new_list = try allocator.create(PersistentList);
            new_list.* = r;
            break :blk Value{ .list = new_list };
        },
        .vector => |vec| blk: {
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = if (vec.items.len > 0) vec.items[1..] else &.{} };
            break :blk Value{ .list = new_list };
        },
        .nil => blk: {
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = &.{} };
            break :blk Value{ .list = new_list };
        },
        .cons => |c| c.rest,
        .map => {
            const s = try seqFn(allocator, args);
            if (s == .nil) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value{ .list = empty };
            }
            const seq_args = [1]Value{s};
            return restFn(allocator, &seq_args);
        },
        .set => {
            const s = try seqFn(allocator, args);
            if (s == .nil) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value{ .list = empty };
            }
            const seq_args = [1]Value{s};
            return restFn(allocator, &seq_args);
        },
        .lazy_seq => |ls| {
            const realized = try ls.realize(allocator);
            const realized_args = [1]Value{realized};
            return restFn(allocator, &realized_args);
        },
        .chunked_cons => |cc| {
            const rest_val = try cc.next(allocator);
            if (rest_val == .nil) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                return Value{ .list = empty };
            }
            return rest_val;
        },
        .string => |s| blk: {
            if (s.len == 0) {
                const empty = try allocator.create(PersistentList);
                empty.* = .{ .items = &.{} };
                break :blk Value{ .list = empty };
            }
            const cp_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            const rest_str = s[cp_len..];
            // Convert remaining chars to list of characters
            var chars: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < rest_str.len) {
                const cl = std.unicode.utf8ByteSequenceLength(rest_str[i]) catch 1;
                const cp = std.unicode.utf8Decode(rest_str[i..][0..cl]) catch rest_str[i];
                try chars.append(allocator, Value{ .char = cp });
                i += cl;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = try chars.toOwnedSlice(allocator) };
            break :blk Value{ .list = lst };
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "rest not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (cons x seq) — prepend x to seq, returns a list or cons cell.
/// Returns a Cons cell when rest is lazy_seq or cons (preserves laziness).
pub fn consFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to cons", .{args.len});
    const x = args[0];

    // For lazy_seq or cons rest, return a Cons cell to preserve laziness
    if (args[1] == .lazy_seq or args[1] == .cons) {
        const cell = try allocator.create(value_mod.Cons);
        cell.* = .{ .first = x, .rest = args[1] };
        return Value{ .cons = cell };
    }

    const seq_items = switch (args[1]) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        .set => |s| s.items,
        .map => blk: {
            const entries = try collectSeqItems(allocator, try seqFn(allocator, &.{args[1]}));
            break :blk entries;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "cons expects a seq, got {s}", .{@tagName(args[1])}),
    };

    const new_items = try allocator.alloc(Value, seq_items.len + 1);
    new_items[0] = x;
    @memcpy(new_items[1..], seq_items);

    const new_list = try allocator.create(PersistentList);
    new_list.* = .{ .items = new_items };
    return Value{ .list = new_list };
}

/// (conj coll x) — add to collection (front for list, back for vector).
pub fn conjFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        // (conj) => []
        const empty = try allocator.alloc(Value, 0);
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = empty };
        return Value{ .vector = vec };
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
    switch (coll) {
        .list => |lst| {
            const new_items = try allocator.alloc(Value, lst.items.len + 1);
            new_items[0] = x;
            @memcpy(new_items[1..], lst.items);
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items, .meta = lst.meta };
            return Value{ .list = new_list };
        },
        .vector => |vec| {
            const new_items = try allocator.alloc(Value, vec.items.len + 1);
            @memcpy(new_items[0..vec.items.len], vec.items);
            new_items[vec.items.len] = x;
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = new_items, .meta = vec.meta };
            return Value{ .vector = new_vec };
        },
        .set => |s| {
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
            return Value{ .set = new_set };
        },
        .map => {
            // (conj map [k v]) => (assoc map k v)
            if (x == .vector) {
                const pair = x.vector;
                if (pair.items.len != 2) return err.setErrorFmt(.eval, .value_error, .{}, "conj on map expects vector of 2 elements, got {d}", .{pair.items.len});
                const assoc_args = [_]Value{ coll, pair.items[0], pair.items[1] };
                return assocFn(allocator, &assoc_args);
            } else if (x == .map) {
                // (conj map1 map2) => merge map2 into map1
                var result = coll;
                const entries = x.map.entries;
                var i: usize = 0;
                while (i < entries.len) : (i += 2) {
                    const assoc_args = [_]Value{ result, entries[i], entries[i + 1] };
                    result = try assocFn(allocator, &assoc_args);
                }
                return result;
            }
            return err.setErrorFmt(.eval, .type_error, .{}, "conj on map expects vector or map, got {s}", .{@tagName(x)});
        },
        .nil => {
            // (conj nil x) => (x) — returns a list
            const new_items = try allocator.alloc(Value, 1);
            new_items[0] = x;
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items };
            return Value{ .list = new_list };
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "conj not supported on {s}", .{@tagName(coll)}),
    }
}

/// (assoc map key val & kvs) — associate key(s) with val(s) in map or vector.
/// For maps: (assoc {:a 1} :b 2) => {:a 1 :b 2}
/// For vectors: (assoc [1 2 3] 1 99) => [1 99 3] (index must be <= count)
pub fn assocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to assoc", .{args.len});
    const base = args[0];

    // Handle vector case
    if (base == .vector) {
        return assocVector(allocator, base.vector, args[1..]);
    }

    // Handle map/nil case
    const base_entries = switch (base) {
        .map => |m| m.entries,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "assoc expects a map, vector, or nil, got {s}", .{@tagName(base)}),
    };

    // Build new entries: copy base, then override/add pairs
    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, base_entries);

    var i: usize = 0;
    while (i < args.len - 1) : (i += 2) {
        const key = args[i + 1];
        const val = args[i + 2];
        // Try to find existing key and replace
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

    const base_comp: ?Value = if (base == .map) base.map.comparator else null;

    // Re-sort if this is a sorted map
    if (base_comp) |comp| {
        try sortMapEntries(allocator, entries.items, comp);
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = if (base == .map) base.map.meta else null, .comparator = base_comp };
    return Value{ .map = new_map };
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
        const idx = switch (idx_val) {
            .integer => |n| if (n >= 0) @as(usize, @intCast(n)) else return err.setErrorFmt(.eval, .index_error, .{}, "assoc index out of bounds: {d}", .{n}),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "assoc expects integer index, got {s}", .{@tagName(idx_val)}),
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
    return Value{ .vector = new_vec };
}

/// (get map key) or (get map key not-found) — lookup in map or set.
pub fn getFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to get", .{args.len});
    const not_found: Value = if (args.len == 3) args[2] else .nil;
    return switch (args[0]) {
        .map => |m| m.get(args[1]) orelse not_found,
        .vector => |vec| blk: {
            if (args[1] != .integer) break :blk not_found;
            const idx = args[1].integer;
            if (idx < 0) break :blk not_found;
            break :blk vec.nth(@intCast(idx)) orelse not_found;
        },
        .set => |s| if (s.contains(args[1])) args[1] else not_found,
        .transient_vector => |tv| blk: {
            if (args[1] != .integer) break :blk not_found;
            const idx = args[1].integer;
            if (idx < 0 or @as(usize, @intCast(idx)) >= tv.items.items.len) break :blk not_found;
            break :blk tv.items.items[@intCast(idx)];
        },
        .transient_map => |tm| blk: {
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) break :blk tm.entries.items[i + 1];
            }
            break :blk not_found;
        },
        .transient_set => |ts| blk: {
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
pub fn nthFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to nth", .{args.len});
    const idx_val = args[1];
    if (idx_val != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "nth expects integer index, got {s}", .{@tagName(idx_val)});
    const idx = idx_val.integer;
    if (idx < 0) {
        if (args.len == 3) return args[2];
        return err.setErrorFmt(.eval, .index_error, .{}, "nth index out of bounds: {d}", .{idx});
    }
    const uidx: usize = @intCast(idx);

    return switch (args[0]) {
        .vector => |vec| vec.nth(uidx) orelse if (args.len == 3) args[2] else err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for vector of size {d}", .{ uidx, vec.items.len }),
        .list => |lst| if (uidx < lst.items.len) lst.items[uidx] else if (args.len == 3) args[2] else err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for list of size {d}", .{ uidx, lst.items.len }),
        .array_chunk => |ac| ac.nth(uidx) orelse if (args.len == 3) args[2] else err.setErrorFmt(.eval, .index_error, .{}, "nth index {d} out of bounds for chunk of size {d}", .{ uidx, ac.count() }),
        .nil => if (args.len == 3) args[2] else err.setErrorFmt(.eval, .index_error, .{}, "nth on nil", .{}),
        else => err.setErrorFmt(.eval, .type_error, .{}, "nth not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (count coll) — number of elements.
pub fn countFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to count", .{args.len});
    if (args[0] == .lazy_seq) {
        const realized = try args[0].lazy_seq.realize(allocator);
        const realized_args = [1]Value{realized};
        return countFn(allocator, &realized_args);
    }
    if (args[0] == .cons) {
        // Count by walking the cons chain
        var n: i64 = 0;
        var current = args[0];
        while (current == .cons) {
            n += 1;
            current = current.cons.rest;
        }
        // Count remaining (list/vector/nil)
        const rest_args = [1]Value{current};
        const rest_count = try countFn(allocator, &rest_args);
        return Value{ .integer = n + rest_count.integer };
    }
    if (args[0] == .chunked_cons) {
        // Count by walking chunked_cons chain
        var n: i64 = 0;
        var current = args[0];
        while (current == .chunked_cons) {
            n += @intCast(current.chunked_cons.chunk.count());
            current = current.chunked_cons.more;
        }
        const rest_args = [1]Value{current};
        const rest_count = try countFn(allocator, &rest_args);
        return Value{ .integer = n + rest_count.integer };
    }
    return Value{ .integer = @intCast(switch (args[0]) {
        .list => |lst| lst.count(),
        .vector => |vec| vec.count(),
        .map => |m| m.count(),
        .set => |s| s.count(),
        .nil => @as(usize, 0),
        .string => |s| s.len,
        .transient_vector => |tv| tv.count(),
        .transient_map => |tm| tm.count(),
        .transient_set => |ts| ts.count(),
        .array_chunk => |ac| ac.count(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "count not supported on {s}", .{@tagName(args[0])}),
    }) };
}

/// (list & items) — returns a new list containing the items.
pub fn listFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (seq coll) — returns a seq on the collection. Returns nil if empty.
pub fn seqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to seq", .{args.len});
    return switch (args[0]) {
        .nil => .nil,
        .list => |lst| if (lst.items.len == 0) .nil else args[0],
        .vector => |vec| {
            if (vec.items.len == 0) return .nil;
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = vec.items };
            return Value{ .list = lst };
        },
        .cons => args[0], // cons is always non-empty
        .chunked_cons => args[0], // chunked_cons is always non-empty
        .map => |m| {
            const n = m.count();
            if (n == 0) return .nil;
            const entry_vecs = try allocator.alloc(Value, n);
            var idx: usize = 0;
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                const pair = try allocator.alloc(Value, 2);
                pair[0] = m.entries[i];
                pair[1] = m.entries[i + 1];
                const vec = try allocator.create(PersistentVector);
                vec.* = .{ .items = pair };
                entry_vecs[idx] = Value{ .vector = vec };
                idx += 1;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = entry_vecs };
            return Value{ .list = lst };
        },
        .set => |s| {
            if (s.items.len == 0) return .nil;
            // Convert set items to list
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = s.items };
            return Value{ .list = lst };
        },
        .lazy_seq => |ls| {
            const realized = try ls.realize(allocator);
            const realized_args = [1]Value{realized};
            return seqFn(allocator, &realized_args);
        },
        .string => |s| {
            if (s.len == 0) return .nil;
            var chars: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < s.len) {
                const cl = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                const cp = std.unicode.utf8Decode(s[i..][0..cl]) catch s[i];
                try chars.append(allocator, Value{ .char = cp });
                i += cl;
            }
            const lst = try allocator.create(PersistentList);
            lst.* = .{ .items = try chars.toOwnedSlice(allocator) };
            return Value{ .list = lst };
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "seq not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (concat) / (concat x) / (concat x y ...) — concatenate sequences.
pub fn concatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = &.{} };
        return Value{ .list = lst };
    }

    // Collect all items from all sequences using collectSeqItems
    var all: std.ArrayListUnmanaged(Value) = .empty;
    for (args) |arg| {
        if (arg == .nil) continue;
        const seq_items = try collectSeqItems(allocator, arg);
        for (seq_items) |item| try all.append(allocator, item);
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = try all.toOwnedSlice(allocator) };
    return Value{ .list = lst };
}

/// (reverse coll) — returns a list of items in reverse order.
/// nil returns empty list. Empty collection returns empty list.
pub fn reverseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reverse", .{args.len});
    const items = switch (args[0]) {
        .nil => &[_]Value{},
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "reverse not supported on {s}", .{@tagName(args[0])}),
    };
    if (items.len == 0) {
        const empty_lst = try allocator.create(PersistentList);
        empty_lst.* = .{ .items = &.{} };
        return Value{ .list = empty_lst };
    }

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value{ .list = lst };
}

/// (rseq rev) — returns a seq of items in reverse order, nil if empty.
pub fn rseqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rseq", .{args.len});
    const items = switch (args[0]) {
        .nil => return .nil,
        .vector => |vec| vec.items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "rseq not supported on {s}", .{@tagName(args[0])}),
    };
    if (items.len == 0) return .nil;

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value{ .list = lst };
}

/// (shuffle coll) — returns a random permutation of coll as a vector.
pub fn shuffleFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to shuffle", .{args.len});
    const items = try collectSeqItems(allocator, args[0]);
    if (items.len == 0) {
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = &.{} };
        return Value{ .vector = vec };
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
    return Value{ .vector = vec };
}

/// (into to from) — returns a new coll with items from `from` conj'd onto `to`.
pub fn intoFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to into", .{args.len});
    if (args[1] == .nil) return args[0];
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
    const spread_items: []const Value = if (last_arg == .nil)
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
    return switch (f) {
        .builtin_fn => |func| func(allocator, call_args),
        .fn_val => bootstrap.callFnVal(allocator, f, call_args),
        .keyword => |kw| blk: {
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
            const m = switch (call_args[0]) {
                .map => |mp| mp,
                else => break :blk if (call_args.len == 2) call_args[1] else .nil,
            };
            break :blk m.get(Value{ .keyword = kw }) orelse
                if (call_args.len == 2) call_args[1] else .nil;
        },
        .map => |m| blk: {
            // map as function: ({:a 1} :a) or ({:a 1} :a default)
            if (call_args.len < 1 or call_args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map lookup", .{call_args.len});
            break :blk m.get(call_args[0]) orelse
                if (call_args.len == 2) call_args[1] else .nil;
        },
        .set => |s| blk: {
            // set as function: (#{:a :b} :a)
            if (call_args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set lookup", .{call_args.len});
            break :blk if (s.contains(call_args[0])) call_args[0] else .nil;
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "apply expects a function, got {s}", .{@tagName(f)}),
    };
}

/// (vector & items) — creates a vector from arguments.
pub fn vectorFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
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
    return Value{ .map = map };
}

/// (__seq-to-map x) — coerce seq-like values to maps for map destructuring.
/// Seqs/lists are converted via hash-map semantics. Non-seqs pass through unchanged.
pub fn seqToMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __seq-to-map", .{args.len});
    return switch (args[0]) {
        .nil => .nil, // JVM: (seq? nil) → false, passes through
        .list => |lst| {
            if (lst.items.len == 0) {
                const map = try allocator.create(PersistentArrayMap);
                map.* = .{ .entries = &.{} };
                return Value{ .map = map };
            }
            return hashMapFn(allocator, lst.items);
        },
        .cons, .lazy_seq => {
            const items = try collectSeqItems(allocator, args[0]);
            if (items.len == 0) {
                const map = try allocator.create(PersistentArrayMap);
                map.* = .{ .entries = &.{} };
                return Value{ .map = map };
            }
            return hashMapFn(allocator, items);
        },
        else => args[0], // maps, vectors, etc. pass through
    };
}

/// (merge & maps) — returns a map that consists of the rest of the maps conj-ed onto the first.
/// If a key occurs in more than one map, the mapping from the latter (left-to-right) will be the mapping in the result.
pub fn mergeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return .nil;

    // Skip leading nils, find first map
    var start: usize = 0;
    while (start < args.len and args[start] == .nil) : (start += 1) {}
    if (start >= args.len) return .nil;

    // Start with entries from first map
    if (args[start] != .map) return err.setErrorFmt(.eval, .type_error, .{}, "merge expects a map, got {s}", .{@tagName(args[start])});
    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, args[start].map.entries);

    // Merge remaining maps left-to-right
    for (args[start + 1 ..]) |arg| {
        if (arg == .nil) continue;
        if (arg != .map) return err.setErrorFmt(.eval, .type_error, .{}, "merge expects a map, got {s}", .{@tagName(arg)});
        const src = arg.map.entries;
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

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = args[start].map.meta };
    return Value{ .map = new_map };
}

/// (merge-with f & maps) — merge maps, calling (f old new) on key conflicts.
pub fn mergeWithFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to merge-with", .{args.len});

    const f = args[0];
    const maps = args[1..];

    if (maps.len == 0) return .nil;

    // Skip leading nils
    var start: usize = 0;
    while (start < maps.len and maps[start] == .nil) : (start += 1) {}
    if (start >= maps.len) return .nil;

    if (maps[start] != .map) return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a map, got {s}", .{@tagName(maps[start])});
    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, maps[start].map.entries);

    for (maps[start + 1 ..]) |arg| {
        if (arg == .nil) continue;
        if (arg != .map) return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a map, got {s}", .{@tagName(arg)});
        const src = arg.map.entries;
        var i: usize = 0;
        while (i < src.len) : (i += 2) {
            const key = src[i];
            const val = src[i + 1];
            var found = false;
            var j: usize = 0;
            while (j < entries.items.len) : (j += 2) {
                if (entries.items[j].eql(key)) {
                    // Key conflict: call f(old_val, new_val)
                    entries.items[j + 1] = switch (f) {
                        .builtin_fn => |func| try func(allocator, &.{ entries.items[j + 1], val }),
                        else => return err.setErrorFmt(.eval, .type_error, .{}, "merge-with expects a function, got {s}", .{@tagName(f)}),
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

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items, .meta = maps[start].map.meta };
    return Value{ .map = new_map };
}

/// Generic value comparison returning std.math.Order.
/// Supports: nil, booleans, integers, floats, strings, keywords, symbols.
/// Cross-type numeric comparison supported. Non-comparable types return TypeError.
pub fn compareValues(a: Value, b: Value) anyerror!std.math.Order {
    // nil sorts before everything
    if (a == .nil and b == .nil) return .eq;
    if (a == .nil) return .lt;
    if (b == .nil) return .gt;

    // booleans: false < true
    if (a == .boolean and b == .boolean) {
        if (a.boolean == b.boolean) return .eq;
        return if (!a.boolean) .lt else .gt;
    }

    // numeric: int/float cross-comparison
    if ((a == .integer or a == .float) and (b == .integer or b == .float)) {
        const fa: f64 = if (a == .integer) @floatFromInt(a.integer) else a.float;
        const fb: f64 = if (b == .integer) @floatFromInt(b.integer) else b.float;
        return std.math.order(fa, fb);
    }

    // strings
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string, b.string);
    }

    // keywords: compare by namespace then name
    if (a == .keyword and b == .keyword) {
        const ans = a.keyword.ns orelse "";
        const bns = b.keyword.ns orelse "";
        const ns_ord = std.mem.order(u8, ans, bns);
        if (ns_ord != .eq) return ns_ord;
        return std.mem.order(u8, a.keyword.name, b.keyword.name);
    }

    // symbols: compare by namespace then name
    if (a == .symbol and b == .symbol) {
        const ans = a.symbol.ns orelse "";
        const bns = b.symbol.ns orelse "";
        const ns_ord = std.mem.order(u8, ans, bns);
        if (ns_ord != .eq) return ns_ord;
        return std.mem.order(u8, a.symbol.name, b.symbol.name);
    }

    // vectors: element-by-element comparison
    if (a == .vector and b == .vector) {
        const av = a.vector.items;
        const bv = b.vector.items;
        const min_len = @min(av.len, bv.len);
        for (0..min_len) |i| {
            const elem_ord = try compareValues(av[i], bv[i]);
            if (elem_ord != .eq) return elem_ord;
        }
        return std.math.order(av.len, bv.len);
    }

    return err.setErrorFmt(.eval, .type_error, .{}, "compare: cannot compare {s} and {s}", .{ @tagName(a), @tagName(b) });
}

/// (compare x y) — comparator returning negative, zero, or positive integer.
pub fn compareFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to compare", .{args.len});
    const ord = try compareValues(args[0], args[1]);
    return Value{ .integer = switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

/// (sort coll) or (sort comp coll) — returns a sorted list.
/// With 1 arg: sorts using natural ordering (compare).
/// With 2 args: first arg is comparator function (not yet supported in unit tests).
pub fn sortFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sort", .{args.len});

    // Get the collection (last arg)
    const coll = args[args.len - 1];
    const items = switch (coll) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "sort not supported on {s}", .{@tagName(coll)}),
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

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = sorted };
    return Value{ .list = lst };
}

/// (sort-by keyfn coll) or (sort-by keyfn comp coll) — sort by key extraction.
pub fn sortByFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sort-by", .{args.len});

    const keyfn = args[0];
    const coll = args[args.len - 1];
    const items = switch (coll) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "sort-by not supported on {s}", .{@tagName(coll)}),
    };

    if (items.len == 0) {
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = &.{} };
        return Value{ .list = lst };
    }

    // Compute keys for each element
    const keys = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        keys[i] = switch (keyfn) {
            .builtin_fn => |func| try func(allocator, &.{item}),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "sort-by expects a function as keyfn, got {s}", .{@tagName(keyfn)}),
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

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = sorted };
    return Value{ .list = lst };
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
    return Value{ .map = new_map };
}

/// Realize a lazy_seq/cons value into a PersistentList.
/// Non-sequential values are returned as-is.
/// Used by eqFn and print builtins for transparent lazy seq support.
pub fn realizeValue(allocator: Allocator, val: Value) anyerror!Value {
    if (val != .lazy_seq and val != .cons) return val;
    const items = try collectSeqItems(allocator, val);
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// Collect all items from a seq-like value (list, vector, cons, lazy_seq)
/// into a flat slice. Handles cons chains and lazy realization.
pub fn collectSeqItems(allocator: Allocator, val: Value) anyerror![]const Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    var current = val;
    while (true) {
        switch (current) {
            .cons => |c| {
                try items.append(allocator, c.first);
                current = c.rest;
            },
            .lazy_seq => |ls| {
                current = try ls.realize(allocator);
            },
            .list => |lst| {
                for (lst.items) |item| try items.append(allocator, item);
                break;
            },
            .vector => |v| {
                for (v.items) |item| try items.append(allocator, item);
                break;
            },
            .set => |s| {
                for (s.items) |item| try items.append(allocator, item);
                break;
            },
            .map => |m| {
                var i: usize = 0;
                while (i < m.entries.len) : (i += 2) {
                    const pair = try allocator.alloc(Value, 2);
                    pair[0] = m.entries[i];
                    pair[1] = m.entries[i + 1];
                    const vec = try allocator.create(PersistentVector);
                    vec.* = .{ .items = pair };
                    try items.append(allocator, Value{ .vector = vec });
                }
                break;
            },
            .string => |s| {
                var i: usize = 0;
                while (i < s.len) {
                    const cl = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                    const cp = std.unicode.utf8Decode(s[i..][0..cl]) catch s[i];
                    try items.append(allocator, Value{ .char = cp });
                    i += cl;
                }
                break;
            },
            .nil => break,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "don't know how to create seq from {s}", .{@tagName(current)}),
        }
    }
    return items.toOwnedSlice(allocator);
}

/// (vec coll) — coerce a collection to a vector.
pub fn vecFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vec", .{args.len});
    if (args[0] == .vector) return args[0];
    const items = try collectSeqItems(allocator, args[0]);
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// (set coll) — coerce a collection to a set (removing duplicates).
pub fn setCoerceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set", .{args.len});

    // Handle lazy_seq: realize then recurse
    if (args[0] == .lazy_seq) {
        const realized = try args[0].lazy_seq.realize(allocator);
        const realized_args = [1]Value{realized};
        return setCoerceFn(allocator, &realized_args);
    }

    // Handle cons: walk chain and collect items
    if (args[0] == .cons) {
        var result = std.ArrayList(Value).empty;
        var current = args[0];
        while (true) {
            if (current == .cons) {
                const item = current.cons.first;
                var dup = false;
                for (result.items) |existing| {
                    if (existing.eql(item)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try result.append(allocator, item);
                current = current.cons.rest;
            } else if (current == .lazy_seq) {
                current = try current.lazy_seq.realize(allocator);
            } else if (current == .nil) {
                break;
            } else if (current == .list) {
                for (current.list.items) |item| {
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
        return Value{ .set = new_set };
    }

    // Handle map: convert to set of [k v] vectors
    if (args[0] == .map) {
        const m = args[0].map;
        const n = m.count();
        if (n == 0) {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{} };
            return Value{ .set = new_set };
        }
        var result = std.ArrayList(Value).empty;
        var i: usize = 0;
        while (i < m.entries.len) : (i += 2) {
            const pair = try allocator.alloc(Value, 2);
            pair[0] = m.entries[i];
            pair[1] = m.entries[i + 1];
            const vec = try allocator.create(PersistentVector);
            vec.* = .{ .items = pair };
            try result.append(allocator, Value{ .vector = vec });
        }
        const new_set = try allocator.create(PersistentHashSet);
        new_set.* = .{ .items = result.items };
        return Value{ .set = new_set };
    }

    // Handle string: convert to set of characters
    if (args[0] == .string) {
        const s = args[0].string;
        if (s.len == 0) {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{} };
            return Value{ .set = new_set };
        }
        var result = std.ArrayList(Value).empty;
        for (s) |c| {
            const char_val = Value{ .char = c };
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
        return Value{ .set = new_set };
    }

    const items = switch (args[0]) {
        .set => return args[0], // already a set
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "set not supported on {s}", .{@tagName(args[0])}),
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
    return Value{ .set = new_set };
}

/// (list* args... coll) — creates a list with args prepended to the final collection.
pub fn listStarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to list*", .{args.len});
    if (args.len == 1) {
        // (list* coll) — just return as seq
        return switch (args[0]) {
            .list => args[0],
            .vector => |vec| blk: {
                const lst = try allocator.create(PersistentList);
                lst.* = .{ .items = vec.items };
                break :blk Value{ .list = lst };
            },
            .nil => .nil,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "list* not supported on {s}", .{@tagName(args[0])}),
        };
    }

    // Last arg is the tail collection
    const tail_items = switch (args[args.len - 1]) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "list* expects a collection as last arg, got {s}", .{@tagName(args[args.len - 1])}),
    };

    const prefix_count = args.len - 1;
    const total = prefix_count + tail_items.len;
    const new_items = try allocator.alloc(Value, total);
    @memcpy(new_items[0..prefix_count], args[0..prefix_count]);
    @memcpy(new_items[prefix_count..], tail_items);

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value{ .list = lst };
}

/// (dissoc map key & ks) — remove key(s) from map.
pub fn dissocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to dissoc", .{args.len});
    if (args.len == 1) {
        // (dissoc map) — identity
        return switch (args[0]) {
            .map => args[0],
            .nil => .nil,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "dissoc expects a map, got {s}", .{@tagName(args[0])}),
        };
    }
    const base_entries = switch (args[0]) {
        .map => |m| m.entries,
        .nil => return .nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "dissoc expects a map, got {s}", .{@tagName(args[0])}),
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
    new_map.* = .{ .entries = entries.items, .meta = if (args[0] == .map) args[0].map.meta else null, .comparator = if (args[0] == .map) args[0].map.comparator else null };
    return Value{ .map = new_map };
}

/// (disj set val & vals) — remove value(s) from set.
pub fn disjFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to disj", .{args.len});
    if (args.len == 1) {
        return switch (args[0]) {
            .set => args[0],
            .nil => .nil,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "disj expects a set, got {s}", .{@tagName(args[0])}),
        };
    }
    const base_items = switch (args[0]) {
        .set => |s| s.items,
        .nil => return .nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "disj expects a set, got {s}", .{@tagName(args[0])}),
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
    new_set.* = .{ .items = items.items, .meta = if (args[0] == .set) args[0].set.meta else null, .comparator = if (args[0] == .set) args[0].set.comparator else null };
    return Value{ .set = new_set };
}

/// (find map key) — returns [key value] (MapEntry) or nil.
pub fn findFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find", .{args.len});
    return switch (args[0]) {
        .map => |m| {
            const v = m.get(args[1]) orelse return .nil;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = v;
            const vec = try allocator.create(PersistentVector);
            vec.* = .{ .items = pair };
            return Value{ .vector = vec };
        },
        .vector => |vec| {
            if (args[1] != .integer) return .nil;
            const idx = args[1].integer;
            if (idx < 0 or @as(usize, @intCast(idx)) >= vec.items.len) return .nil;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = vec.items[@intCast(idx)];
            const v = try allocator.create(PersistentVector);
            v.* = .{ .items = pair };
            return Value{ .vector = v };
        },
        .transient_vector => |tv| {
            if (args[1] != .integer) return .nil;
            const idx = args[1].integer;
            if (idx < 0 or @as(usize, @intCast(idx)) >= tv.items.items.len) return .nil;
            const pair = try allocator.alloc(Value, 2);
            pair[0] = args[1];
            pair[1] = tv.items.items[@intCast(idx)];
            const v = try allocator.create(PersistentVector);
            v.* = .{ .items = pair };
            return Value{ .vector = v };
        },
        .transient_map => |tm| {
            var i: usize = 0;
            while (i < tm.entries.items.len) : (i += 2) {
                if (tm.entries.items[i].eql(args[1])) {
                    const pair = try allocator.alloc(Value, 2);
                    pair[0] = args[1];
                    pair[1] = tm.entries.items[i + 1];
                    const v = try allocator.create(PersistentVector);
                    v.* = .{ .items = pair };
                    return Value{ .vector = v };
                }
            }
            return .nil;
        },
        .nil => .nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "find expects a map or vector, got {s}", .{@tagName(args[0])}),
    };
}

/// (peek coll) — stack top: last of vector, first of list.
pub fn peekFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to peek", .{args.len});
    return switch (args[0]) {
        .vector => |vec| if (vec.items.len > 0) vec.items[vec.items.len - 1] else .nil,
        .list => |lst| if (lst.items.len > 0) lst.items[0] else .nil,
        .nil => .nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "peek not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (pop coll) — stack pop: vector without last, list without first.
pub fn popFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop", .{args.len});
    return switch (args[0]) {
        .vector => |vec| {
            if (vec.items.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Can't pop empty vector", .{});
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = vec.items[0 .. vec.items.len - 1], .meta = vec.meta };
            return Value{ .vector = new_vec };
        },
        .list => |lst| {
            if (lst.items.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Can't pop empty list", .{});
            const new_lst = try allocator.create(PersistentList);
            new_lst.* = .{ .items = lst.items[1..], .meta = lst.meta };
            return Value{ .list = new_lst };
        },
        .nil => return .nil,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "pop not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (subvec v start) or (subvec v start end) — returns a subvector of v from start (inclusive) to end (exclusive).
pub fn subvecFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subvec", .{args.len});
    if (args[0] != .vector) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects a vector, got {s}", .{@tagName(args[0])});
    if (args[1] != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects integer start, got {s}", .{@tagName(args[1])});
    const v = args[0].vector;
    const start: usize = if (args[1].integer < 0) return err.setErrorFmt(.eval, .index_error, .{}, "subvec start index out of bounds: {d}", .{args[1].integer}) else @intCast(args[1].integer);
    const end: usize = if (args.len == 3) blk: {
        if (args[2] != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "subvec expects integer end, got {s}", .{@tagName(args[2])});
        break :blk if (args[2].integer < 0) return err.setErrorFmt(.eval, .index_error, .{}, "subvec end index out of bounds: {d}", .{args[2].integer}) else @intCast(args[2].integer);
    } else v.items.len;

    if (start > end or end > v.items.len) return err.setErrorFmt(.eval, .index_error, .{}, "subvec index out of bounds: start={d}, end={d}, size={d}", .{ start, end, v.items.len });
    const result = try allocator.create(PersistentVector);
    result.* = .{ .items = try allocator.dupe(Value, v.items[start..end]) };
    return Value{ .vector = result };
}

/// (array-map & kvs) — creates an array map from key-value pairs.
/// Like hash-map but guarantees insertion order (which our PersistentArrayMap already preserves).
pub fn arrayMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "array-map requires even number of args, got {d}", .{args.len});
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value{ .map = map };
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
    return Value{ .set = set };
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
    if (items.items.len > 1) try sortSetItems(allocator, items.items, Value.nil);
    const set = try allocator.create(PersistentHashSet);
    set.* = .{ .items = try allocator.dupe(Value, items.items), .comparator = Value.nil };
    items.deinit(allocator);
    return Value{ .set = set };
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
    return Value{ .set = set };
}

/// (sorted-map & kvs) — creates a map with entries sorted by key.
/// Uses natural ordering (compareValues). Stores comparator=.nil for natural ordering.
pub fn sortedMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "sorted-map requires even number of args, got {d}", .{args.len});
    if (args.len == 0) {
        const map = try allocator.create(PersistentArrayMap);
        map.* = .{ .entries = &.{}, .comparator = Value.nil };
        return Value{ .map = map };
    }
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);

    try sortMapEntries(allocator, entries, Value.nil);

    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries, .comparator = Value.nil };
    return Value{ .map = map };
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
        return Value{ .map = map };
    }
    const entries = try allocator.alloc(Value, kvs.len);
    @memcpy(entries, kvs);

    try sortMapEntries(allocator, entries, comp);

    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries, .comparator = comp };
    return Value{ .map = map };
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
fn compareWithComparator(allocator: Allocator, comparator: Value, a: Value, b: Value) anyerror!std.math.Order {
    if (comparator == .nil) {
        return compareValues(a, b);
    }
    // Custom comparator: call as Clojure function
    const result = try bootstrap.callFnVal(allocator, comparator, &.{ a, b });
    const n: i64 = switch (result) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |bv| if (bv) @as(i64, -1) else 0,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "comparator must return a number, got {s}", .{@tagName(result)}),
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
    const comp: Value = switch (sc) {
        .map => |m| m.comparator orelse return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection", .{}),
        .set => |s| s.comparator orelse return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection", .{}),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subseq requires a sorted collection, got {s}", .{@tagName(sc)}),
    };

    var result = std.ArrayList(Value).empty;

    if (sc == .map) {
        const entries = sc.map.entries;
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
                try result.append(allocator, Value{ .vector = vec });
            }
        }
    } else {
        // set
        const items = sc.set.items;
        for (items) |item| {
            if (try testEntry(allocator, comp, item, args)) {
                try result.append(allocator, item);
            }
        }
    }
    if (result.items.len == 0) return Value.nil;

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
    return Value{ .list = list };
}

/// Test whether an entry key passes the subseq test(s).
/// For 3-arg: (test (compare entry-key key) 0)
/// For 5-arg: (start-test (compare entry-key start-key) 0) AND (end-test (compare entry-key end-key) 0)
fn testEntry(allocator: Allocator, comp: Value, entry_key: Value, args: []const Value) anyerror!bool {
    const zero = Value{ .integer = 0 };

    if (args.len == 3) {
        const test_fn = args[1];
        const key = args[2];
        const cmp = try compareWithComparator(allocator, comp, entry_key, key);
        const cmp_int = Value{ .integer = switch (cmp) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } };
        const test_result = try bootstrap.callFnVal(allocator, test_fn, &.{ cmp_int, zero });
        return isTruthy(test_result);
    } else {
        // 5 args: sc start-test start-key end-test end-key
        const start_test = args[1];
        const start_key = args[2];
        const end_test = args[3];
        const end_key = args[4];

        const cmp_start = try compareWithComparator(allocator, comp, entry_key, start_key);
        const cmp_start_int = Value{ .integer = switch (cmp_start) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } };
        const start_result = try bootstrap.callFnVal(allocator, start_test, &.{ cmp_start_int, zero });
        if (!isTruthy(start_result)) return false;

        const cmp_end = try compareWithComparator(allocator, comp, entry_key, end_key);
        const cmp_end_int = Value{ .integer = switch (cmp_end) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } };
        const end_result = try bootstrap.callFnVal(allocator, end_test, &.{ cmp_end_int, zero });
        return isTruthy(end_result);
    }
}

fn isTruthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };
}

/// (empty coll) — empty collection of same type, or nil.
pub fn emptyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to empty", .{args.len});
    return switch (args[0]) {
        .vector => blk: {
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = &.{}, .meta = args[0].vector.meta };
            break :blk Value{ .vector = new_vec };
        },
        .list => blk: {
            const new_lst = try allocator.create(PersistentList);
            new_lst.* = .{ .items = &.{}, .meta = args[0].list.meta };
            break :blk Value{ .list = new_lst };
        },
        .map => blk: {
            const new_map = try allocator.create(PersistentArrayMap);
            new_map.* = .{ .entries = &.{}, .meta = args[0].map.meta, .comparator = args[0].map.comparator };
            break :blk Value{ .map = new_map };
        },
        .set => blk: {
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = &.{}, .meta = args[0].set.meta, .comparator = args[0].set.comparator };
            break :blk Value{ .set = new_set };
        },
        .nil => .nil,
        else => .nil,
    };
}

// ============================================================
// BuiltinDef table
// ============================================================

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
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

/// Simple addition for testing merge-with.
fn testAddFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .integer or args[1] != .integer) return error.TypeError;
    return Value{ .integer = args[0].integer + args[1].integer };
}

test "first on list" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var lst = PersistentList{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expect(result.eql(.{ .integer = 1 }));
}

test "first on empty list" {
    var lst = PersistentList{ .items = &.{} };
    const result = try firstFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expect(result.isNil());
}

test "first on nil" {
    const result = try firstFn(test_alloc, &.{Value.nil});
    try testing.expect(result.isNil());
}

test "first on vector" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 } };
    var vec = PersistentVector{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expect(result.eql(.{ .integer = 10 }));
}

test "rest on list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try restFn(arena.allocator(), &.{Value{ .list = &lst }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
}

test "rest on nil returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try restFn(arena.allocator(), &.{Value.nil});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "cons prepends to list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try consFn(arena.allocator(), &.{ Value{ .integer = 1 }, Value{ .list = &lst } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expect(result.list.first().eql(.{ .integer = 1 }));
}

test "cons onto nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try consFn(arena.allocator(), &.{ Value{ .integer = 1 }, Value.nil });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.count());
}

test "conj to list prepends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value{ .list = &lst }, Value{ .integer = 1 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expect(result.list.first().eql(.{ .integer = 1 }));
}

test "conj to vector appends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var vec = PersistentVector{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value{ .vector = &vec }, Value{ .integer = 3 } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.count());
    try testing.expect(result.vector.nth(2).?.eql(.{ .integer = 3 }));
}

test "conj nil returns list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try conjFn(arena.allocator(), &.{ Value.nil, Value{ .integer = 1 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.count());
}

test "assoc adds to map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "b", .ns = null } },
        Value{ .integer = 2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 2), result.map.count());
}

test "assoc replaces existing key" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "a", .ns = null } },
        Value{ .integer = 99 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
    const v = result.map.get(.{ .keyword = .{ .name = "a", .ns = null } });
    try testing.expect(v.?.eql(.{ .integer = 99 }));
}

test "assoc on vector replaces at index" {
    // (assoc [1 2 3] 1 99) => [1 99 3]
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var v = PersistentVector{ .items = &items };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .vector = &v },
        Value{ .integer = 1 },
        Value{ .integer = 99 },
    });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try testing.expect(result.vector.items[0].eql(.{ .integer = 1 }));
    try testing.expect(result.vector.items[1].eql(.{ .integer = 99 }));
    try testing.expect(result.vector.items[2].eql(.{ .integer = 3 }));
}

test "assoc on empty vector at index 0" {
    // (assoc [] 0 4) => [4]
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var v = PersistentVector{ .items = &.{} };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .vector = &v },
        Value{ .integer = 0 },
        Value{ .integer = 4 },
    });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 1), result.vector.items.len);
    try testing.expect(result.vector.items[0].eql(.{ .integer = 4 }));
}

test "assoc on vector out of bounds fails" {
    // (assoc [] 1 4) => error (index must be <= count)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var v = PersistentVector{ .items = &.{} };
    const result = assocFn(arena.allocator(), &.{
        Value{ .vector = &v },
        Value{ .integer = 1 },
        Value{ .integer = 4 },
    });
    try testing.expectError(error.IndexError, result);
}

test "get from map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "a", .ns = null } },
    });
    try testing.expect(result.eql(.{ .integer = 1 }));
}

test "get missing key returns nil" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "z", .ns = null } },
    });
    try testing.expect(result.isNil());
}

test "get with not-found" {
    const entries = [_]Value{};
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "z", .ns = null } },
        Value{ .integer = -1 },
    });
    try testing.expect(result.eql(.{ .integer = -1 }));
}

test "nth on vector" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 1 },
    });
    try testing.expect(result.eql(.{ .integer = 20 }));
}

test "nth out of bounds" {
    const items = [_]Value{ .{ .integer = 10 } };
    var vec = PersistentVector{ .items = &items };
    try testing.expectError(error.IndexError, nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 5 },
    }));
}

test "nth with not-found" {
    const items = [_]Value{ .{ .integer = 10 } };
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 5 },
        Value{ .integer = -1 },
    });
    try testing.expect(result.eql(.{ .integer = -1 }));
}

test "count on various types" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var lst = PersistentList{ .items = &items };
    var vec = PersistentVector{ .items = &items };

    try testing.expectEqual(Value{ .integer = 2 }, try countFn(test_alloc, &.{Value{ .list = &lst }}));
    try testing.expectEqual(Value{ .integer = 2 }, try countFn(test_alloc, &.{Value{ .vector = &vec }}));
    try testing.expectEqual(Value{ .integer = 0 }, try countFn(test_alloc, &.{Value.nil}));
    try testing.expectEqual(Value{ .integer = 5 }, try countFn(test_alloc, &.{Value{ .string = "hello" }}));
}

test "builtins table has 39 entries" {
    // 37 + 1 (__seq-to-map) + 1 (sorted-set) + 2 (sorted-map-by, sorted-set-by) + 2 (subseq, rsubseq)
    try testing.expectEqual(43, builtins.len);
}

test "reverse list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try reverseFn(alloc, &.{Value{ .list = &lst }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 3 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[2]);
}

test "reverse nil returns empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try reverseFn(arena.allocator(), &.{Value.nil});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.items.len);
}

test "apply with builtin_fn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (apply count [[1 2 3]]) -> 3
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var inner_vec = PersistentVector{ .items = &items };
    const arg_items = [_]Value{Value{ .vector = &inner_vec }};
    var arg_list = PersistentList{ .items = &arg_items };
    const result = try applyFn(alloc, &.{
        Value{ .builtin_fn = &countFn },
        Value{ .list = &arg_list },
    });
    try testing.expectEqual(Value{ .integer = 3 }, result);
}

test "merge two maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    const result = try mergeFn(alloc, &.{ Value{ .map = &m1 }, Value{ .map = &m2 } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 2), result.map.count());
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "a", .ns = null } }).?.eql(.{ .integer = 1 }));
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "b", .ns = null } }).?.eql(.{ .integer = 2 }));
}

test "merge with nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };

    // (merge nil {:a 1}) => {:a 1}
    const r1 = try mergeFn(alloc, &.{ .nil, Value{ .map = &m1 } });
    try testing.expect(r1 == .map);
    try testing.expectEqual(@as(usize, 1), r1.map.count());

    // (merge {:a 1} nil) => {:a 1}
    const r2 = try mergeFn(alloc, &.{ Value{ .map = &m1 }, .nil });
    try testing.expect(r2 == .map);
    try testing.expectEqual(@as(usize, 1), r2.map.count());

    // (merge nil nil) => nil
    const r3 = try mergeFn(alloc, &.{ .nil, .nil });
    try testing.expect(r3 == .nil);

    // (merge) => nil
    const r4 = try mergeFn(alloc, &.{});
    try testing.expect(r4 == .nil);
}

test "merge overlapping keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 99 },
        .{ .keyword = .{ .name = "c", .ns = null } }, .{ .integer = 3 },
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    const result = try mergeFn(alloc, &.{ Value{ .map = &m1 }, Value{ .map = &m2 } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 3), result.map.count());
    // :b should be overwritten by m2's value
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "b", .ns = null } }).?.eql(.{ .integer = 99 }));
}

test "merge-with merges with function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e1 = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m1 = PersistentArrayMap{ .entries = &e1 };
    const e2 = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 10 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m2 = PersistentArrayMap{ .entries = &e2 };

    // (merge-with + {:a 1} {:a 10 :b 2}) => {:a 11 :b 2}
    const result = try mergeWithFn(alloc, &.{
        Value{ .builtin_fn = &testAddFn },
        Value{ .map = &m1 },
        Value{ .map = &m2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 2), result.map.count());
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "a", .ns = null } }).?.eql(.{ .integer = 11 }));
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "b", .ns = null } }).?.eql(.{ .integer = 2 }));
}

test "zipmap basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (zipmap [:a :b :c] [1 2 3]) => {:a 1 :b 2 :c 3}
    const keys = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .keyword = .{ .name = "b", .ns = null } },
        .{ .keyword = .{ .name = "c", .ns = null } },
    };
    var key_vec = PersistentVector{ .items = &keys };
    const vals = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var val_vec = PersistentVector{ .items = &vals };

    const result = try zipmapFn(alloc, &.{ Value{ .vector = &key_vec }, Value{ .vector = &val_vec } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 3), result.map.count());
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "a", .ns = null } }).?.eql(.{ .integer = 1 }));
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "c", .ns = null } }).?.eql(.{ .integer = 3 }));
}

test "zipmap unequal lengths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (zipmap [:a :b] [1]) => {:a 1} — stops at shorter
    const keys = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .keyword = .{ .name = "b", .ns = null } },
    };
    var key_vec = PersistentVector{ .items = &keys };
    const vals = [_]Value{.{ .integer = 1 }};
    var val_vec = PersistentVector{ .items = &vals };

    const result = try zipmapFn(alloc, &.{ Value{ .vector = &key_vec }, Value{ .vector = &val_vec } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
}

test "zipmap empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var empty_vec = PersistentVector{ .items = &.{} };
    const result = try zipmapFn(alloc, &.{ Value{ .vector = &empty_vec }, Value{ .vector = &empty_vec } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 0), result.map.count());
}

test "compare integers" {
    const r1 = try compareFn(test_alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 } });
    try testing.expectEqual(Value{ .integer = -1 }, r1);
    const r2 = try compareFn(test_alloc, &.{ .{ .integer = 2 }, .{ .integer = 1 } });
    try testing.expectEqual(Value{ .integer = 1 }, r2);
    const r3 = try compareFn(test_alloc, &.{ .{ .integer = 5 }, .{ .integer = 5 } });
    try testing.expectEqual(Value{ .integer = 0 }, r3);
}

test "compare strings" {
    const r1 = try compareFn(test_alloc, &.{ .{ .string = "apple" }, .{ .string = "banana" } });
    try testing.expect(r1.integer < 0);
    const r2 = try compareFn(test_alloc, &.{ .{ .string = "banana" }, .{ .string = "apple" } });
    try testing.expect(r2.integer > 0);
    const r3 = try compareFn(test_alloc, &.{ .{ .string = "abc" }, .{ .string = "abc" } });
    try testing.expectEqual(Value{ .integer = 0 }, r3);
}

test "sort integers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    var vec = PersistentVector{ .items = &items };
    const result = try sortFn(alloc, &.{Value{ .vector = &vec }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[1]);
    try testing.expectEqual(Value{ .integer = 3 }, result.list.items[2]);
}

test "sort empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var empty_vec = PersistentVector{ .items = &.{} };
    const result = try sortFn(alloc, &.{Value{ .vector = &empty_vec }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.items.len);
}

test "sort-by with keyfn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // sort-by count ["bb" "a" "ccc"] => ["a" "bb" "ccc"]
    const items = [_]Value{ .{ .string = "bb" }, .{ .string = "a" }, .{ .string = "ccc" } };
    var vec = PersistentVector{ .items = &items };
    const result = try sortByFn(alloc, &.{
        Value{ .builtin_fn = &countFn },
        Value{ .vector = &vec },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expect(result.list.items[0].eql(.{ .string = "a" }));
    try testing.expect(result.list.items[1].eql(.{ .string = "bb" }));
    try testing.expect(result.list.items[2].eql(.{ .string = "ccc" }));
}

test "vec converts list to vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try vecFn(alloc, &.{Value{ .list = &lst }});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, result.vector.items[0]);
}

test "vec on nil returns empty vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try vecFn(arena.allocator(), &.{.nil});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 0), result.vector.items.len);
}

test "set converts vector to set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (set [1 2 2 3]) => #{1 2 3}
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var vec = PersistentVector{ .items = &items };
    const result = try setCoerceFn(alloc, &.{Value{ .vector = &vec }});
    try testing.expect(result == .set);
    try testing.expectEqual(@as(usize, 3), result.set.items.len);
}

test "list* creates list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (list* 1 2 [3 4]) => (1 2 3 4)
    const tail_items = [_]Value{ .{ .integer = 3 }, .{ .integer = 4 } };
    var tail_vec = PersistentVector{ .items = &tail_items };
    const result = try listStarFn(alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 }, Value{ .vector = &tail_vec } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[3]);
}

test "seq on map returns list of entry vectors" {
    const alloc = testing.allocator;
    var entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    const m = try alloc.create(PersistentArrayMap);
    defer alloc.destroy(m);
    m.* = .{ .entries = &entries };

    const result = try seqFn(alloc, &.{Value{ .map = m }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);

    // First entry: [:a 1]
    const e1 = result.list.items[0];
    try testing.expect(e1 == .vector);
    try testing.expectEqual(@as(usize, 2), e1.vector.items.len);
    try testing.expect(e1.vector.items[0].eql(.{ .keyword = .{ .name = "a", .ns = null } }));
    try testing.expectEqual(Value{ .integer = 1 }, e1.vector.items[1]);

    // Second entry: [:b 2]
    const e2 = result.list.items[1];
    try testing.expect(e2 == .vector);
    try testing.expectEqual(Value{ .integer = 2 }, e2.vector.items[1]);

    // Cleanup
    alloc.free(e1.vector.items);
    alloc.destroy(e1.vector);
    alloc.free(e2.vector.items);
    alloc.destroy(e2.vector);
    alloc.free(result.list.items);
    alloc.destroy(result.list);
}

test "seq on empty map returns nil" {
    const alloc = testing.allocator;
    const m = try alloc.create(PersistentArrayMap);
    defer alloc.destroy(m);
    m.* = .{ .entries = &.{} };

    const result = try seqFn(alloc, &.{Value{ .map = m }});
    try testing.expectEqual(Value.nil, result);
}

test "seq on set returns list of elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var s = PersistentHashSet{ .items = &items };
    const result = try seqFn(alloc, &.{Value{ .set = &s }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
}

test "seq on empty set returns nil" {
    const alloc = testing.allocator;
    const s = try alloc.create(PersistentHashSet);
    defer alloc.destroy(s);
    s.* = .{ .items = &.{} };

    const result = try seqFn(alloc, &.{Value{ .set = s }});
    try testing.expectEqual(Value.nil, result);
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
        .{ .keyword = .{ .ns = null, .name = "a" } }, .{ .integer = 1 },
        .{ .keyword = .{ .ns = null, .name = "b" } }, .{ .integer = 2 },
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try dissocFn(alloc, &.{ Value{ .map = m }, .{ .keyword = .{ .ns = null, .name = "a" } } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
    try testing.expect(result.map.get(.{ .keyword = .{ .ns = null, .name = "b" } }) != null);
    try testing.expect(result.map.get(.{ .keyword = .{ .ns = null, .name = "a" } }) == null);
}

test "dissoc on nil returns nil" {
    const result = try dissocFn(test_alloc, &.{ Value.nil, .{ .keyword = .{ .ns = null, .name = "a" } } });
    try testing.expectEqual(Value.nil, result);
}

test "dissoc missing key is identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "a" } }, .{ .integer = 1 },
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try dissocFn(alloc, &.{ Value{ .map = m }, .{ .keyword = .{ .ns = null, .name = "z" } } });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
}

// --- disj tests ---

test "disj removes value from set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const s = try alloc.create(PersistentHashSet);
    s.* = .{ .items = &items };

    const result = try disjFn(alloc, &.{ Value{ .set = s }, .{ .integer = 2 } });
    try testing.expect(result == .set);
    try testing.expectEqual(@as(usize, 2), result.set.count());
    try testing.expect(!result.set.contains(.{ .integer = 2 }));
    try testing.expect(result.set.contains(.{ .integer = 1 }));
    try testing.expect(result.set.contains(.{ .integer = 3 }));
}

test "disj on nil returns nil" {
    const result = try disjFn(test_alloc, &.{ Value.nil, .{ .integer = 1 } });
    try testing.expectEqual(Value.nil, result);
}

// --- find tests ---

test "find returns MapEntry vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "a" } }, .{ .integer = 1 },
        .{ .keyword = .{ .ns = null, .name = "b" } }, .{ .integer = 2 },
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try findFn(alloc, &.{ Value{ .map = m }, .{ .keyword = .{ .ns = null, .name = "a" } } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.items.len);
    try testing.expect(result.vector.items[0].eql(.{ .keyword = .{ .ns = null, .name = "a" } }));
    try testing.expect(result.vector.items[1].eql(.{ .integer = 1 }));
}

test "find returns nil for missing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        .{ .keyword = .{ .ns = null, .name = "a" } }, .{ .integer = 1 },
    };
    const m = try alloc.create(PersistentArrayMap);
    m.* = .{ .entries = &entries };

    const result = try findFn(alloc, &.{ Value{ .map = m }, .{ .keyword = .{ .ns = null, .name = "z" } } });
    try testing.expectEqual(Value.nil, result);
}

// --- peek tests ---

test "peek on vector returns last element" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const vec = PersistentVector{ .items = &items };
    const result = try peekFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expect(result.eql(.{ .integer = 3 }));
}

test "peek on list returns first element" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 } };
    const lst = PersistentList{ .items = &items };
    const result = try peekFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expect(result.eql(.{ .integer = 10 }));
}

test "peek on nil returns nil" {
    const result = try peekFn(test_alloc, &.{Value.nil});
    try testing.expectEqual(Value.nil, result);
}

test "peek on empty vector returns nil" {
    const vec = PersistentVector{ .items = &.{} };
    const result = try peekFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectEqual(Value.nil, result);
}

// --- pop tests ---

test "pop on vector removes last element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try popFn(alloc, &.{Value{ .vector = vec }});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.items.len);
    try testing.expect(result.vector.items[0].eql(.{ .integer = 1 }));
    try testing.expect(result.vector.items[1].eql(.{ .integer = 2 }));
}

test "pop on list removes first element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    const lst = try alloc.create(PersistentList);
    lst.* = .{ .items = &items };

    const result = try popFn(alloc, &.{Value{ .list = lst }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);
    try testing.expect(result.list.items[0].eql(.{ .integer = 20 }));
    try testing.expect(result.list.items[1].eql(.{ .integer = 30 }));
}

test "pop on empty vector is error" {
    const vec = PersistentVector{ .items = &.{} };
    const result = popFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectError(error.ValueError, result);
}

test "pop on nil returns nil" {
    const result = try popFn(test_alloc, &.{Value.nil});
    try testing.expectEqual(Value.nil, result);
}

// --- empty tests ---

test "empty on vector returns empty vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try emptyFn(alloc, &.{Value{ .vector = vec }});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 0), result.vector.items.len);
}

test "empty on nil returns nil" {
    const result = try emptyFn(test_alloc, &.{Value.nil});
    try testing.expectEqual(Value.nil, result);
}

test "empty on string returns nil" {
    const result = try emptyFn(test_alloc, &.{Value{ .string = "abc" }});
    try testing.expectEqual(Value.nil, result);
}

// --- subvec tests ---

test "subvec with start and end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 }, .{ .integer = 4 }, .{ .integer = 5 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try subvecFn(alloc, &.{ Value{ .vector = vec }, Value{ .integer = 1 }, Value{ .integer = 4 } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.count());
    try testing.expect(result.vector.nth(0).?.eql(.{ .integer = 2 }));
    try testing.expect(result.vector.nth(1).?.eql(.{ .integer = 3 }));
    try testing.expect(result.vector.nth(2).?.eql(.{ .integer = 4 }));
}

test "subvec with start only (end defaults to length)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try subvecFn(alloc, &.{ Value{ .vector = vec }, Value{ .integer = 1 } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.count());
    try testing.expect(result.vector.nth(0).?.eql(.{ .integer = 20 }));
}

test "subvec out of bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    try testing.expectError(error.IndexError, subvecFn(alloc, &.{ Value{ .vector = vec }, Value{ .integer = 0 }, Value{ .integer = 5 } }));
}

test "subvec on non-vector is error" {
    try testing.expectError(error.TypeError, subvecFn(test_alloc, &.{ Value{ .integer = 42 }, Value{ .integer = 0 } }));
}

// --- array-map tests ---

test "array-map creates map from key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try arrayMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 2), result.map.count());
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "a", .ns = null } }).?.eql(.{ .integer = 1 }));
    try testing.expect(result.map.get(.{ .keyword = .{ .name = "b", .ns = null } }).?.eql(.{ .integer = 2 }));
}

test "array-map with no args returns empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try arrayMapFn(arena.allocator(), &.{});
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 0), result.map.count());
}

test "array-map with odd args is error" {
    try testing.expectError(error.ArityError, arrayMapFn(test_alloc, &.{Value{ .keyword = .{ .name = "a", .ns = null } }}));
}

// --- hash-set tests ---

test "hash-set creates set from values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try hashSetFn(alloc, &.{ Value{ .integer = 1 }, Value{ .integer = 2 }, Value{ .integer = 3 } });
    try testing.expect(result == .set);
    try testing.expectEqual(@as(usize, 3), result.set.count());
    try testing.expect(result.set.contains(.{ .integer = 1 }));
    try testing.expect(result.set.contains(.{ .integer = 2 }));
    try testing.expect(result.set.contains(.{ .integer = 3 }));
}

test "hash-set deduplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try hashSetFn(alloc, &.{ Value{ .integer = 1 }, Value{ .integer = 1 }, Value{ .integer = 2 } });
    try testing.expect(result == .set);
    try testing.expectEqual(@as(usize, 2), result.set.count());
}

test "hash-set with no args returns empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try hashSetFn(arena.allocator(), &.{});
    try testing.expect(result == .set);
    try testing.expectEqual(@as(usize, 0), result.set.count());
}

// --- sorted-map tests ---

test "sorted-map creates map with sorted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "c", .ns = null } }, Value{ .integer = 3 },
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 3), result.map.count());
    // Keys should be sorted: :a, :b, :c
    // Entries are [k1,v1,k2,v2,...] so sorted order means entries[0]=:a, entries[2]=:b, entries[4]=:c
    try testing.expect(result.map.entries[0].eql(.{ .keyword = .{ .name = "a", .ns = null } }));
    try testing.expect(result.map.entries[2].eql(.{ .keyword = .{ .name = "b", .ns = null } }));
    try testing.expect(result.map.entries[4].eql(.{ .keyword = .{ .name = "c", .ns = null } }));
}

test "sorted-map with no args returns empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try sortedMapFn(arena.allocator(), &.{});
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 0), result.map.count());
}

test "sorted-map with odd args is error" {
    try testing.expectError(error.ArityError, sortedMapFn(test_alloc, &.{Value{ .integer = 1 }}));
}

test "sorted-map stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
    });
    try testing.expect(result == .map);
    // sorted-map stores .nil as natural ordering sentinel
    try testing.expect(result.map.comparator != null);
    try testing.expect(result.map.comparator.? == .nil);
}

test "sorted-map empty stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try sortedMapFn(arena.allocator(), &.{});
    try testing.expect(result == .map);
    try testing.expect(result.map.comparator != null);
    try testing.expect(result.map.comparator.? == .nil);
}

test "assoc on sorted-map maintains sort order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create sorted map with :a and :c
    const sm = try sortedMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "c", .ns = null } }, Value{ .integer = 3 },
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
    });
    // assoc :b — should sort into the middle
    const result = try assocFn(alloc, &.{
        sm,
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 3), result.map.count());
    // Keys should be sorted: :a, :b, :c
    try testing.expect(result.map.entries[0].eql(.{ .keyword = .{ .name = "a", .ns = null } }));
    try testing.expect(result.map.entries[2].eql(.{ .keyword = .{ .name = "b", .ns = null } }));
    try testing.expect(result.map.entries[4].eql(.{ .keyword = .{ .name = "c", .ns = null } }));
    // Comparator propagated
    try testing.expect(result.map.comparator != null);
    try testing.expect(result.map.comparator.? == .nil);
}

test "dissoc on sorted-map preserves comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sm = try sortedMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
    });
    const result = try dissocFn(alloc, &.{
        sm,
        Value{ .keyword = .{ .name = "b", .ns = null } },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
    try testing.expect(result.map.comparator != null);
}

test "sorted-set stores natural ordering comparator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try sortedSetFn(alloc, &.{
        Value{ .integer = 3 }, Value{ .integer = 1 }, Value{ .integer = 2 },
    });
    try testing.expect(result == .set);
    // Items should be sorted: 1, 2, 3
    try testing.expectEqual(@as(usize, 3), result.set.count());
    try testing.expect(result.set.items[0].eql(Value{ .integer = 1 }));
    try testing.expect(result.set.items[1].eql(Value{ .integer = 2 }));
    try testing.expect(result.set.items[2].eql(Value{ .integer = 3 }));
    // Comparator stored
    try testing.expect(result.set.comparator != null);
    try testing.expect(result.set.comparator.? == .nil);
}

// --- subseq / rsubseq tests ---

const arith = @import("arithmetic.zig");

test "subseq on sorted-map with >" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-map :a 1 :b 2 :c 3)
    const sm = try sortedMapFn(alloc, &.{
        Value{ .keyword = .{ .name = "c", .ns = null } }, Value{ .integer = 3 },
        Value{ .keyword = .{ .name = "a", .ns = null } }, Value{ .integer = 1 },
        Value{ .keyword = .{ .name = "b", .ns = null } }, Value{ .integer = 2 },
    });

    // (subseq sm > :a) => ([:b 2] [:c 3])
    const gt_fn = Value{ .builtin_fn = arith.builtins[9].func.? }; // ">"
    const result = try subseqFn(alloc, &.{ sm, gt_fn, Value{ .keyword = .{ .name = "a", .ns = null } } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);
    // First entry should be [:b 2]
    try testing.expect(result.list.items[0] == .vector);
    try testing.expect(result.list.items[0].vector.items[0].eql(.{ .keyword = .{ .name = "b", .ns = null } }));
}

test "subseq on sorted-set with >=" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-set 1 2 3 4 5)
    const ss = try sortedSetFn(alloc, &.{
        Value{ .integer = 3 }, Value{ .integer = 1 }, Value{ .integer = 5 },
        Value{ .integer = 2 }, Value{ .integer = 4 },
    });

    // (subseq ss >= 3) => (3 4 5)
    const ge_fn = Value{ .builtin_fn = arith.builtins[11].func.? }; // ">="
    const result = try subseqFn(alloc, &.{ ss, ge_fn, Value{ .integer = 3 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expect(result.list.items[0].eql(Value{ .integer = 3 }));
    try testing.expect(result.list.items[1].eql(Value{ .integer = 4 }));
    try testing.expect(result.list.items[2].eql(Value{ .integer = 5 }));
}

test "rsubseq on sorted-set with <=" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (sorted-set 1 2 3 4 5)
    const ss = try sortedSetFn(alloc, &.{
        Value{ .integer = 3 }, Value{ .integer = 1 }, Value{ .integer = 5 },
        Value{ .integer = 2 }, Value{ .integer = 4 },
    });

    // (rsubseq ss <= 3) => (3 2 1)
    const le_fn = Value{ .builtin_fn = arith.builtins[10].func.? }; // "<="
    const result = try rsubseqFn(alloc, &.{ ss, le_fn, Value{ .integer = 3 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expect(result.list.items[0].eql(Value{ .integer = 3 }));
    try testing.expect(result.list.items[1].eql(Value{ .integer = 2 }));
    try testing.expect(result.list.items[2].eql(Value{ .integer = 1 }));
}
