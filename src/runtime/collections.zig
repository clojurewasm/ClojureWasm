// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Persistent collection types for ClojureWasm.
//!
//! Implements persistent vectors (32-way trie), hash maps (HAMT),
//! hash sets, sorted maps/sets, and cons-based lists.

const std = @import("std");
const Value = @import("value.zig").Value;

const testing = std.testing;

/// Global generation counter for vector COW (Copy-on-Write) optimization.
///
/// Each vector conj increments this counter and stores it in the backing array's
/// hidden gen slot. When a subsequent conj checks the slot, matching generation
/// means this vector exclusively owns the tail — safe to extend in-place (O(1)).
/// Mismatching generation means another vector branched from the same backing —
/// a copy with geometric growth is needed to preserve persistent semantics.
///
/// Monotonically increasing; never decremented or reset.
/// Atomic for thread safety (Phase 48).
pub var _vec_gen_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// Persistent list — array-backed for initial simplicity.
pub const PersistentList = struct {
    items: []const Value,
    meta: ?*const Value = null,
    source_line: u32 = 0,
    source_column: u16 = 0,
    /// Per-child source positions for macro expansion roundtrip preservation.
    /// Parallel to items[]. Set by formToValue, read by valueToForm.
    child_lines: ?[]const u32 = null,
    child_columns: ?[]const u16 = null,

    pub fn count(self: PersistentList) usize {
        return self.items.len;
    }

    pub fn first(self: PersistentList) Value {
        if (self.items.len == 0) return Value.nil_val;
        return self.items[0];
    }

    pub fn rest(self: PersistentList) PersistentList {
        if (self.items.len == 0) return .{ .items = &.{} };
        return .{ .items = self.items[1..] };
    }
};

/// Persistent vector — array-backed with geometric growth optimization.
///
/// When created via conj with geometric growth, the backing array has
/// `_capacity + 1` Value slots. The last slot (index _capacity) stores
/// a generation tag (Value.integer) for copy-on-write detection.
/// Sequential conj extends in-place when gen matches; branching triggers copy.
pub const PersistentVector = struct {
    items: []const Value,
    meta: ?*const Value = null,
    source_line: u32 = 0,
    source_column: u16 = 0,
    /// Per-child source positions for macro expansion roundtrip preservation.
    child_lines: ?[]const u32 = null,
    child_columns: ?[]const u16 = null,
    /// Geometric growth backing capacity (0 = no growth backing).
    _capacity: usize = 0,
    /// This vector's generation for COW detection.
    _gen: i64 = 0,

    pub fn count(self: PersistentVector) usize {
        return self.items.len;
    }

    pub fn nth(self: PersistentVector, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }
};

/// Mutable array — Java array equivalent for ClojureWasm.
/// Single-dimensional, typed (element_type for compatibility, all stored as Value).
pub const ZigArray = struct {
    items: []Value,
    element_type: ElementType = .object,

    pub const ElementType = enum {
        object, int, long, float, double, boolean, byte, short, char,
    };

    pub fn count(self: ZigArray) usize {
        return self.items.len;
    }
};

/// BigInt — arbitrary precision integer backed by Zig's std.math.big.int.
/// Immutable value semantics: arithmetic returns new BigInt.
pub const BigInt = struct {
    managed: std.math.big.int.Managed,

    pub fn initFromI64(allocator: std.mem.Allocator, val: i64) !*BigInt {
        const bi = try allocator.create(BigInt);
        bi.managed = try std.math.big.int.Managed.initSet(allocator, val);
        return bi;
    }

    /// Parse BigInt from decimal digit string (e.g. "42", "-99999999999999999999").
    /// String may have leading '-' for negative.
    pub fn initFromString(allocator: std.mem.Allocator, text: []const u8) !*BigInt {
        const bi = try allocator.create(BigInt);
        bi.managed = try std.math.big.int.Managed.init(allocator);
        var s = text;
        var negative = false;
        if (s.len > 0 and s[0] == '-') {
            negative = true;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '+') {
            s = s[1..];
        }
        bi.managed.setString(10, s) catch return error.InvalidCharacter;
        if (negative) bi.managed.negate();
        return bi;
    }

    pub fn toI64(self: *const BigInt) ?i64 {
        return self.managed.toInt(i64) catch null;
    }

    pub fn toF64(self: *const BigInt) f64 {
        return self.managed.toFloat(f64, .nearest_even)[0];
    }

    /// Convert to owned decimal string (e.g. "42", "-123").
    pub fn toStringAlloc(self: *const BigInt, allocator: std.mem.Allocator) ![]const u8 {
        const c = self.managed.toConst();
        var limbs_buf: [128]std.math.big.Limb = undefined;
        var str_buf: [512]u8 = undefined;
        const len = c.toString(&str_buf, 10, .lower, &limbs_buf);
        return allocator.dupe(u8, str_buf[0..len]);
    }
};

/// Discriminator for NanHeapTag slot 30 (shared by Ratio and BigDecimal).
/// MUST be the first field in both Ratio and BigDecimal structs.
pub const NumericExtKind = enum(u8) { ratio, big_decimal };

