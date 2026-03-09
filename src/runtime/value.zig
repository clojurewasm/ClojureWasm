// Value type — Runtime value representation for ClojureWasm.
//
// Uses NaN boxing for compact 8-byte representation.
// IEEE 754 double NaN space encodes tagged values:
//   top16 < 0xFFF8 → float (raw f64 bits pass-through)
//   0xFFF8 → heap C (sub-type[47:45] + addr>>3[44:0]), types 16-23
//   0xFFF9 → integer (i48 signed, overflow → float promotion)
//   0xFFFA → heap A (sub-type[47:45] + addr>>3[44:0]), types 0-7
//   0xFFFB → constant (0=nil, 1=true, 2=false)
//   0xFFFC → char (u21 codepoint)
//   0xFFFD → builtin_fn (48-bit function pointer)
//   0xFFFE → heap B (sub-type[47:45] + addr>>3[44:0]), types 8-15
//   0xFFFF → heap D (sub-type[47:45] + addr>>3[44:0]), types 24-31

const std = @import("std");
const testing = std.testing;

// --- NaN boxing constants ---

const NB_HEAP_TAG_C: u64 = 0xFFF8_0000_0000_0000; // heap types 16-23
const NB_INT_TAG: u64 = 0xFFF9_0000_0000_0000;
const NB_HEAP_TAG_A: u64 = 0xFFFA_0000_0000_0000; // heap types 0-7
const NB_CONST_TAG: u64 = 0xFFFB_0000_0000_0000;
const NB_CHAR_TAG: u64 = 0xFFFC_0000_0000_0000;
const NB_BUILTIN_FN_TAG: u64 = 0xFFFD_0000_0000_0000;
const NB_HEAP_TAG_B: u64 = 0xFFFE_0000_0000_0000; // heap types 8-15
const NB_HEAP_TAG_D: u64 = 0xFFFF_0000_0000_0000; // heap types 24-31
const NB_TAG_SHIFT: u6 = 48;
const NB_PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
const NB_ADDR_SHIFTED_MASK: u64 = 0x0000_1FFF_FFFF_FFFF; // 45 bits for addr >> 3
const NB_HEAP_SUBTYPE_SHIFT: u6 = 45; // 3-bit sub-type in bits 47-45
const NB_ADDR_ALIGN_SHIFT: u3 = 3; // 8-byte alignment (>>3)
const NB_HEAP_GROUP_SIZE: u8 = 8;

// --- Heap type slot assignment (1:1 mapping, no sharing) ---
//
// | Group (tag) | Sub 0    | Sub 1  | Sub 2   | Sub 3     | Sub 4     | Sub 5     | Sub 6       | Sub 7      |
// |-------------|----------|--------|---------|-----------|-----------|-----------|-------------|------------|
// | A (0xFFFA)  | string   | symbol | keyword | list      | vector    | array_map | hash_map    | hash_set   |
// | B (0xFFFE)  | fn_val   | atom   | var_ref | regex     | protocol  | multi_fn  | protocol_fn | delay      |
// | C (0xFFF8)  | lazy_seq | cons   | reduced | ex_info   | ns        | agent     | ref         | volatile   |
// | D (0xFFFF)  | t_vector | t_map  | t_set   | chunk_buf | chunked_c | wasm_mod  | wasm_fn     | class_inst |

const HeapTag = enum(u8) {
    // Group A (0-7)
    string = 0,
    symbol = 1,
    keyword = 2,
    list = 3,
    vector = 4,
    array_map = 5,
    hash_map = 6,
    hash_set = 7,
    // Group B (8-15)
    fn_val = 8,
    atom = 9,
    var_ref = 10,
    regex = 11,
    protocol = 12,
    multi_fn = 13,
    protocol_fn = 14,
    delay = 15,
    // Group C (16-23)
    lazy_seq = 16,
    cons = 17,
    reduced = 18,
    ex_info = 19,
    ns = 20,
    agent = 21,
    ref = 22,
    @"volatile" = 23,
    // Group D (24-31)
    transient_vector = 24,
    transient_map = 25,
    transient_set = 26,
    chunk_buffer = 27,
    chunked_cons = 28,
    wasm_module = 29,
    wasm_fn = 30,
    class_inst = 31,
};

// --- HeapHeader ---
// Prefixed to every heap-allocated object for GC and metadata.

pub const HeapHeader = extern struct {
    tag: u8, // HeapTag discriminant
    flags: Flags,

    pub const Flags = packed struct(u8) {
        marked: bool = false, // GC mark bit
        frozen: bool = false, // Arena freeze flag
        _pad: u6 = 0,
    };

    pub fn init(heap_tag: HeapTag) HeapHeader {
        return .{ .tag = @intFromEnum(heap_tag), .flags = .{} };
    }
};

// --- Value ---

