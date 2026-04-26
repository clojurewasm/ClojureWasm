//! NaN-boxed Value type for ClojureWasm runtime.
//!
//! Every Clojure value is a `u64` using IEEE-754 NaN boxing. The upper
//! 16 bits act as a tag:
//!
//!   top16 < 0xFFF8                 raw f64 (pass-through)
//!
//!   Heap groups (contiguous 0xFFF8-0xFFFB):
//!     0xFFF8  Group A  Core Data           sub-type[47:45] | addr>>3 [44:0]
//!     0xFFF9  Group B  Callable & Binding  sub-type[47:45] | addr>>3 [44:0]
//!     0xFFFA  Group C  Sequence & State    sub-type[47:45] | addr>>3 [44:0]
//!     0xFFFB  Group D  Transient & Ext     sub-type[47:45] | addr>>3 [44:0]
//!
//!   Immediate types (contiguous 0xFFFC-0xFFFF):
//!     0xFFFC  integer     i48, signed; overflow → float promotion
//!     0xFFFD  constant    0=nil, 1=true, 2=false
//!     0xFFFE  char        u21 codepoint
//!     0xFFFF  builtin_fn  48-bit function pointer
//!
//! Contiguous layout enables single-op classification:
//!   isHeap:      (top16 & 0xFFFC) == 0xFFF8
//!   isImmediate: (top16 & 0xFFFC) == 0xFFFC
//!
//! Slot mapping is 1:1 (no slot-sharing + discriminant) so a type check
//! reduces to a band comparison on top16 plus a 3-bit sub-type read.

const std = @import("std");
const testing = std.testing;

// Heap group tags (contiguous: 0xFFF8-0xFFFB)
const NB_HEAP_TAG_A: u64 = 0xFFF8_0000_0000_0000;
const NB_HEAP_TAG_B: u64 = 0xFFF9_0000_0000_0000;
const NB_HEAP_TAG_C: u64 = 0xFFFA_0000_0000_0000;
const NB_HEAP_TAG_D: u64 = 0xFFFB_0000_0000_0000;

// Immediate type tags (contiguous: 0xFFFC-0xFFFF)
const NB_INT_TAG: u64 = 0xFFFC_0000_0000_0000;
const NB_CONST_TAG: u64 = 0xFFFD_0000_0000_0000;
const NB_CHAR_TAG: u64 = 0xFFFE_0000_0000_0000;
const NB_BUILTIN_FN_TAG: u64 = 0xFFFF_0000_0000_0000;

const NB_TAG_SHIFT: u6 = 48;
const NB_PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
const NB_ADDR_SHIFTED_MASK: u64 = 0x0000_1FFF_FFFF_FFFF; // 45 bits for addr>>3
const NB_HEAP_SUBTYPE_SHIFT: u6 = 45; // 3-bit sub-type at bits 47..45
const NB_ADDR_ALIGN_SHIFT: u3 = 3; // 8-byte alignment (>>3)
const NB_HEAP_GROUP_SIZE: u8 = 8;

// Derived (kept in sync via expressions, not hand-written hex literals)
const NB_ADDR_ALIGN_MASK: u64 = (@as(u64, 1) << NB_ADDR_ALIGN_SHIFT) - 1;
const NB_HEAP_SUBTYPE_MASK: u64 = NB_HEAP_GROUP_SIZE - 1;
const NB_FLOAT_TAG_BOUNDARY: u16 = @truncate(NB_HEAP_TAG_A >> NB_TAG_SHIFT);
const NB_TAG_A: u16 = @truncate(NB_HEAP_TAG_A >> NB_TAG_SHIFT);
const NB_TAG_B: u16 = @truncate(NB_HEAP_TAG_B >> NB_TAG_SHIFT);
const NB_TAG_C: u16 = @truncate(NB_HEAP_TAG_C >> NB_TAG_SHIFT);
const NB_TAG_D: u16 = @truncate(NB_HEAP_TAG_D >> NB_TAG_SHIFT);
const NB_TAG_INT: u16 = @truncate(NB_INT_TAG >> NB_TAG_SHIFT);
const NB_TAG_CONST: u16 = @truncate(NB_CONST_TAG >> NB_TAG_SHIFT);
const NB_TAG_CHAR: u16 = @truncate(NB_CHAR_TAG >> NB_TAG_SHIFT);
const NB_TAG_BUILTIN: u16 = @truncate(NB_BUILTIN_FN_TAG >> NB_TAG_SHIFT);
const NB_I48_MIN: i64 = -(@as(i64, 1) << (NB_TAG_SHIFT - 1));
const NB_I48_MAX: i64 = (@as(i64, 1) << (NB_TAG_SHIFT - 1)) - 1;
const NB_CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000; // IEEE-754 positive quiet NaN