/// Ratio — exact rational number as numerator/denominator BigInt pair.
/// Always stored in reduced form (GCD=1, denominator positive).
pub const Ratio = extern struct {
    kind: NumericExtKind = .ratio, // MUST be at offset 0 (tag discriminator)
    numerator: *BigInt,
    denominator: *BigInt,

    /// Create a reduced ratio from two BigInt values.
    /// Normalizes: GCD=1, denominator > 0.
    /// If denominator divides numerator evenly, returns null (caller should use integer).
    pub fn initReduced(allocator: std.mem.Allocator, num: *BigInt, den: *BigInt) !?*Ratio {
        // Compute GCD
        const gcd_bi = try allocator.create(BigInt);
        gcd_bi.managed = try std.math.big.int.Managed.init(allocator);

        // Use Zig's big int GCD: gcd(|num|, |den|)
        var abs_num = try allocator.create(BigInt);
        abs_num.managed = try std.math.big.int.Managed.init(allocator);
        try abs_num.managed.copy(num.managed.toConst());
        abs_num.managed.setSign(true); // make positive

        var abs_den = try allocator.create(BigInt);
        abs_den.managed = try std.math.big.int.Managed.init(allocator);
        try abs_den.managed.copy(den.managed.toConst());
        abs_den.managed.setSign(true); // make positive

        // GCD computation using Euclidean algorithm
        try bigIntGcd(&gcd_bi.managed, &abs_num.managed, &abs_den.managed);

        // Reduce: num/gcd, den/gcd
        const r_num = try allocator.create(BigInt);
        r_num.managed = try std.math.big.int.Managed.init(allocator);
        var r_num_rem = try std.math.big.int.Managed.init(allocator);
        r_num.managed.divTrunc(&r_num_rem, &num.managed, &gcd_bi.managed) catch return error.OutOfMemory;

        const r_den = try allocator.create(BigInt);
        r_den.managed = try std.math.big.int.Managed.init(allocator);
        var r_den_rem = try std.math.big.int.Managed.init(allocator);
        r_den.managed.divTrunc(&r_den_rem, &den.managed, &gcd_bi.managed) catch return error.OutOfMemory;

        // Normalize sign: denominator always positive
        if (!r_den.managed.isPositive()) {
            r_num.managed.negate();
            r_den.managed.negate();
        }

        // If denominator is 1, return null (caller should use integer)
        if (r_den.managed.toConst().orderAgainstScalar(1) == .eq) {
            return null;
        }

        const ratio = try allocator.create(Ratio);
        ratio.kind = .ratio;
        ratio.numerator = r_num;
        ratio.denominator = r_den;
        return ratio;
    }

    /// Create a Ratio from two i64 values. Returns null if result is integer.
    pub fn initFromI64(allocator: std.mem.Allocator, num: i64, den: i64) !?*Ratio {
        const n = try BigInt.initFromI64(allocator, num);
        const d = try BigInt.initFromI64(allocator, den);
        return initReduced(allocator, n, d);
    }

    /// Create from string numerator/denominator (e.g. "22", "7").
    pub fn initFromStrings(allocator: std.mem.Allocator, num_str: []const u8, den_str: []const u8) !?*Ratio {
        const n = try BigInt.initFromString(allocator, num_str);
        const d = try BigInt.initFromString(allocator, den_str);
        return initReduced(allocator, n, d);
    }

    pub fn toF64(self: *const Ratio) f64 {
        return self.numerator.toF64() / self.denominator.toF64();
    }
};

/// Euclidean GCD for big integers. result = gcd(a, b).
fn bigIntGcd(result: *std.math.big.int.Managed, a: *std.math.big.int.Managed, b: *std.math.big.int.Managed) !void {
    // Simple Euclidean: gcd(a, 0) = a, gcd(a, b) = gcd(b, a mod b)
    var x = try std.math.big.int.Managed.init(a.allocator);
    try x.copy(a.toConst());
    x.setSign(true);

    var y = try std.math.big.int.Managed.init(a.allocator);
    try y.copy(b.toConst());
    y.setSign(true);

    var temp = try std.math.big.int.Managed.init(a.allocator);
    var quotient = try std.math.big.int.Managed.init(a.allocator);

    while (!y.toConst().eqlZero()) {
        try temp.copy(y.toConst());
        quotient.divTrunc(&y, &x, &temp) catch return error.OutOfMemory;
        // Now y = x mod temp, we need: x = temp (old y), y = remainder
        // divTrunc puts quotient in quotient, remainder in y
        try x.copy(temp.toConst());
    }
    try result.copy(x.toConst());
}

/// BigDecimal — arbitrary-precision decimal (unscaled BigInt + i32 scale).
/// Value = unscaled_value × 10^(-scale).
/// Example: 42.5 → unscaled=425, scale=1.
pub const BigDecimal = extern struct {
    kind: NumericExtKind = .big_decimal, // MUST be at offset 0 (tag discriminator)
    unscaled: *BigInt,
    scale: i32,

    /// Create from integer value (scale=0).
    pub fn initFromI64(allocator: std.mem.Allocator, val: i64) !*BigDecimal {
        const bd = try allocator.create(BigDecimal);
        bd.kind = .big_decimal;
        bd.unscaled = try BigInt.initFromI64(allocator, val);
        bd.scale = 0;
        return bd;
    }

    /// Create from string like "42.5", "123", "-3.14", "1.0e+1", "1e10".
    pub fn initFromString(allocator: std.mem.Allocator, text: []const u8) !*BigDecimal {
        const bd = try allocator.create(BigDecimal);
        bd.kind = .big_decimal;

        // Split off exponent part (e.g. "1.0e+1" → mantissa="1.0", exp=1)
        var mantissa = text;
        var exponent: i32 = 0;
        if (std.mem.indexOfScalar(u8, text, 'e') orelse std.mem.indexOfScalar(u8, text, 'E')) |e_pos| {
            mantissa = text[0..e_pos];
            const exp_str = text[e_pos + 1 ..];
            exponent = std.fmt.parseInt(i32, exp_str, 10) catch return error.InvalidCharacter;
        }

        // Parse mantissa (may have decimal point)
        var base_scale: i32 = 0;
        if (std.mem.indexOfScalar(u8, mantissa, '.')) |dot_pos| {
            // Has decimal point: "1.0" → digits="10", base_scale=1
            const frac_len = mantissa.len - dot_pos - 1;
            base_scale = @intCast(frac_len);
            const buf = try allocator.alloc(u8, mantissa.len - 1);
            @memcpy(buf[0..dot_pos], mantissa[0..dot_pos]);
            @memcpy(buf[dot_pos..], mantissa[dot_pos + 1 ..]);
            bd.unscaled = try BigInt.initFromString(allocator, buf);
        } else {
            // No decimal point
            bd.unscaled = try BigInt.initFromString(allocator, mantissa);
        }

        // Apply exponent: effective scale = base_scale - exponent
        bd.scale = base_scale - exponent;
        return bd;
    }

    /// Convert to f64.
    pub fn toF64(self: *const BigDecimal) f64 {
        const mantissa = self.unscaled.toF64();
        if (self.scale == 0) return mantissa;
        const divisor = std.math.pow(f64, 10.0, @floatFromInt(self.scale));
        return mantissa / divisor;
    }

    /// Convert to string (e.g., "42.5", "123", "0.001").
    pub fn toStringAlloc(self: *const BigDecimal, allocator: std.mem.Allocator) ![]const u8 {
        const digits = self.unscaled.toStringAlloc(allocator) catch return error.OutOfMemory;
        if (self.scale <= 0) {
            if (self.scale == 0) return digits;
            // Negative scale: append zeros
            const zeros: usize = @intCast(-self.scale);
            const buf = try allocator.alloc(u8, digits.len + zeros);
            @memcpy(buf[0..digits.len], digits);
            @memset(buf[digits.len..], '0');
            return buf;
        }
        // Positive scale: insert decimal point
        const scale_u: usize = @intCast(self.scale);
        const negative = digits.len > 0 and digits[0] == '-';
        const abs_digits = if (negative) digits[1..] else digits;
        if (scale_u >= abs_digits.len) {
            // Need leading zeros: "5" with scale=3 → "0.005"
            const prefix = if (negative) "-0." else "0.";
            const leading_zeros = scale_u - abs_digits.len;
            const buf = try allocator.alloc(u8, prefix.len + leading_zeros + abs_digits.len);
            @memcpy(buf[0..prefix.len], prefix);
            @memset(buf[prefix.len .. prefix.len + leading_zeros], '0');
            @memcpy(buf[prefix.len + leading_zeros ..], abs_digits);
            return buf;
        }
        // Normal case: "425" with scale=1 → "42.5"
        const int_len = abs_digits.len - scale_u;
        const prefix_len: usize = if (negative) 1 else 0;
        const buf = try allocator.alloc(u8, prefix_len + int_len + 1 + scale_u);
        var pos: usize = 0;
        if (negative) {
            buf[0] = '-';
            pos = 1;
        }
        @memcpy(buf[pos .. pos + int_len], abs_digits[0..int_len]);
        pos += int_len;
        buf[pos] = '.';
        pos += 1;
        @memcpy(buf[pos..], abs_digits[int_len..]);
        return buf;
    }
};

