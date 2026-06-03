// SPDX-License-Identifier: EPL-2.0
//! NaN-boxed Value type for ClojureWasm runtime — module root.
//!
//! This file is the public face of the `runtime/value/` subdirectory.
//! It exports the `Value` enum + its `Tag` classifier + every helper
//! callers used to import from the old single-file `runtime/value.zig`.
//! Internal types (`HeapTag`, `HeapHeader`, NaN-box constants) are
//! re-exported here so existing call sites only need to add the `/value`
//! segment to their `@import` path.
//!
//! Phase 5 row 5.2 split lands this module decomposition per
//! `.dev/structure_plan.md` (F-004 + D-029 decree) + ADR-0027 §5.
//! The 32 → 64 HeapTag widening + `heapTagToTag` collapse +
//! `big_int` slot rotation + `tag_ops.zig` skeleton land in the
//! follow-up 5.2.b commit.

const std = @import("std");
const testing = std.testing;

const heap_tag_mod = @import("heap_tag.zig");
const heap_header_mod = @import("heap_header.zig");
const nb = @import("nan_box.zig");

// Re-exports — callers used to reach these through `runtime/value.zig`.
pub const HeapTag = heap_tag_mod.HeapTag;
pub const HeapHeader = heap_header_mod.HeapHeader;