// 32 heap slots (4 groups × 8 sub-types). A type check is a band+sub-type
// read; the value's HeapTag also lives in the object's HeapHeader.
//
// | Group (band)          | Sub 0    | Sub 1    | Sub 2     | Sub 3       | Sub 4   | Sub 5   | Sub 6    | Sub 7      |
// |-----------------------|----------|----------|-----------|-------------|---------|---------|----------|------------|
// | A: Core Data (0xFFF8) | string   | symbol   | keyword   | list        | vector  | arr_map | hash_map | hash_set   |
// | B: Call/Bind (0xFFF9) | fn_val   | multi_fn | protocol  | protocol_fn | var_ref | ns      | delay    | regex      |
// | C: Seq/State (0xFFFA) | lazy_seq | cons     | chunked_c | chunk_buf   | atom    | agent   | ref      | volatile   |
// | D: Trans/Ext (0xFFFB) | t_vector | t_map    | t_set     | reduced     | ex_info | wasm_m  | wasm_fn  | class      |

/// Heap object discriminant. Stored in the object's `HeapHeader.tag` and
/// also encoded as a 3-bit sub-type within heap-tagged Values (combined
/// with the 2-bit group band).
pub const HeapTag = enum(u8) {
    // Group A: Core Data — immutable literals and persistent collections.
    string = 0,
    symbol = 1,
    keyword = 2,
    list = 3,
    vector = 4,
    array_map = 5,
    hash_map = 6,
    hash_set = 7,
    // Group B: Callable & Binding — invocable, dispatch, name resolution.
    fn_val = 8,
    multi_fn = 9,
    protocol = 10,
    protocol_fn = 11,
    var_ref = 12,
    ns = 13,
    delay = 14,
    regex = 15,
    // Group C: Sequence & State — lazy evaluation, mutable references.
    lazy_seq = 16,
    cons = 17,
    chunked_cons = 18,
    chunk_buffer = 19,
    atom = 20,
    agent = 21,
    ref = 22,
    @"volatile" = 23,
    // Group D: Transient & Extension — mutable colls, control, wasm, escape.
    transient_vector = 24,
    transient_map = 25,
    transient_set = 26,
    reduced = 27,
    ex_info = 28,
    wasm_module = 29,
    wasm_fn = 30,
    class = 31,
};

/// 2-byte header prefixed to every heap-allocated object. Used by GC
/// for mark/sweep and by the runtime for fine-grained type dispatch.
pub const HeapHeader = extern struct {
    /// HeapTag discriminant (0–31).
    tag: u8,
    /// Per-object GC and lifecycle flags.
    flags: Flags,

    pub const Flags = packed struct(u8) {
        /// GC mark bit for mark-sweep collection.
        marked: bool = false,
        /// Arena freeze flag — prevents mutation after snapshot.
        frozen: bool = false,
        _pad: u6 = 0,
    };

    pub fn init(heap_tag: HeapTag) HeapHeader {
        return .{ .tag = @intFromEnum(heap_tag), .flags = .{} };
    }
};