/// Persistent array map — flat key-value pairs [k1,v1,k2,v2,...].
/// Insertion-order preserving. Linear scan for lookup.
pub const PersistentArrayMap = struct {
    entries: []const Value,
    meta: ?*const Value = null,
    /// Custom comparator for sorted-map-by (fn of 2 args → negative/0/positive).
    /// null for regular maps and sorted-map (natural ordering).
    comparator: ?Value = null,

    pub fn count(self: PersistentArrayMap) usize {
        return self.entries.len / 2;
    }

    pub fn get(self: PersistentArrayMap, key: Value) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (self.entries[i].eql(key)) return self.entries[i + 1];
        }
        return null;
    }

    /// Look up a value by raw string key (matching string-tagged entries).
    /// Avoids allocating a temporary HeapString Value for the lookup.
    pub fn getByStringKey(self: PersistentArrayMap, key: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (self.entries[i].tag() == .string and std.mem.eql(u8, self.entries[i].asString(), key))
                return self.entries[i + 1];
        }
        return null;
    }
};

/// Persistent hash set — array-backed with linear scan.
pub const PersistentHashSet = struct {
    items: []const Value,
    meta: ?*const Value = null,
    /// Custom comparator for sorted-set-by (fn of 2 args → negative/0/positive).
    /// .nil for sorted-set (natural ordering), null for regular sets.
    comparator: ?Value = null,

    pub fn count(self: PersistentHashSet) usize {
        return self.items.len;
    }

    pub fn contains(self: PersistentHashSet, val: Value) bool {
        for (self.items) |item| {
            if (item.eql(val)) return true;
        }
        return false;
    }

    /// Returns the actual stored element that equals val, or null.
    /// Unlike contains(), this returns the set's own element (preserving metadata).
    pub fn get(self: PersistentHashSet, val: Value) ?Value {
        for (self.items) |item| {
            if (item.eql(val)) return item;
        }
        return null;
    }
};

/// Transient vector — mutable builder for PersistentVector.
/// Created via (transient [1 2 3]), mutated via conj!/assoc!/pop!,
/// finalized via (persistent! tv).
pub const TransientVector = struct {
    items: std.ArrayList(Value) = .empty,
    consumed: bool = false,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentVector) !*TransientVector {
        const tv = try allocator.create(TransientVector);
        tv.* = .{};
        try tv.items.appendSlice(allocator, source.items);
        return tv;
    }

    pub fn ensureEditable(self: *TransientVector) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientVector) usize {
        return self.items.items.len;
    }

    pub fn conj(self: *TransientVector, allocator: std.mem.Allocator, val: Value) !*TransientVector {
        try self.ensureEditable();
        try self.items.append(allocator, val);
        return self;
    }

    pub fn assocAt(self: *TransientVector, allocator: std.mem.Allocator, index: usize, val: Value) !*TransientVector {
        try self.ensureEditable();
        if (index > self.items.items.len) return error.IndexOutOfBounds;
        if (index == self.items.items.len) {
            // Append at end (like assoc on vector with count as index)
            try self.items.append(allocator, val);
            return self;
        }
        self.items.items[index] = val;
        return self;
    }

    pub fn pop(self: *TransientVector) !*TransientVector {
        try self.ensureEditable();
        if (self.items.items.len == 0) return error.CantPopEmpty;
        _ = self.items.pop();
        return self;
    }

    pub fn persistent(self: *TransientVector, allocator: std.mem.Allocator) !*const PersistentVector {
        try self.ensureEditable();
        self.consumed = true;
        const items = try allocator.alloc(Value, self.items.items.len);
        @memcpy(items, self.items.items);
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = items };
        return vec;
    }
};