/// NaN-boxed runtime value. Every Clojure value fits in 8 bytes.
///
/// Use `tag()` to classify, constructors (`initInteger`, `initFloat`, …)
/// to build, and accessors (`asInteger`, `asFloat`, …) to extract.
pub const Value = enum(u64) {
    nil_val = nb.NB_CONST_TAG | 0,
    true_val = nb.NB_CONST_TAG | 1,
    false_val = nb.NB_CONST_TAG | 2,
    _,

    /// High-level type tag returned by `tag()`. Heap entries (0..63) match
    /// `HeapTag` 1:1 by integer position per ADR-0027 §2; immediates (64..69)
    /// sit after. This ordering lets `heapTagToTag` collapse to
    /// `@enumFromInt(@intFromEnum(.))` per simplify finding #8 + ROADMAP
    /// §9.7 row 5.2 text.
    pub const Tag = enum(u8) {
        // Group A (slots 0..15)
        string = 0,
        symbol = 1,
        keyword = 2,
        list = 3,
        vector = 4,
        array_map = 5,
        hash_map = 6,
        hash_set = 7,
        lazy_seq = 8,
        cons = 9,
        chunked_cons = 10,
        chunk_buffer = 11,
        range = 12,
        string_seq = 13,
        array_seq = 14,
        map_entry = 15,
        // Group B (slots 16..31)
        fn_val = 16,
        multi_fn = 17,
        protocol = 18,
        protocol_fn = 19,
        var_ref = 20,
        ns = 21,
        delay = 22,
        regex = 23,
        tagged_literal = 24,
        reader_conditional = 25,
        class = 26,
        reified_instance = 27,
        type_descriptor = 28,
        host_instance = 29,
        typed_instance = 30,
        uuid = 31,
        // Group C (slots 32..47)
        atom = 32,
        agent = 33,
        ref = 34,
        @"volatile" = 35,
        future = 36,
        promise = 37,
        reduced = 38,
        ex_info = 39,
        transient_vector = 40,
        transient_map = 41,
        transient_set = 42,
        rb_node = 43, // persistent LLRB red-black tree node (ADR-0057)
        array_chunk = 44,
        persistent_queue = 45,
        sorted_map = 46,
        sorted_set = 47,
        // Group D (slots 48..63)
        big_int = 48,
        ratio = 49,
        big_decimal = 50,
        array = 51,
        wasm_module = 52,
        wasm_fn = 53,
        wasm_funcref = 54,
        wasm_externref = 55,
        matcher = 56,
        tuple = 57,
        box = 58,
        hamt_node = 59, // D11 — PersistentVector interior/leaf node (5.4.a)
        tail_node = 60, // D12 — PersistentVector 32-element tail array (5.4.a)
        hamt_map_node = 61, // D13 — PersistentHashMap CHAMP-style HAMT node (5.5.a)
        hash_collision_map_node = 62, // D14 — PersistentHashMap collision bucket (5.5.c)
        tval = 63, // D15 — STM Ref TVal (ADR-0010 amendment 4; HeapTag-only — TVal is not NaN-boxed as a Value)
        // Immediates (not in heap slot space; classified by top16 band,
        // not by integer-indexed lookup against HeapTag)
        nil = 64,
        boolean = 65,
        integer = 66,
        float = 67,
        char = 68,
        builtin_fn = 69,
    };

    /// Pack a heap pointer + HeapTag into a Value. The pointer must be
    /// 8-byte aligned so the low 3 bits are zero.
    pub fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value {
        const addr: u64 = @intFromPtr(ptr);
        std.debug.assert(addr & nb.NB_ADDR_ALIGN_MASK == 0);
        const shifted = addr >> nb.NB_ADDR_ALIGN_SHIFT;
        std.debug.assert(shifted <= nb.NB_ADDR_SHIFTED_MASK);
        const type_val = @intFromEnum(ht);
        const group = type_val / nb.NB_HEAP_GROUP_SIZE;
        const tag_base: u64 = switch (group) {
            0 => nb.NB_HEAP_TAG_A,
            1 => nb.NB_HEAP_TAG_B,
            2 => nb.NB_HEAP_TAG_C,
            3 => nb.NB_HEAP_TAG_D,
            // @panic: cw runtime invariant — HeapTag is bounded to
            // 4 × NB_HEAP_GROUP_SIZE entries (g1 = 32; g2 = 64 per
            // F-004 NaN-box second generation layout, row 5.2.b).
            // Adding entries past that bound would require a layout
            // extension ADR; this arm guards against silent drift.
            else => unreachable,
        };
        const sub_type: u64 = type_val % nb.NB_HEAP_GROUP_SIZE;
        return @enumFromInt(tag_base | (sub_type << nb.NB_HEAP_SUBTYPE_SHIFT) | shifted);
    }

    /// Extract the heap pointer from a heap-tagged Value.
    pub fn decodePtr(self: Value, comptime T: type) T {
        const shifted = @intFromEnum(self) & nb.NB_ADDR_SHIFTED_MASK;
        return @ptrFromInt(@as(usize, shifted) << nb.NB_ADDR_ALIGN_SHIFT);
    }

    /// Map a HeapTag integer to its parallel Tag entry. Per ADR-0027 §2 +
    /// simplify finding #8: Tag heap entries (0..63) are integer-aligned
    /// with HeapTag (0..63), so the mapping is a single `@enumFromInt`.
    fn heapTagToTag(ht_raw: u8) Tag {
        return @enumFromInt(ht_raw);
    }

    /// Classify this Value into a Tag by inspecting the upper 16 bits.
    pub fn tag(self: Value) Tag {
        const bits = @intFromEnum(self);
        const top16: u16 = @truncate(bits >> nb.NB_TAG_SHIFT);
        if (top16 < nb.NB_FLOAT_TAG_BOUNDARY) return .float;
        const sub: u8 = @truncate((bits >> nb.NB_HEAP_SUBTYPE_SHIFT) & nb.NB_HEAP_SUBTYPE_MASK);
        return switch (top16) {
            nb.NB_TAG_A => heapTagToTag(sub),
            nb.NB_TAG_B => heapTagToTag(sub + nb.NB_HEAP_GROUP_SIZE),
            nb.NB_TAG_C => heapTagToTag(sub + nb.NB_HEAP_GROUP_SIZE * 2),
            nb.NB_TAG_D => heapTagToTag(sub + nb.NB_HEAP_GROUP_SIZE * 3),
            nb.NB_TAG_INT => .integer,
            nb.NB_TAG_CONST => switch (bits & nb.NB_PAYLOAD_MASK) {
                0 => .nil,
                1, 2 => .boolean,
                // @panic: cw runtime invariant — NB_TAG_CONST payload
                // is constructed only as nil_val (0) / true_val (1) /
                // false_val (2). A NB_TAG_CONST Value with any other
                // payload is a corrupt bit pattern.
                else => unreachable,
            },
            nb.NB_TAG_CHAR => .char,
            nb.NB_TAG_BUILTIN => .builtin_fn,
            // @panic: cw runtime invariant — top16 is constructed only
            // as NB_TAG_INT / _A / _B / _C / _D / _CONST / _CHAR /
            // _BUILTIN, or covered by the `< NB_FLOAT_TAG_BOUNDARY`
            // early-return above. Any other top16 is a corrupt bit
            // pattern.
            else => unreachable,
        };
    }

    pub fn initBoolean(b: bool) Value {
        return if (b) Value.true_val else Value.false_val;
    }

    /// Encode an integer. Values outside i48 range are promoted to float
    /// (Clojure-compatible auto-promotion within the i48 window).
    pub fn initInteger(i: i64) Value {
        if (i < nb.NB_I48_MIN or i > nb.NB_I48_MAX) {
            return initFloat(@floatFromInt(i));
        }
        const raw: u48 = @truncate(@as(u64, @bitCast(i)));
        return @enumFromInt(nb.NB_INT_TAG | @as(u64, raw));
    }

    /// Encode a float. NaN bit patterns whose top16 ≥ 0xFFF8 collide
    /// with tagged values; collapse them to canonical positive quiet NaN.
    pub fn initFloat(f: f64) Value {
        const bits: u64 = @bitCast(f);
        if ((bits >> nb.NB_TAG_SHIFT) >= nb.NB_FLOAT_TAG_BOUNDARY) {
            return @enumFromInt(nb.NB_CANONICAL_NAN);
        }
        return @enumFromInt(bits);
    }

    pub fn initChar(c: u21) Value {
        return @enumFromInt(nb.NB_CHAR_TAG | @as(u64, c));
    }

    /// Pack a 48-bit function pointer into a NaN-boxed Value.
    pub fn initBuiltinFn(fn_ptr: anytype) Value {
        const addr: u64 = @intFromPtr(fn_ptr);
        std.debug.assert(addr <= nb.NB_PAYLOAD_MASK);
        return @enumFromInt(nb.NB_BUILTIN_FN_TAG | addr);
    }

    /// Extract the function pointer from a builtin_fn Value. Caller
    /// supplies the concrete pointer type via `FnPtr`.
    pub fn asBuiltinFn(self: Value, comptime FnPtr: type) FnPtr {
        const raw = @intFromEnum(self) & nb.NB_PAYLOAD_MASK;
        return @ptrFromInt(raw);
    }

    pub fn isNil(self: Value) bool {
        return self == Value.nil_val;
    }

    /// Clojure truthiness: everything except `nil` and `false`.
    pub fn isTruthy(self: Value) bool {
        return self != Value.nil_val and self != Value.false_val;
    }

    pub fn asBoolean(self: Value) bool {
        return self == Value.true_val;
    }

    pub fn asInteger(self: Value) i48 {
        const raw: u48 = @truncate(@intFromEnum(self));
        return @bitCast(raw);
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(@intFromEnum(self));
    }

    pub fn asChar(self: Value) u21 {
        return @truncate(@intFromEnum(self));
    }

    pub fn isInt(self: Value) bool {
        return self.tag() == .integer;
    }

    pub fn isFloat(self: Value) bool {
        return self.tag() == .float;
    }

    pub fn isNumber(self: Value) bool {
        const t = self.tag();
        return t == .integer or t == .float;
    }

    pub fn isString(self: Value) bool {
        return self.tag() == .string;
    }

    pub fn isSymbol(self: Value) bool {
        return self.tag() == .symbol;
    }

    pub fn isKeyword(self: Value) bool {
        return self.tag() == .keyword;
    }

    /// Decode this Value to its underlying heap `*HeapHeader`, or
    /// `null` if it is an immediate (nil / boolean / integer / float
    /// / char / builtin_fn — `NB_CONST_TAG` / `NB_INT_TAG` /
    /// `NB_CHAR_TAG` / `NB_BUILTIN_FN_TAG` band + raw float).
    /// Heap-tagged Values per ADR-0027 §1 carry a 44-bit shifted
    /// pointer in bits 43..0; the helper reuses `decodePtr` to
    /// reconstruct the byte address.
    ///
    /// Per ADR-0028 §5: every root walker calls `heapHeader()` to
    /// punch the membrane between a runtime-data-structure stored
    /// Value and the GC's mark queue. Immediates yield `null` so
    /// the queue stays leaf-clean.
    pub fn heapHeader(self: Value) ?*HeapHeader {
        const bits = @intFromEnum(self);
        const top16: u16 = @truncate(bits >> nb.NB_TAG_SHIFT);
        if (top16 < nb.NB_FLOAT_TAG_BOUNDARY) return null;        // raw f64
        if (top16 >= nb.NB_TAG_INT) return null;                  // immediate band
        // `.var_ref` (20) and `.ns` (21) are heap-TAGGED but their payload is an
        // Env-lifetime `*Var` / `*Namespace` with NO `HeapHeader` at offset 0 —
        // decoding one as a header and handing it to `mark()` would corrupt the
        // Env struct (root_set.zig: "namespace-owned pointers, not GC edges").
        // They are never GcHeap-allocated, so the membrane skips them.
        switch (self.tag()) {
            .var_ref, .ns => return null,
            else => {},
        }
        return self.decodePtr(*HeapHeader);
    }
};

