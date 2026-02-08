// Wasm MVP opcode definitions.
//
// Single-byte opcodes (0x00-0xd2), 0xFC-prefixed misc opcodes,
// and 0xFD-prefixed SIMD opcode reservations (Phase 36).

const std = @import("std");

/// Wasm MVP value types as encoded in the binary format.
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B, // SIMD — Phase 36
    funcref = 0x70,
    externref = 0x6F,
};

/// Block type encoding in Wasm binary.
pub const BlockType = union(enum) {
    empty, // 0x40
    val_type: ValType,
    type_index: u32, // s33 encoded
};

/// Reference types used in tables and ref instructions.
pub const RefType = enum(u8) {
    funcref = 0x70,
    externref = 0x6F,
};

/// Import/export descriptor tags.
pub const ExternalKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
};

/// Limits encoding (memories and tables).
pub const Limits = struct {
    min: u32,
    max: ?u32,
};

/// Wasm MVP opcodes (single byte, 0x00-0xd2).
pub const Opcode = enum(u8) {
    // Control flow
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,
    end = 0x0B,
    br = 0x0C,
    br_if = 0x0D,
    br_table = 0x0E,
    @"return" = 0x0F,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1A,
    select = 0x1B,
    select_t = 0x1C,

    // Variable access
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Table access
    table_get = 0x25,
    table_set = 0x26,

    // Memory load
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2A,
    f64_load = 0x2B,
    i32_load8_s = 0x2C,
    i32_load8_u = 0x2D,
    i32_load16_s = 0x2E,
    i32_load16_u = 0x2F,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,

    // Memory store
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3A,
    i32_store16 = 0x3B,
    i64_store8 = 0x3C,
    i64_store16 = 0x3D,
    i64_store32 = 0x3E,

    // Memory size/grow
    memory_size = 0x3F,
    memory_grow = 0x40,

    // Constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // i32 comparison
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4A,
    i32_gt_u = 0x4B,
    i32_le_s = 0x4C,
    i32_le_u = 0x4D,
    i32_ge_s = 0x4E,
    i32_ge_u = 0x4F,

    // i64 comparison
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5A,

    // f32 comparison
    f32_eq = 0x5B,
    f32_ne = 0x5C,
    f32_lt = 0x5D,
    f32_gt = 0x5E,
    f32_le = 0x5F,
    f32_ge = 0x60,

    // f64 comparison
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,

    // i32 arithmetic
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6A,
    i32_sub = 0x6B,
    i32_mul = 0x6C,
    i32_div_s = 0x6D,
    i32_div_u = 0x6E,
    i32_rem_s = 0x6F,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,

    // i64 arithmetic
    i64_clz = 0x79,
    i64_ctz = 0x7A,
    i64_popcnt = 0x7B,
    i64_add = 0x7C,
    i64_sub = 0x7D,
    i64_mul = 0x7E,
    i64_div_s = 0x7F,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8A,

    // f32 arithmetic
    f32_abs = 0x8B,
    f32_neg = 0x8C,
    f32_ceil = 0x8D,
    f32_floor = 0x8E,
    f32_trunc = 0x8F,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,

    // f64 arithmetic
    f64_abs = 0x99,
    f64_neg = 0x9A,
    f64_ceil = 0x9B,
    f64_floor = 0x9C,
    f64_trunc = 0x9D,
    f64_nearest = 0x9E,
    f64_sqrt = 0x9F,
    f64_add = 0xA0,
    f64_sub = 0xA1,
    f64_mul = 0xA2,
    f64_div = 0xA3,
    f64_min = 0xA4,
    f64_max = 0xA5,
    f64_copysign = 0xA6,

    // Type conversions
    i32_wrap_i64 = 0xA7,
    i32_trunc_f32_s = 0xA8,
    i32_trunc_f32_u = 0xA9,
    i32_trunc_f64_s = 0xAA,
    i32_trunc_f64_u = 0xAB,
    i64_extend_i32_s = 0xAC,
    i64_extend_i32_u = 0xAD,
    i64_trunc_f32_s = 0xAE,
    i64_trunc_f32_u = 0xAF,
    i64_trunc_f64_s = 0xB0,
    i64_trunc_f64_u = 0xB1,
    f32_convert_i32_s = 0xB2,
    f32_convert_i32_u = 0xB3,
    f32_convert_i64_s = 0xB4,
    f32_convert_i64_u = 0xB5,
    f32_demote_f64 = 0xB6,
    f64_convert_i32_s = 0xB7,
    f64_convert_i32_u = 0xB8,
    f64_convert_i64_s = 0xB9,
    f64_convert_i64_u = 0xBA,
    f64_promote_f32 = 0xBB,
    i32_reinterpret_f32 = 0xBC,
    i64_reinterpret_f64 = 0xBD,
    f32_reinterpret_i32 = 0xBE,
    f64_reinterpret_i64 = 0xBF,

    // Sign extension (post-MVP, but widely supported)
    i32_extend8_s = 0xC0,
    i32_extend16_s = 0xC1,
    i64_extend8_s = 0xC2,
    i64_extend16_s = 0xC3,
    i64_extend32_s = 0xC4,

    // Reference types
    ref_null = 0xD0,
    ref_is_null = 0xD1,
    ref_func = 0xD2,

    // Multi-byte prefix
    misc_prefix = 0xFC,
    simd_prefix = 0xFD, // Phase 36 reservation

    _,
};