/// Transient array map — mutable builder for PersistentArrayMap.
pub const TransientArrayMap = struct {
    entries: std.ArrayList(Value) = .empty,
    consumed: bool = false,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentArrayMap) !*TransientArrayMap {
        const tm = try allocator.create(TransientArrayMap);
        tm.* = .{};
        try tm.entries.appendSlice(allocator, source.entries);
        return tm;
    }

    pub fn ensureEditable(self: *TransientArrayMap) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientArrayMap) usize {
        return self.entries.items.len / 2;
    }

    pub fn assocKV(self: *TransientArrayMap, allocator: std.mem.Allocator, key: Value, val: Value) !*TransientArrayMap {
        try self.ensureEditable();
        // Check if key already exists
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 2) {
            if (self.entries.items[i].eql(key)) {
                self.entries.items[i + 1] = val;
                return self;
            }
        }
        // New key — append
        try self.entries.append(allocator, key);
        try self.entries.append(allocator, val);
        return self;
    }

    pub fn dissocKey(self: *TransientArrayMap, key: Value) !*TransientArrayMap {
        try self.ensureEditable();
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 2) {
            if (self.entries.items[i].eql(key)) {
                // Swap-remove: move last pair into this slot
                const last = self.entries.items.len;
                if (i + 2 < last) {
                    self.entries.items[i] = self.entries.items[last - 2];
                    self.entries.items[i + 1] = self.entries.items[last - 1];
                }
                self.entries.items.len -= 2;
                return self;
            }
        }
        return self; // key not found — no-op
    }

    pub fn conjEntry(self: *TransientArrayMap, allocator: std.mem.Allocator, entry: Value) !*TransientArrayMap {
        try self.ensureEditable();
        // entry must be a vector of [key val]
        switch (entry.tag()) {
            .vector => {
                const vec = entry.asVector();
                if (vec.items.len != 2) return error.MapEntryMustBePair;
                return self.assocKV(allocator, vec.items[0], vec.items[1]);
            },
            .map => {
                const m = entry.asMap();
                // Merge map entries
                var i: usize = 0;
                while (i < m.entries.len) : (i += 2) {
                    _ = try self.assocKV(allocator, m.entries[i], m.entries[i + 1]);
                }
                return self;
            },
            else => return error.MapConjRequiresVectorOrMap,
        }
    }

    pub fn persistent(self: *TransientArrayMap, allocator: std.mem.Allocator) !*const PersistentArrayMap {
        try self.ensureEditable();
        self.consumed = true;
        const entries = try allocator.alloc(Value, self.entries.items.len);
        @memcpy(entries, self.entries.items);
        const m = try allocator.create(PersistentArrayMap);
        m.* = .{ .entries = entries };
        return m;
    }
};

/// Transient hash set — mutable builder for PersistentHashSet.
pub const TransientHashSet = struct {
    items: std.ArrayList(Value) = .empty,
    consumed: bool = false,
    comparator: ?Value = null,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentHashSet) !*TransientHashSet {
        const ts = try allocator.create(TransientHashSet);
        ts.* = .{ .comparator = source.comparator };
        try ts.items.appendSlice(allocator, source.items);
        return ts;
    }

    pub fn ensureEditable(self: *TransientHashSet) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientHashSet) usize {
        return self.items.items.len;
    }

    pub fn conj(self: *TransientHashSet, allocator: std.mem.Allocator, val: Value) !*TransientHashSet {
        try self.ensureEditable();
        // Check for duplicate
        for (self.items.items) |item| {
            if (item.eql(val)) return self; // already present
        }
        try self.items.append(allocator, val);
        return self;
    }

    pub fn disj(self: *TransientHashSet, val: Value) !*TransientHashSet {
        try self.ensureEditable();
        for (self.items.items, 0..) |item, i| {
            if (item.eql(val)) {
                _ = self.items.swapRemove(i);
                return self;
            }
        }
        return self; // not found — no-op
    }

    pub fn persistent(self: *TransientHashSet, allocator: std.mem.Allocator) !*const PersistentHashSet {
        try self.ensureEditable();
        self.consumed = true;
        const items = try allocator.alloc(Value, self.items.items.len);
        @memcpy(items, self.items.items);
        const s = try allocator.create(PersistentHashSet);
        s.* = .{ .items = items, .comparator = self.comparator };
        return s;
    }
};

/// ArrayChunk — immutable slice view over a Value array.
/// Supports offset for efficient dropFirst without copying.
pub const ArrayChunk = struct {
    array: []const Value,
    off: usize = 0,
    end: usize,

    pub fn initFull(array: []const Value) ArrayChunk {
        return .{ .array = array, .off = 0, .end = array.len };
    }

    pub fn count(self: ArrayChunk) usize {
        return self.end - self.off;
    }

    pub fn nth(self: ArrayChunk, i: usize) ?Value {
        if (i >= self.count()) return null;
        return self.array[self.off + i];
    }

    pub fn dropFirst(self: ArrayChunk) ?ArrayChunk {
        if (self.off >= self.end) return null;
        return .{ .array = self.array, .off = self.off + 1, .end = self.end };
    }
};

/// ChunkBuffer — mutable builder for ArrayChunk.
/// Created via (chunk-buffer n), elements added via (chunk-append b x),
/// finalized via (chunk b) -> ArrayChunk.
pub const ChunkBuffer = struct {
    items: std.ArrayList(Value) = .empty,
    consumed: bool = false,

    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !*ChunkBuffer {
        const cb = try allocator.create(ChunkBuffer);
        cb.* = .{};
        try cb.items.ensureTotalCapacity(allocator, capacity);
        return cb;
    }

    pub fn add(self: *ChunkBuffer, allocator: std.mem.Allocator, val: Value) !void {
        if (self.consumed) return error.ChunkBufferConsumed;
        try self.items.append(allocator, val);
    }

    pub fn toChunk(self: *ChunkBuffer, allocator: std.mem.Allocator) !*const ArrayChunk {
        if (self.consumed) return error.ChunkBufferConsumed;
        self.consumed = true;
        const items = try allocator.alloc(Value, self.items.items.len);
        @memcpy(items, self.items.items);
        const chunk = try allocator.create(ArrayChunk);
        chunk.* = ArrayChunk.initFull(items);
        return chunk;
    }

    pub fn count(self: ChunkBuffer) usize {
        return self.items.items.len;
    }
};