// --- tests ---

test "nil, true, false constants" {
    const nil: Value = .nil_val;
    const t: Value = .true_val;
    const f: Value = .false_val;

    try testing.expect(nil.tag() == .nil);
    try testing.expect(t.tag() == .boolean);
    try testing.expect(f.tag() == .boolean);

    try testing.expect(nil.isNil());
    try testing.expect(!t.isNil());
    try testing.expect(!f.isNil());

    try testing.expect(!nil.isTruthy());
    try testing.expect(t.isTruthy());
    try testing.expect(!f.isTruthy());

    try testing.expect(t.asBoolean());
    try testing.expect(!f.asBoolean());
}

test "integer encoding round-trip" {
    const zero = Value.initInteger(0);
    try testing.expect(zero.tag() == .integer);
    try testing.expectEqual(@as(i48, 0), zero.asInteger());

    const pos = Value.initInteger(42);
    try testing.expect(pos.tag() == .integer);
    try testing.expectEqual(@as(i48, 42), pos.asInteger());

    const neg = Value.initInteger(-1);
    try testing.expectEqual(@as(i48, -1), neg.asInteger());

    // i48 max/min
    const max_i48 = Value.initInteger((1 << 47) - 1);
    try testing.expect(max_i48.tag() == .integer);
    try testing.expectEqual(@as(i48, (1 << 47) - 1), max_i48.asInteger());

    const min_i48 = Value.initInteger(-(1 << 47));
    try testing.expect(min_i48.tag() == .integer);
    try testing.expectEqual(@as(i48, -(1 << 47)), min_i48.asInteger());

    // Out-of-range → float promotion
    const overflow = Value.initInteger((1 << 47));
    try testing.expect(overflow.tag() == .float);
    const underflow = Value.initInteger(-(1 << 47) - 1);
    try testing.expect(underflow.tag() == .float);
}