pub const Value = enum(u64) {
    nil_val = NB_CONST_TAG | 0,
    true_val = NB_CONST_TAG | 1,
    false_val = NB_CONST_TAG | 2,
    _,

    /// Runtime type tag for dispatch.
    pub const Tag = enum {
        nil,
        boolean,
        integer,
        float,
        char,
        string,
        symbol,
        keyword,
        list,
        vector,
        array_map,
        hash_map,
        hash_set,
        fn_val,
        builtin_fn,
        atom,
        var_ref,
        regex,
        protocol,
        multi_fn,
        protocol_fn,
        delay,
        lazy_seq,
        cons,
        reduced,
        ex_info,
        ns,
        agent,
        ref,
        @"volatile",
        transient_vector,
        transient_map,
        transient_set,
        chunk_buffer,
        chunked_cons,
        wasm_module,
        wasm_fn,
        class_inst,
    };

    // --- Encoding helpers ---

    fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value {
        const addr: u64 = @intFromPtr(ptr);
        std.debug.assert(addr & 0x7 == 0); // 8-byte aligned
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

    fn decodePtr(self: Value, comptime T: type) T {
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
            .atom => .atom,
            .var_ref => .var_ref,
            .regex => .regex,
            .protocol => .protocol,
            .multi_fn => .multi_fn,
            .protocol_fn => .protocol_fn,
            .delay => .delay,
            .lazy_seq => .lazy_seq,
            .cons => .cons,
            .reduced => .reduced,
            .ex_info => .ex_info,
            .ns => .ns,
            .agent => .agent,
            .ref => .ref,
            .@"volatile" => .@"volatile",
            .transient_vector => .transient_vector,
            .transient_map => .transient_map,
            .transient_set => .transient_set,
            .chunk_buffer => .chunk_buffer,
            .chunked_cons => .chunked_cons,
            .wasm_module => .wasm_module,
            .wasm_fn => .wasm_fn,
            .class_inst => .class_inst,
        };
    }

    // --- Tag query ---

    pub fn tag(self: Value) Tag {
        const bits = @intFromEnum(self);
        const top16: u16 = @truncate(bits >> NB_TAG_SHIFT);
        if (top16 < 0xFFF8) return .float;
        return switch (top16) {
            0xFFF8 => heapTagToTag(@as(u8, @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & 0x7)) + 16),
            0xFFF9 => .integer,
            0xFFFA => heapTagToTag(@truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & 0x7)),
            0xFFFB => switch (bits & NB_PAYLOAD_MASK) {
                0 => .nil,
                1, 2 => .boolean,
                else => unreachable,
            },
            0xFFFC => .char,
            0xFFFD => .builtin_fn,
            0xFFFE => heapTagToTag(@as(u8, @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & 0x7)) + 8),
            0xFFFF => heapTagToTag(@as(u8, @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & 0x7)) + 24),
            else => unreachable,
        };
    }

    // --- Constructors ---

    pub fn initBoolean(b: bool) Value {
        return if (b) Value.true_val else Value.false_val;
    }

    pub fn initInteger(i: i64) Value {
        // i48 range: -2^47 .. 2^47-1
        if (i < -(1 << 47) or i > (1 << 47) - 1) {
            return initFloat(@floatFromInt(i));
        }
        const raw: u48 = @truncate(@as(u64, @bitCast(i)));
        return @enumFromInt(NB_INT_TAG | @as(u64, raw));
    }

    pub fn initFloat(f: f64) Value {
        const bits: u64 = @bitCast(f);
        // Canonicalize NaN values whose top16 >= 0xFFF8 to positive quiet NaN,
        // because those bit patterns are reserved for tagged values.
        if ((bits >> NB_TAG_SHIFT) >= 0xFFF8) {
            return @enumFromInt(@as(u64, 0x7FF8_0000_0000_0000));
        }
        return @enumFromInt(bits);
    }

    pub fn initChar(c: u21) Value {
        return @enumFromInt(NB_CHAR_TAG | @as(u64, c));
    }

    // --- Accessors ---

    pub fn isNil(self: Value) bool {
        return self == Value.nil_val;
    }

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

    // --- Type predicates ---

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

// --- Tests ---

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

test "integer encoding/decoding" {
    const zero = Value.initInteger(0);
    try testing.expect(zero.tag() == .integer);
    try testing.expectEqual(@as(i48, 0), zero.asInteger());

    const pos = Value.initInteger(42);
    try testing.expectEqual(@as(i48, 42), pos.asInteger());

    const neg = Value.initInteger(-1);
    try testing.expectEqual(@as(i48, -1), neg.asInteger());

    // i48 max: 2^47 - 1 = 140737488355327
    const max_i48 = Value.initInteger((1 << 47) - 1);
    try testing.expect(max_i48.tag() == .integer);
    try testing.expectEqual(@as(i48, (1 << 47) - 1), max_i48.asInteger());

    // i48 min: -2^47 = -140737488355328
    const min_i48 = Value.initInteger(-(1 << 47));
    try testing.expect(min_i48.tag() == .integer);
    try testing.expectEqual(@as(i48, -(1 << 47)), min_i48.asInteger());

    // Overflow: outside i48 range → promoted to float
    const overflow = Value.initInteger((1 << 47));
    try testing.expect(overflow.tag() == .float);

    const underflow = Value.initInteger(-(1 << 47) - 1);
    try testing.expect(underflow.tag() == .float);
}