/// ChunkedCons — a chunked sequence: first chunk + rest seq.
/// first() returns chunk.nth(0), next() either drops within chunk
/// or advances to rest seq.
pub const ChunkedCons = struct {
    chunk: *const ArrayChunk,
    more: Value, // rest sequence (lazy-seq, list, nil, etc.)

    pub fn first(self: ChunkedCons) Value {
        return self.chunk.nth(0) orelse Value.nil_val;
    }

    pub fn next(self: *const ChunkedCons, allocator: std.mem.Allocator) !Value {
        if (self.chunk.count() > 1) {
            const new_chunk = try allocator.create(ArrayChunk);
            new_chunk.* = self.chunk.dropFirst() orelse return self.more;
            const new_cc = try allocator.create(ChunkedCons);
            new_cc.* = .{ .chunk = new_chunk, .more = self.more };
            return Value.initChunkedCons(new_cc);
        }
        // Advance to rest
        return switch (self.more.tag()) {
            .nil => Value.nil_val,
            else => self.more,
        };
    }
};

// ============================================================
// PersistentHashMap — Hash Array Mapped Trie (HAMT)
// ============================================================
//
// Maps with <= 8 entries use PersistentArrayMap (flat key-value array, O(n)
// linear scan). Above this threshold, maps auto-promote to PersistentHashMap
// backed by a HAMT — a 32-way branching trie indexed by hash bits.
//
// HAMT properties:
//   - O(log32 n) get/assoc/dissoc (effectively O(1) for practical sizes)
//   - Structural sharing: assoc only copies the path from root to modified
//     leaf; siblings are shared. This makes persistent updates efficient.
//   - Two bitmaps per node: data_map (inline KVs) and node_map (child nodes).
//     @popCount gives the array index from a bitmap position.
//
// Impact: map_ops 26ms -> 14ms (1.9x), keyword_lookup 24ms -> 20ms (1.2x).

/// Threshold: ArrayMap promotes to HashMap above this entry count.
pub const HASH_MAP_THRESHOLD = 8;

/// Compute a 32-bit hash for HAMT dispatch.
/// Uses Murmur3 finalizer mix on the raw hash to improve bit distribution,
/// ensuring keys spread evenly across the 32-way branches.
fn hashValue(v: Value) u32 {
    const h = @import("../lang/builtins/predicates.zig").computeHash(v);
    // Murmur3 finalizer mix
    var x: u32 = @truncate(@as(u64, @bitCast(h)));
    x ^= x >> 16;
    x *%= 0x85ebca6b;
    x ^= x >> 13;
    x *%= 0xc2b2ae35;
    x ^= x >> 16;
    return x;
}