test "float encoding round-trip" {
    const pi = Value.initFloat(3.14159);
    try testing.expect(pi.tag() == .float);
    try testing.expectApproxEqRel(@as(f64, 3.14159), pi.asFloat(), 1e-10);

    const zero = Value.initFloat(0.0);
    try testing.expect(zero.tag() == .float);
    try testing.expectEqual(@as(f64, 0.0), zero.asFloat());

    const neg = Value.initFloat(-1.5);
    try testing.expectEqual(@as(f64, -1.5), neg.asFloat());

    const inf = Value.initFloat(std.math.inf(f64));
    try testing.expect(std.math.isPositiveInf(inf.asFloat()));

    const neg_inf = Value.initFloat(-std.math.inf(f64));
    try testing.expect(std.math.isNegativeInf(neg_inf.asFloat()));

    const nan = Value.initFloat(std.math.nan(f64));
    try testing.expect(nan.tag() == .float);
    try testing.expect(std.math.isNan(nan.asFloat()));
}

test "NaN canonicalization" {
    // A negative-sign NaN bit pattern (top16 >= 0xFFF8) would collide
    // with tagged Values; initFloat must canonicalise it.
    const canonical: u64 = 0x7FF8_0000_0000_0000;
    const neg_nan: f64 = @bitCast(@as(u64, 0xFFF8_0000_0000_0001));
    const result = Value.initFloat(neg_nan);
    try testing.expect(result.tag() == .float);
    try testing.expectEqual(canonical, @intFromEnum(result));
}