test "float encoding/decoding" {
    const pi = Value.initFloat(3.14159);
    try testing.expect(pi.tag() == .float);
    try testing.expectApproxEqRel(@as(f64, 3.14159), pi.asFloat(), 1e-10);

    const zero = Value.initFloat(0.0);
    try testing.expect(zero.tag() == .float);
    try testing.expectEqual(@as(f64, 0.0), zero.asFloat());

    const neg = Value.initFloat(-1.5);
    try testing.expect(neg.tag() == .float);
    try testing.expectEqual(@as(f64, -1.5), neg.asFloat());

    // Positive infinity
    const inf = Value.initFloat(std.math.inf(f64));
    try testing.expect(inf.tag() == .float);
    try testing.expect(std.math.isPositiveInf(inf.asFloat()));

    // Negative infinity
    const neg_inf = Value.initFloat(-std.math.inf(f64));
    try testing.expect(neg_inf.tag() == .float);
    try testing.expect(std.math.isNegativeInf(neg_inf.asFloat()));

    // Positive quiet NaN → stays NaN
    const nan = Value.initFloat(std.math.nan(f64));
    try testing.expect(nan.tag() == .float);
    try testing.expect(std.math.isNan(nan.asFloat()));
}

test "NaN canonicalization" {
    // Negative NaN patterns (top16 >= 0xFFF8) must be canonicalized
    // to positive quiet NaN to avoid collision with tagged values.
    const canonical_nan: u64 = 0x7FF8_0000_0000_0000;

    // Create a negative quiet NaN (0xFFF8...)
    const neg_nan: f64 = @bitCast(@as(u64, 0xFFF8_0000_0000_0001));
    const result = Value.initFloat(neg_nan);
    try testing.expect(result.tag() == .float);
    try testing.expectEqual(canonical_nan, @intFromEnum(result));
}

test "char encoding/decoding" {
    const a = Value.initChar('a');
    try testing.expect(a.tag() == .char);
    try testing.expectEqual(@as(u21, 'a'), a.asChar());

    // Unicode: emoji
    const emoji = Value.initChar(0x1F600); // grinning face
    try testing.expect(emoji.tag() == .char);
    try testing.expectEqual(@as(u21, 0x1F600), emoji.asChar());
}

test "type predicates" {
    const nil: Value = .nil_val;
    const int = Value.initInteger(42);
    const float = Value.initFloat(3.14);

    try testing.expect(nil.isNil());
    try testing.expect(!int.isNil());

    try testing.expect(int.isInt());
    try testing.expect(!float.isInt());

    try testing.expect(float.isFloat());
    try testing.expect(!int.isFloat());

    try testing.expect(int.isNumber());
    try testing.expect(float.isNumber());
    try testing.expect(!nil.isNumber());
}

test "HeapHeader" {
    var hdr = HeapHeader.init(.string);
    try testing.expectEqual(@as(u8, 0), hdr.tag);
    try testing.expect(!hdr.flags.marked);
    try testing.expect(!hdr.flags.frozen);

    hdr.flags.marked = true;
    try testing.expect(hdr.flags.marked);
    try testing.expect(!hdr.flags.frozen);

    hdr.flags.frozen = true;
    try testing.expect(hdr.flags.marked);
    try testing.expect(hdr.flags.frozen);
}

test "heap pointer round-trip" {
    // Allocate an 8-byte aligned object and verify encoding/decoding
    var data: u64 align(8) = 0xDEAD_BEEF;
    const encoded = Value.encodeHeapPtr(.string, &data);
    try testing.expect(encoded.tag() == .string);
    const decoded = encoded.decodePtr(*u64);
    try testing.expectEqual(&data, decoded);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), decoded.*);
}

test "heap pointer tags for all groups" {
    // Test one type from each heap group
    var obj_a: u64 align(8) = 0; // Group A
    var obj_b: u64 align(8) = 0; // Group B
    var obj_c: u64 align(8) = 0; // Group C
    var obj_d: u64 align(8) = 0; // Group D

    const a = Value.encodeHeapPtr(.keyword, &obj_a); // slot 2, Group A
    const b = Value.encodeHeapPtr(.fn_val, &obj_b); // slot 8, Group B
    const c = Value.encodeHeapPtr(.cons, &obj_c); // slot 17, Group C
    const d = Value.encodeHeapPtr(.transient_vector, &obj_d); // slot 24, Group D

    try testing.expect(a.tag() == .keyword);
    try testing.expect(b.tag() == .fn_val);
    try testing.expect(c.tag() == .cons);
    try testing.expect(d.tag() == .transient_vector);

    // Verify pointers round-trip
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