/// HAMT node — sparse 32-way branching with bitmap indexing.
///
/// Each node has two bitmaps and two arrays:
///   data_map: bit i set = position i has an inline KV pair in kvs[]
///   node_map: bit i set = position i has a child node in nodes[]
///
/// To find the array index for position i: @popCount(bitmap & (bit(i) - 1)).
/// This gives O(1) index computation from the bitmap, avoiding a 32-slot array.
///
/// On hash collision at a given level, the two KVs are pushed into a child
/// node at the next 5-bit level (up to 7 levels for 32-bit hashes).
pub const HAMTNode = struct {
    data_map: u32 = 0,
    node_map: u32 = 0,
    kvs: []const KV = &.{},
    nodes: []const *const HAMTNode = &.{},

    pub const KV = struct {
        key: Value,
        val: Value,
    };

    const EMPTY: HAMTNode = .{};

    /// Get value for key, or null if not found.
    pub fn get(self: *const HAMTNode, hash: u32, shift: u5, key: Value) ?Value {
        const bit = bitpos(hash, shift);
        if (self.data_map & bit != 0) {
            const idx = bitmapIndex(self.data_map, bit);
            if (self.kvs[idx].key.eql(key)) return self.kvs[idx].val;
            return null;
        }
        if (self.node_map & bit != 0) {
            const idx = bitmapIndex(self.node_map, bit);
            return self.nodes[idx].get(hash, nextShift(shift), key);
        }
        return null;
    }

    /// Return a new node with the key-value pair added/replaced.
    pub fn assoc(self: *const HAMTNode, allocator: std.mem.Allocator, hash: u32, shift: u5, key: Value, val: Value) !*const HAMTNode {
        const bit = bitpos(hash, shift);

        if (self.data_map & bit != 0) {
            // Slot occupied by inline KV
            const idx = bitmapIndex(self.data_map, bit);
            const existing_key = self.kvs[idx].key;
            if (existing_key.eql(key)) {
                // Key match — replace value
                if (self.kvs[idx].val.eql(val)) return self; // no change
                const new_kvs = try allocator.alloc(KV, self.kvs.len);
                @memcpy(new_kvs, self.kvs);
                new_kvs[idx] = .{ .key = key, .val = val };
                const new_node = try allocator.create(HAMTNode);
                new_node.* = .{
                    .data_map = self.data_map,
                    .node_map = self.node_map,
                    .kvs = new_kvs,
                    .nodes = self.nodes,
                };
                return new_node;
            }
            // Hash collision at this level — push down
            const existing_hash = hashValue(existing_key);
            const sub_node = try createTwoNode(allocator, existing_hash, existing_key, self.kvs[idx].val, hash, key, val, nextShift(shift));
            // Remove KV, add sub-node
            const new_kvs = try allocator.alloc(KV, self.kvs.len - 1);
            copyExcept(KV, new_kvs, self.kvs, idx);
            const node_idx = bitmapIndex(self.node_map, bit);
            const new_nodes = try allocator.alloc(*const HAMTNode, self.nodes.len + 1);
            copyInsert(*const HAMTNode, new_nodes, self.nodes, node_idx, sub_node);
            const new_node = try allocator.create(HAMTNode);
            new_node.* = .{
                .data_map = self.data_map ^ bit,
                .node_map = self.node_map | bit,
                .kvs = new_kvs,
                .nodes = new_nodes,
            };
            return new_node;
        }

        if (self.node_map & bit != 0) {
            // Slot occupied by sub-node — recurse
            const idx = bitmapIndex(self.node_map, bit);
            const child = self.nodes[idx];
            const new_child = try child.assoc(allocator, hash, nextShift(shift), key, val);
            if (new_child == child) return self; // no change
            const new_nodes = try allocator.alloc(*const HAMTNode, self.nodes.len);
            @memcpy(new_nodes, self.nodes);
            new_nodes[idx] = new_child;
            const new_node = try allocator.create(HAMTNode);
            new_node.* = .{
                .data_map = self.data_map,
                .node_map = self.node_map,
                .kvs = self.kvs,
                .nodes = new_nodes,
            };
            return new_node;
        }

        // Empty slot — insert inline KV
        const idx = bitmapIndex(self.data_map, bit);
        const new_kvs = try allocator.alloc(KV, self.kvs.len + 1);
        copyInsert(KV, new_kvs, self.kvs, idx, .{ .key = key, .val = val });
        const new_node = try allocator.create(HAMTNode);
        new_node.* = .{
            .data_map = self.data_map | bit,
            .node_map = self.node_map,
            .kvs = new_kvs,
            .nodes = self.nodes,
        };
        return new_node;
    }

    /// Return a new node without the given key, or null if node becomes empty.
    pub fn dissoc(self: *const HAMTNode, allocator: std.mem.Allocator, hash: u32, shift: u5, key: Value) !?*const HAMTNode {
        const bit = bitpos(hash, shift);

        if (self.data_map & bit != 0) {
            const idx = bitmapIndex(self.data_map, bit);
            if (!self.kvs[idx].key.eql(key)) return self; // not found
            // Remove this KV
            if (self.kvs.len == 1 and self.nodes.len == 0) return null; // node empty
            const new_kvs = try allocator.alloc(KV, self.kvs.len - 1);
            copyExcept(KV, new_kvs, self.kvs, idx);
            const new_node = try allocator.create(HAMTNode);
            new_node.* = .{
                .data_map = self.data_map ^ bit,
                .node_map = self.node_map,
                .kvs = new_kvs,
                .nodes = self.nodes,
            };
            return new_node;
        }

        if (self.node_map & bit != 0) {
            const idx = bitmapIndex(self.node_map, bit);
            const child = self.nodes[idx];
            const new_child = try child.dissoc(allocator, hash, nextShift(shift), key);
            if (new_child) |nc| {
                if (nc == child) return self; // no change
                // Inline single-entry sub-nodes back into parent
                if (nc.kvs.len == 1 and nc.nodes.len == 0) {
                    // Pull the single KV up
                    const kv = nc.kvs[0];
                    const new_kvs = try allocator.alloc(KV, self.kvs.len + 1);
                    const kv_idx = bitmapIndex(self.data_map, bit);
                    copyInsert(KV, new_kvs, self.kvs, kv_idx, kv);
                    const new_nodes = try allocator.alloc(*const HAMTNode, self.nodes.len - 1);
                    copyExcept(*const HAMTNode, new_nodes, self.nodes, idx);
                    const new_node = try allocator.create(HAMTNode);
                    new_node.* = .{
                        .data_map = self.data_map | bit,
                        .node_map = self.node_map ^ bit,
                        .kvs = new_kvs,
                        .nodes = new_nodes,
                    };
                    return new_node;
                }
                const new_nodes = try allocator.alloc(*const HAMTNode, self.nodes.len);
                @memcpy(new_nodes, self.nodes);
                new_nodes[idx] = nc;
                const new_node = try allocator.create(HAMTNode);
                new_node.* = .{
                    .data_map = self.data_map,
                    .node_map = self.node_map,
                    .kvs = self.kvs,
                    .nodes = new_nodes,
                };
                return new_node;
            } else {
                // Child became empty — remove sub-node
                if (self.kvs.len == 0 and self.nodes.len == 1) return null;
                const new_nodes = try allocator.alloc(*const HAMTNode, self.nodes.len - 1);
                copyExcept(*const HAMTNode, new_nodes, self.nodes, idx);
                const new_node = try allocator.create(HAMTNode);
                new_node.* = .{
                    .data_map = self.data_map,
                    .node_map = self.node_map ^ bit,
                    .kvs = self.kvs,
                    .nodes = new_nodes,
                };
                return new_node;
            }
        }

        return self; // key not in this node
    }

    /// Count all key-value pairs in this subtree.
    pub fn countEntries(self: *const HAMTNode) usize {
        var n: usize = self.kvs.len;
        for (self.nodes) |child| {
            n += child.countEntries();
        }
        return n;
    }

    /// Collect all entries as flat [k1, v1, k2, v2, ...] for seq/iteration.
    pub fn collectEntries(self: *const HAMTNode, allocator: std.mem.Allocator, out: *std.ArrayList(Value)) !void {
        for (self.kvs) |kv| {
            try out.append(allocator, kv.key);
            try out.append(allocator, kv.val);
        }
        for (self.nodes) |child| {
            try child.collectEntries(allocator, out);
        }
    }
};

/// Create a node with exactly two key-value pairs.
fn createTwoNode(allocator: std.mem.Allocator, hash1: u32, key1: Value, val1: Value, hash2: u32, key2: Value, val2: Value, shift: u5) !*const HAMTNode {
    const bit1 = bitpos(hash1, shift);
    const bit2 = bitpos(hash2, shift);

    if (bit1 != bit2) {
        // Different positions — put both inline
        const node = try allocator.create(HAMTNode);
        const kvs = try allocator.alloc(HAMTNode.KV, 2);
        if (bitmapIndex(bit1 | bit2, bit1) == 0) {
            kvs[0] = .{ .key = key1, .val = val1 };
            kvs[1] = .{ .key = key2, .val = val2 };
        } else {
            kvs[0] = .{ .key = key2, .val = val2 };
            kvs[1] = .{ .key = key1, .val = val1 };
        }
        node.* = .{
            .data_map = bit1 | bit2,
            .kvs = kvs,
        };
        return node;
    }

    // Same position — need to go deeper
    const child = try createTwoNode(allocator, hash1, key1, val1, hash2, key2, val2, nextShift(shift));
    const node = try allocator.create(HAMTNode);
    const nodes = try allocator.alloc(*const HAMTNode, 1);
    nodes[0] = child;
    node.* = .{
        .node_map = bit1,
        .nodes = nodes,
    };
    return node;
}

/// Extract 5-bit index from hash at given shift level.
fn mask(hash: u32, shift: u5) u5 {
    return @truncate(hash >> shift);
}