test "char encoding round-trip" {
    const a = Value.initChar('a');
    try testing.expect(a.tag() == .char);
    try testing.expectEqual(@as(u21, 'a'), a.asChar());

    const emoji = Value.initChar(0x1F600);
    try testing.expect(emoji.tag() == .char);
    try testing.expectEqual(@as(u21, 0x1F600), emoji.asChar());
}

test "type predicates" {
    const nil: Value = .nil_val;
    const int = Value.initInteger(42);
    const float = Value.initFloat(3.14);

    try testing.expect(int.isInt());
    try testing.expect(!float.isInt());
    try testing.expect(float.isFloat());
    try testing.expect(int.isNumber() and float.isNumber());
    try testing.expect(!nil.isNumber());
}

test "encodeHeapPtr round-trip (string)" {
    var data: u64 align(8) = 0xDEAD_BEEF;
    const encoded = Value.encodeHeapPtr(.string, &data);
    try testing.expect(encoded.tag() == .string);
    const decoded = encoded.decodePtr(*u64);
    try testing.expectEqual(&data, decoded);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), decoded.*);
}

test "encodeHeapPtr covers all four heap groups" {
    var obj_a: u64 align(8) = 0;
    var obj_b: u64 align(8) = 0;
    var obj_c: u64 align(8) = 0;
    var obj_d: u64 align(8) = 0;

    const a = Value.encodeHeapPtr(.keyword, &obj_a);
    const b = Value.encodeHeapPtr(.fn_val, &obj_b);
    const c = Value.encodeHeapPtr(.cons, &obj_c);
    const d = Value.encodeHeapPtr(.transient_vector, &obj_d);

    try testing.expect(a.tag() == .keyword);
    try testing.expect(b.tag() == .fn_val);
    try testing.expect(c.tag() == .cons);
    try testing.expect(d.tag() == .transient_vector);

    try testing.expectEqual(&obj_a, a.decodePtr(*u64));
    try testing.expectEqual(&obj_b, b.decodePtr(*u64));
    try testing.expectEqual(&obj_c, c.decodePtr(*u64));
    try testing.expectEqual(&obj_d, d.decodePtr(*u64));
}

test "Value is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Value));
}

test "F-004 g2 64-slot layout: HeapTag and Tag are integer-aligned for heap entries" {
    // Per ADR-0027 §2 + simplify finding #8 collapse: heapTagToTag is now
    // a single @enumFromInt. This requires Tag heap entries (0..63) to
    // hold the same integer values as HeapTag (0..63).
    try testing.expectEqual(@intFromEnum(HeapTag.string), @intFromEnum(Value.Tag.string));
    try testing.expectEqual(@intFromEnum(HeapTag.range), @intFromEnum(Value.Tag.range));
    try testing.expectEqual(@intFromEnum(HeapTag.map_entry), @intFromEnum(Value.Tag.map_entry));
    try testing.expectEqual(@intFromEnum(HeapTag.typed_instance), @intFromEnum(Value.Tag.typed_instance));
    try testing.expectEqual(@intFromEnum(HeapTag.big_int), @intFromEnum(Value.Tag.big_int));
    try testing.expectEqual(@intFromEnum(HeapTag.wasm_funcref), @intFromEnum(Value.Tag.wasm_funcref));
    try testing.expectEqual(@intFromEnum(HeapTag.tval), @intFromEnum(Value.Tag.tval));
}