/// NaN-boxed runtime value. Every Clojure value fits in 8 bytes.
///
/// Use `tag()` to classify, constructors (`initInteger`, `initFloat`, …)
/// to build, and accessors (`asInteger`, `asFloat`, …) to extract.
pub const Value = enum(u64) {
    nil_val = NB_CONST_TAG | 0,
    true_val = NB_CONST_TAG | 1,
    false_val = NB_CONST_TAG | 2,
    _,

    /// High-level type tag returned by `tag()`. One slot per kind.
    pub const Tag = enum {
        // Immediates
        nil,
        boolean,
        integer,
        float,
        char,
        builtin_fn,
        // Group A: Core Data
        string,
        symbol,
        keyword,
        list,
        vector,
        array_map,
        hash_map,
        hash_set,
        // Group B: Callable & Binding
        fn_val,
        multi_fn,
        protocol,
        protocol_fn,
        var_ref,
        ns,
        delay,
        regex,
        // Group C: Sequence & State
        lazy_seq,
        cons,
        chunked_cons,
        chunk_buffer,
        atom,
        agent,
        ref,
        @"volatile",
        // Group D: Transient & Extension
        transient_vector,
        transient_map,
        transient_set,
        reduced,
        ex_info,
        wasm_module,
        wasm_fn,
        class,
    };

    /// Pack a heap pointer + HeapTag into a Value. The pointer must be
    /// 8-byte aligned so the low 3 bits are zero.
    pub fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value {
        const addr: u64 = @intFromPtr(ptr);
        std.debug.assert(addr & NB_ADDR_ALIGN_MASK == 0);
        const shifted = addr >> NB_ADDR_ALIGN_SHIFT;
        std.debug.assert(shifted <= NB_ADDR_SHIFTED_MASK);
        const type_val = @intFromEnum(ht);
        const group = type_val / NB_HEAP_GROUP_SIZE;
        const tag_base: u64 = switch (group) {
            0 => NB_HEAP_TAG_A,
            1 => NB_HEAP_TAG_B,
            2 => NB_HEAP_TAG_C,
            3 => NB_HEAP_TAG_D,
            else => unreachable,
        };
        const sub_type: u64 = type_val % NB_HEAP_GROUP_SIZE;
        return @enumFromInt(tag_base | (sub_type << NB_HEAP_SUBTYPE_SHIFT) | shifted);
    }

    /// Extract the heap pointer from a heap-tagged Value.
    pub fn decodePtr(self: Value, comptime T: type) T {
        const shifted = @intFromEnum(self) & NB_ADDR_SHIFTED_MASK;
        return @ptrFromInt(@as(usize, shifted) << NB_ADDR_ALIGN_SHIFT);
    }

    fn heapTagToTag(ht_raw: u8) Tag {
        return switch (@as(HeapTag, @enumFromInt(ht_raw))) {
            .string => .string,
            .symbol => .symbol,
            .keyword => .keyword,
            .list => .list,
            .vector => .vector,
            .array_map => .array_map,
            .hash_map => .hash_map,
            .hash_set => .hash_set,
            .fn_val => .fn_val,
            .multi_fn => .multi_fn,
            .protocol => .protocol,
            .protocol_fn => .protocol_fn,
            .var_ref => .var_ref,
            .ns => .ns,
            .delay => .delay,
            .regex => .regex,
            .lazy_seq => .lazy_seq,
            .cons => .cons,
            .chunked_cons => .chunked_cons,
            .chunk_buffer => .chunk_buffer,
            .atom => .atom,
            .agent => .agent,
            .ref => .ref,
            .@"volatile" => .@"volatile",
            .transient_vector => .transient_vector,
            .transient_map => .transient_map,
            .transient_set => .transient_set,
            .reduced => .reduced,
            .ex_info => .ex_info,
            .wasm_module => .wasm_module,
            .wasm_fn => .wasm_fn,
            .class => .class,
        };
    }

    /// Classify this Value into a Tag by inspecting the upper 16 bits.
    pub fn tag(self: Value) Tag {
        const bits = @intFromEnum(self);
        const top16: u16 = @truncate(bits >> NB_TAG_SHIFT);
        if (top16 < NB_FLOAT_TAG_BOUNDARY) return .float;
        const sub: u8 = @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & NB_HEAP_SUBTYPE_MASK);
        return switch (top16) {
            NB_TAG_A => heapTagToTag(sub),
            NB_TAG_B => heapTagToTag(sub + NB_HEAP_GROUP_SIZE),
            NB_TAG_C => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 2),
            NB_TAG_D => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 3),
            NB_TAG_INT => .integer,
            NB_TAG_CONST => switch (bits & NB_PAYLOAD_MASK) {
                0 => .nil,
                1, 2 => .boolean,
                else => unreachable,
            },
            NB_TAG_CHAR => .char,
            NB_TAG_BUILTIN => .builtin_fn,
            else => unreachable,
        };
    }

    pub fn initBoolean(b: bool) Value {
        return if (b) Value.true_val else Value.false_val;
    }

    /// Encode an integer. Values outside i48 range are promoted to float
    /// (Clojure-compatible auto-promotion within the i48 window).
    pub fn initInteger(i: i64) Value {
        if (i < NB_I48_MIN or i > NB_I48_MAX) {
            return initFloat(@floatFromInt(i));
        }
        const raw: u48 = @truncate(@as(u64, @bitCast(i)));
        return @enumFromInt(NB_INT_TAG | @as(u64, raw));
    }

    /// Encode a float. NaN bit patterns whose top16 ≥ 0xFFF8 collide
    /// with tagged values; collapse them to canonical positive quiet NaN.
    pub fn initFloat(f: f64) Value {
        const bits: u64 = @bitCast(f);
        if ((bits >> NB_TAG_SHIFT) >= NB_FLOAT_TAG_BOUNDARY) {
            return @enumFromInt(NB_CANONICAL_NAN);
        }
        return @enumFromInt(bits);
    }

    pub fn initChar(c: u21) Value {
        return @enumFromInt(NB_CHAR_TAG | @as(u64, c));
    }

    /// Pack a 48-bit function pointer into a NaN-boxed Value.
    pub fn initBuiltinFn(fn_ptr: anytype) Value {
        const addr: u64 = @intFromPtr(fn_ptr);
        std.debug.assert(addr <= NB_PAYLOAD_MASK);
        return @enumFromInt(NB_BUILTIN_FN_TAG | addr);
    }

    /// Extract the function pointer from a builtin_fn Value. Caller
    /// supplies the concrete pointer type via `FnPtr`.
    pub fn asBuiltinFn(self: Value, comptime FnPtr: type) FnPtr {
        const raw = @intFromEnum(self) & NB_PAYLOAD_MASK;
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

test "HeapHeader layout and flags" {
    var hdr = HeapHeader.init(.string);
    try testing.expectEqual(@as(u8, 0), hdr.tag);
    try testing.expect(!hdr.flags.marked);
    try testing.expect(!hdr.flags.frozen);

    hdr.flags.marked = true;
    try testing.expect(hdr.flags.marked);
    try testing.expect(!hdr.flags.frozen);

    hdr.flags.frozen = true;
    try testing.expect(hdr.flags.marked and hdr.flags.frozen);
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

test "HeapHeader is 2 bytes" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(HeapHeader));
}