/// Bit position for the 5-bit index.
fn bitpos(hash: u32, shift: u5) u32 {
    return @as(u32, 1) << mask(hash, shift);
}

/// Count set bits below the given bit to find array index.
fn bitmapIndex(bitmap: u32, bit: u32) usize {
    return @popCount(bitmap & (bit -% 1));
}

/// Advance shift by 5 bits, wrapping at 30 (max 7 levels for 32-bit hash).
fn nextShift(shift: u5) u5 {
    return if (shift >= 25) 0 else shift + 5;
}

/// Copy src to dst, inserting elem at idx.
fn copyInsert(comptime T: type, dst: []T, src: []const T, idx: usize, elem: T) void {
    @memcpy(dst[0..idx], src[0..idx]);
    dst[idx] = elem;
    if (idx < src.len) @memcpy(dst[idx + 1 ..], src[idx..]);
}

/// Copy src to dst, skipping element at idx.
fn copyExcept(comptime T: type, dst: []T, src: []const T, idx: usize) void {
    @memcpy(dst[0..idx], src[0..idx]);
    if (idx + 1 < src.len) @memcpy(dst[idx..], src[idx + 1 ..]);
}

/// Persistent hash map — HAMT-based, replaces ArrayMap for large maps.
pub const PersistentHashMap = struct {
    count: usize = 0,
    root: ?*const HAMTNode = null,
    has_null: bool = false,
    null_val: Value = Value.nil_val,
    meta: ?*const Value = null,

    pub const EMPTY: PersistentHashMap = .{};

    pub fn getCount(self: *const PersistentHashMap) usize {
        return self.count;
    }

    pub fn get(self: *const PersistentHashMap, key: Value) ?Value {
        if (key == Value.nil_val) {
            return if (self.has_null) self.null_val else null;
        }
        const root = self.root orelse return null;
        return root.get(hashValue(key), 0, key);
    }

    pub fn containsKey(self: *const PersistentHashMap, key: Value) bool {
        return self.get(key) != null;
    }

    pub fn assoc(self: *const PersistentHashMap, allocator: std.mem.Allocator, key: Value, val: Value) !*const PersistentHashMap {
        if (key == Value.nil_val) {
            if (self.has_null and self.null_val.eql(val)) return self;
            const new_map = try allocator.create(PersistentHashMap);
            new_map.* = .{
                .count = self.count + @as(usize, if (self.has_null) 0 else 1),
                .root = self.root,
                .has_null = true,
                .null_val = val,
                .meta = self.meta,
            };
            return new_map;
        }
        const hash = hashValue(key);
        const empty_root = &HAMTNode.EMPTY;
        const old_root = self.root orelse empty_root;
        const new_root = try old_root.assoc(allocator, hash, 0, key, val);
        if (new_root == old_root) return self; // no change
        // Count: if old root didn't have this key, increment
        const added: usize = if (old_root.get(hash, 0, key) == null) 1 else 0;
        const new_map = try allocator.create(PersistentHashMap);
        new_map.* = .{
            .count = self.count + added,
            .root = new_root,
            .has_null = self.has_null,
            .null_val = self.null_val,
            .meta = self.meta,
        };
        return new_map;
    }

    pub fn dissoc(self: *const PersistentHashMap, allocator: std.mem.Allocator, key: Value) !*const PersistentHashMap {
        if (key == Value.nil_val) {
            if (!self.has_null) return self;
            const new_map = try allocator.create(PersistentHashMap);
            new_map.* = .{
                .count = self.count - 1,
                .root = self.root,
                .has_null = false,
                .null_val = Value.nil_val,
                .meta = self.meta,
            };
            return new_map;
        }
        const root = self.root orelse return self;
        const hash = hashValue(key);
        const new_root = try root.dissoc(allocator, hash, 0, key);
        if (new_root) |nr| {
            if (nr == root) return self; // key not found
        }
        const new_map = try allocator.create(PersistentHashMap);
        new_map.* = .{
            .count = self.count - 1,
            .root = new_root,
            .has_null = self.has_null,
            .null_val = self.null_val,
            .meta = self.meta,
        };
        return new_map;
    }

    /// Collect all entries as flat [k1, v1, k2, v2, ...] for seq/iteration.
    pub fn toEntries(self: *const PersistentHashMap, allocator: std.mem.Allocator) ![]const Value {
        var out = std.ArrayList(Value).empty;
        if (self.has_null) {
            try out.append(allocator, Value.nil_val);
            try out.append(allocator, self.null_val);
        }
        if (self.root) |root| {
            try root.collectEntries(allocator, &out);
        }
        return out.items;
    }

    /// Create a PersistentHashMap from a flat [k1, v1, k2, v2, ...] array.
    pub fn fromEntries(allocator: std.mem.Allocator, entries: []const Value) !*const PersistentHashMap {
        const empty = &PersistentHashMap.EMPTY;
        var m: *const PersistentHashMap = empty;
        var i: usize = 0;
        while (i < entries.len) : (i += 2) {
            m = try m.assoc(allocator, entries[i], entries[i + 1]);
        }
        return m;
    }
};

// === Tests ===

test "PersistentList - empty" {
    const list = PersistentList{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), list.count());
}

test "PersistentList - count/first/rest" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const list = PersistentList{ .items = &items };
    try testing.expectEqual(@as(usize, 3), list.count());
    try testing.expect(list.first().eql(Value.initInteger(1)));
    try testing.expectEqual(@as(usize, 2), list.rest().count());
}

test "PersistentList - first of empty is nil" {
    const list = PersistentList{ .items = &.{} };
    try testing.expect(list.first().isNil());
}

test "PersistentList - rest of empty is empty list" {
    const list = PersistentList{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), list.rest().count());
}

test "PersistentVector - empty" {
    const vec = PersistentVector{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), vec.count());
}

test "PersistentVector - count/nth" {
    const items = [_]Value{ Value.initInteger(10), Value.initInteger(20), Value.initInteger(30) };
    const vec = PersistentVector{ .items = &items };
    try testing.expectEqual(@as(usize, 3), vec.count());
    try testing.expect(vec.nth(0).?.eql(Value.initInteger(10)));
    try testing.expect(vec.nth(1).?.eql(Value.initInteger(20)));
    try testing.expect(vec.nth(2).?.eql(Value.initInteger(30)));
    try testing.expect(vec.nth(3) == null);
}