/// 0xFC-prefixed misc opcodes (saturating truncations, bulk memory, table ops).
pub const MiscOpcode = enum(u32) {
    // Saturating truncation
    i32_trunc_sat_f32_s = 0x00,
    i32_trunc_sat_f32_u = 0x01,
    i32_trunc_sat_f64_s = 0x02,
    i32_trunc_sat_f64_u = 0x03,
    i64_trunc_sat_f32_s = 0x04,
    i64_trunc_sat_f32_u = 0x05,
    i64_trunc_sat_f64_s = 0x06,
    i64_trunc_sat_f64_u = 0x07,

    // Bulk memory operations
    memory_init = 0x08,
    data_drop = 0x09,
    memory_copy = 0x0A,
    memory_fill = 0x0B,

    // Table operations
    table_init = 0x0C,
    elem_drop = 0x0D,
    table_copy = 0x0E,
    table_grow = 0x0F,
    table_size = 0x10,
    table_fill = 0x11,

    _,
};

/// Wasm section IDs.
pub const Section = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,

    _,
};

/// Wasm binary magic number and version.
pub const MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6D }; // \0asm
pub const VERSION = [4]u8{ 0x01, 0x00, 0x00, 0x00 }; // version 1

// ============================================================
// Tests
// ============================================================

test "Opcode — MVP opcodes have correct values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.@"unreachable"));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Opcode.nop));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(Opcode.end));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(Opcode.call));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(Opcode.local_get));
    try std.testing.expectEqual(@as(u8, 0x28), @intFromEnum(Opcode.i32_load));
    try std.testing.expectEqual(@as(u8, 0x41), @intFromEnum(Opcode.i32_const));
    try std.testing.expectEqual(@as(u8, 0x6A), @intFromEnum(Opcode.i32_add));
    try std.testing.expectEqual(@as(u8, 0xA7), @intFromEnum(Opcode.i32_wrap_i64));
    try std.testing.expectEqual(@as(u8, 0xBF), @intFromEnum(Opcode.f64_reinterpret_i64));
    try std.testing.expectEqual(@as(u8, 0xC0), @intFromEnum(Opcode.i32_extend8_s));
    try std.testing.expectEqual(@as(u8, 0xD0), @intFromEnum(Opcode.ref_null));
    try std.testing.expectEqual(@as(u8, 0xFC), @intFromEnum(Opcode.misc_prefix));
    try std.testing.expectEqual(@as(u8, 0xFD), @intFromEnum(Opcode.simd_prefix));
}

test "Opcode — decode from raw byte" {
    const byte: u8 = 0x6A; // i32.add
    const op: Opcode = @enumFromInt(byte);
    try std.testing.expectEqual(Opcode.i32_add, op);
}