test "F-004 day-1 Tag additions encode + decode through Group A" {
    // The g2 widening adds range / string_seq / array_seq / map_entry
    // to Group A. Encode a heap pointer with each and confirm the
    // round-trip lands the same Tag.
    var obj_range: u64 align(8) = 0;
    var obj_string_seq: u64 align(8) = 0;
    var obj_array_seq: u64 align(8) = 0;
    var obj_map_entry: u64 align(8) = 0;

    const v_range = Value.encodeHeapPtr(.range, &obj_range);
    const v_string_seq = Value.encodeHeapPtr(.string_seq, &obj_string_seq);
    const v_array_seq = Value.encodeHeapPtr(.array_seq, &obj_array_seq);
    const v_map_entry = Value.encodeHeapPtr(.map_entry, &obj_map_entry);

    try testing.expectEqual(Value.Tag.range, v_range.tag());
    try testing.expectEqual(Value.Tag.string_seq, v_string_seq.tag());
    try testing.expectEqual(Value.Tag.array_seq, v_array_seq.tag());
    try testing.expectEqual(Value.Tag.map_entry, v_map_entry.tag());

    try testing.expectEqual(&obj_range, v_range.decodePtr(*u64));
    try testing.expectEqual(&obj_string_seq, v_string_seq.decodePtr(*u64));
    try testing.expectEqual(&obj_array_seq, v_array_seq.decodePtr(*u64));
    try testing.expectEqual(&obj_map_entry, v_map_entry.decodePtr(*u64));
}

test "F-004 big_int slot rotation: now Group D slot 0 (value 48)" {
    // Per ADR-0027 §5 + the §9.7 row 5.2.b commit message, big_int
    // moves from g1 slot 29 to g2 slot 48 (Group D position 0).
    try testing.expectEqual(@as(u8, 48), @intFromEnum(HeapTag.big_int));

    var obj: u64 align(8) = 0xCAFE_BABE;
    const v = Value.encodeHeapPtr(.big_int, &obj);
    try testing.expectEqual(Value.Tag.big_int, v.tag());
    try testing.expectEqual(&obj, v.decodePtr(*u64));
}

test "Value.heapHeader returns null for every immediate kind" {
    try testing.expect(Value.nil_val.heapHeader() == null);
    try testing.expect(Value.true_val.heapHeader() == null);
    try testing.expect(Value.false_val.heapHeader() == null);
    try testing.expect(Value.initInteger(42).heapHeader() == null);
    try testing.expect(Value.initFloat(3.14).heapHeader() == null);
    try testing.expect(Value.initChar('a').heapHeader() == null);
}

test "Value.heapHeader returns the decoded pointer for heap-tagged Values" {
    // The Cell layout matches the 5.3.b.* "HeapHeader at offset 0"
    // convention so the alias is valid.
    const Cell = extern struct { header: HeapHeader = HeapHeader.init(.string), payload: u64 = 0 };
    var c: Cell align(8) = .{};
    const v = Value.encodeHeapPtr(.string, &c);
    const hdr = v.heapHeader();
    try testing.expect(hdr != null);
    try testing.expectEqual(@as(*HeapHeader, @ptrCast(&c)), hdr.?);
}

test "Value.heapHeader skips .var_ref / .ns (Env-lifetime, not GC-managed)" {
    // ADR-0083: `.var_ref` (20) and `.ns` (21) are heap-TAGGED but point at
    // Env-owned structs with NO HeapHeader at offset 0. The membrane must
    // return null for them so the GC never decodes one as a header + marks it.
    var fake_var: u64 align(8) = 0xdead;
    var fake_ns: u64 align(8) = 0xbeef;
    try testing.expect(Value.encodeHeapPtr(.var_ref, &fake_var).heapHeader() == null);
    try testing.expect(Value.encodeHeapPtr(.ns, &fake_ns).heapHeader() == null);
    // sanity: the tags still classify correctly (only the GC membrane skips).
    try testing.expect(Value.encodeHeapPtr(.ns, &fake_ns).tag() == .ns);
}

test "F-004 inline wasm slots: funcref + externref encode through Group D" {
    // wasm_funcref + wasm_externref live at D6 / D7 inline per F-004 +
    // ADR-0027 §2; 5.2.b lands the slot encoding only (Phase 16 entry
    // adds the marshalling wrapper per D-036).
    var obj_func: u64 align(8) = 0;
    var obj_extern: u64 align(8) = 0;

    const v_func = Value.encodeHeapPtr(.wasm_funcref, &obj_func);
    const v_extern = Value.encodeHeapPtr(.wasm_externref, &obj_extern);

    try testing.expectEqual(Value.Tag.wasm_funcref, v_func.tag());
    try testing.expectEqual(Value.Tag.wasm_externref, v_extern.tag());
}