test "PersistentArrayMap - empty" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try testing.expectEqual(@as(usize, 0), m.count());
}

test "PersistentArrayMap - count/get" {
    // {k1 v1, k2 v2} stored as [k1, v1, k2, v2]
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try testing.expectEqual(@as(usize, 2), m.count());
    const v = m.get(Value.initKeyword(alloc, .{ .name = "a", .ns = null }));
    try testing.expect(v != null);
    try testing.expect(v.?.eql(Value.initInteger(1)));
}

test "PersistentArrayMap - get missing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try testing.expect(m.get(Value.initKeyword(alloc, .{ .name = "z", .ns = null })) == null);
}

test "PersistentHashSet - empty" {
    const s = PersistentHashSet{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "PersistentHashSet - contains" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const s = PersistentHashSet{ .items = &items };
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expect(s.contains(Value.initInteger(2)));
    try testing.expect(!s.contains(Value.initInteger(99)));
}

// --- PersistentHashMap (HAMT) Tests ---

test "PersistentHashMap - empty" {
    const m = PersistentHashMap.EMPTY;
    try testing.expectEqual(@as(usize, 0), m.getCount());
    try testing.expect(m.get(Value.initInteger(1)) == null);
}

test "PersistentHashMap - single assoc and get" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m0 = &PersistentHashMap.EMPTY;
    const m1 = try m0.assoc(alloc, Value.initInteger(42), Value.initInteger(100));
    try testing.expectEqual(@as(usize, 1), m1.getCount());
    const v = m1.get(Value.initInteger(42));
    try testing.expect(v != null);
    try testing.expect(v.?.eql(Value.initInteger(100)));
    // Original unchanged
    try testing.expectEqual(@as(usize, 0), m0.getCount());
}

test "PersistentHashMap - multiple assocs" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m: *const PersistentHashMap = &PersistentHashMap.EMPTY;
    // Insert 20 entries
    for (0..20) |i| {
        m = try m.assoc(alloc, Value.initInteger(@intCast(i)), Value.initInteger(@as(i64, @intCast(i)) * 10));
    }
    try testing.expectEqual(@as(usize, 20), m.getCount());
    // Verify all entries
    for (0..20) |i| {
        const v = m.get(Value.initInteger(@intCast(i)));
        try testing.expect(v != null);
        try testing.expect(v.?.eql(Value.initInteger(@as(i64, @intCast(i)) * 10)));
    }
    // Missing key
    try testing.expect(m.get(Value.initInteger(99)) == null);
}

test "PersistentHashMap - key replacement" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m0 = &PersistentHashMap.EMPTY;
    const m1 = try m0.assoc(alloc, Value.initInteger(1), Value.initInteger(10));
    const m2 = try m1.assoc(alloc, Value.initInteger(1), Value.initInteger(20));
    try testing.expectEqual(@as(usize, 1), m2.getCount());
    try testing.expect(m2.get(Value.initInteger(1)).?.eql(Value.initInteger(20)));
    // Old version preserved
    try testing.expect(m1.get(Value.initInteger(1)).?.eql(Value.initInteger(10)));
}

test "PersistentHashMap - nil key" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m0 = &PersistentHashMap.EMPTY;
    const m1 = try m0.assoc(alloc, Value.nil_val, Value.initInteger(42));
    try testing.expectEqual(@as(usize, 1), m1.getCount());
    try testing.expect(m1.get(Value.nil_val).?.eql(Value.initInteger(42)));
    // Dissoc nil key
    const m2 = try m1.dissoc(alloc, Value.nil_val);
    try testing.expectEqual(@as(usize, 0), m2.getCount());
    try testing.expect(m2.get(Value.nil_val) == null);
}

test "PersistentHashMap - dissoc" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m: *const PersistentHashMap = &PersistentHashMap.EMPTY;
    for (0..5) |i| {
        m = try m.assoc(alloc, Value.initInteger(@intCast(i)), Value.initInteger(@as(i64, @intCast(i)) * 10));
    }
    try testing.expectEqual(@as(usize, 5), m.getCount());

    const m2 = try m.dissoc(alloc, Value.initInteger(2));
    try testing.expectEqual(@as(usize, 4), m2.getCount());
    try testing.expect(m2.get(Value.initInteger(2)) == null);
    try testing.expect(m2.get(Value.initInteger(0)) != null);
    try testing.expect(m2.get(Value.initInteger(4)) != null);
    // Original unchanged
    try testing.expectEqual(@as(usize, 5), m.getCount());
}

test "PersistentHashMap - large map (100 entries)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m: *const PersistentHashMap = &PersistentHashMap.EMPTY;
    for (0..100) |i| {
        m = try m.assoc(alloc, Value.initInteger(@intCast(i)), Value.initInteger(@as(i64, @intCast(i)) + 1000));
    }
    try testing.expectEqual(@as(usize, 100), m.getCount());
    for (0..100) |i| {
        const v = m.get(Value.initInteger(@intCast(i)));
        try testing.expect(v != null);
        try testing.expect(v.?.eql(Value.initInteger(@as(i64, @intCast(i)) + 1000)));
    }
}

test "PersistentHashMap - toEntries" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m: *const PersistentHashMap = &PersistentHashMap.EMPTY;
    m = try m.assoc(alloc, Value.initInteger(1), Value.initInteger(10));
    m = try m.assoc(alloc, Value.initInteger(2), Value.initInteger(20));

    const entries = try m.toEntries(alloc);
    try testing.expectEqual(@as(usize, 4), entries.len); // 2 pairs = 4 values
}

test "PersistentHashMap - fromEntries" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(alloc, .{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    const m = try PersistentHashMap.fromEntries(alloc, &entries);
    try testing.expectEqual(@as(usize, 2), m.getCount());
    try testing.expect(m.get(Value.initKeyword(alloc, .{ .name = "a", .ns = null })).?.eql(Value.initInteger(1)));
    try testing.expect(m.get(Value.initKeyword(alloc, .{ .name = "b", .ns = null })).?.eql(Value.initInteger(2)));
}