test "Opcode — unknown byte produces non-named variant" {
    const byte: u8 = 0xFE; // not a valid opcode
    const op: Opcode = @enumFromInt(byte);
    // Should not match any named variant
    const is_known = switch (op) {
        .@"unreachable", .nop, .block, .loop, .@"if", .@"else", .end => true,
        .br, .br_if, .br_table, .@"return", .call, .call_indirect => true,
        .drop, .select, .select_t => true,
        .local_get, .local_set, .local_tee, .global_get, .global_set => true,
        .table_get, .table_set => true,
        .i32_load, .i64_load, .f32_load, .f64_load => true,
        .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u => true,
        .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u => true,
        .i64_load32_s, .i64_load32_u => true,
        .i32_store, .i64_store, .f32_store, .f64_store => true,
        .i32_store8, .i32_store16 => true,
        .i64_store8, .i64_store16, .i64_store32 => true,
        .memory_size, .memory_grow => true,
        .i32_const, .i64_const, .f32_const, .f64_const => true,
        .i32_eqz, .i32_eq, .i32_ne => true,
        .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u => true,
        .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => true,
        .i64_eqz, .i64_eq, .i64_ne => true,
        .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u => true,
        .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => true,
        .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => true,
        .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => true,
        .i32_clz, .i32_ctz, .i32_popcnt => true,
        .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u => true,
        .i32_rem_s, .i32_rem_u => true,
        .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u => true,
        .i32_rotl, .i32_rotr => true,
        .i64_clz, .i64_ctz, .i64_popcnt => true,
        .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u => true,
        .i64_rem_s, .i64_rem_u => true,
        .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u => true,
        .i64_rotl, .i64_rotr => true,
        .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => true,
        .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => true,
        .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => true,
        .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => true,
        .i32_wrap_i64 => true,
        .i32_trunc_f32_s, .i32_trunc_f32_u, .i32_trunc_f64_s, .i32_trunc_f64_u => true,
        .i64_extend_i32_s, .i64_extend_i32_u => true,
        .i64_trunc_f32_s, .i64_trunc_f32_u, .i64_trunc_f64_s, .i64_trunc_f64_u => true,
        .f32_convert_i32_s, .f32_convert_i32_u, .f32_convert_i64_s, .f32_convert_i64_u => true,
        .f32_demote_f64 => true,
        .f64_convert_i32_s, .f64_convert_i32_u, .f64_convert_i64_s, .f64_convert_i64_u => true,
        .f64_promote_f32 => true,
        .i32_reinterpret_f32, .i64_reinterpret_f64 => true,
        .f32_reinterpret_i32, .f64_reinterpret_i64 => true,
        .i32_extend8_s, .i32_extend16_s => true,
        .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => true,
        .ref_null, .ref_is_null, .ref_func => true,
        .misc_prefix, .simd_prefix => true,
        _ => false,
    };
    try std.testing.expect(!is_known);
}

test "MiscOpcode — correct values" {
    try std.testing.expectEqual(@as(u32, 0x00), @intFromEnum(MiscOpcode.i32_trunc_sat_f32_s));
    try std.testing.expectEqual(@as(u32, 0x07), @intFromEnum(MiscOpcode.i64_trunc_sat_f64_u));
    try std.testing.expectEqual(@as(u32, 0x0A), @intFromEnum(MiscOpcode.memory_copy));
    try std.testing.expectEqual(@as(u32, 0x0B), @intFromEnum(MiscOpcode.memory_fill));
    try std.testing.expectEqual(@as(u32, 0x11), @intFromEnum(MiscOpcode.table_fill));
}

test "ValType — correct encodings" {
    try std.testing.expectEqual(@as(u8, 0x7F), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(u8, 0x7E), @intFromEnum(ValType.i64));
    try std.testing.expectEqual(@as(u8, 0x7D), @intFromEnum(ValType.f32));
    try std.testing.expectEqual(@as(u8, 0x7C), @intFromEnum(ValType.f64));
    try std.testing.expectEqual(@as(u8, 0x7B), @intFromEnum(ValType.v128));
    try std.testing.expectEqual(@as(u8, 0x70), @intFromEnum(ValType.funcref));
    try std.testing.expectEqual(@as(u8, 0x6F), @intFromEnum(ValType.externref));
}

test "Section — correct IDs" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Section.custom));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Section.type));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Section.@"export"));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(Section.code));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(Section.data_count));
}

test "MAGIC and VERSION" {
    try std.testing.expectEqualSlices(u8, "\x00asm", &MAGIC);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0 }, &VERSION);
}
