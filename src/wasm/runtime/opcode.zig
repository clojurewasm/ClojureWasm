// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Wasm opcode definitions.
//
// Single-byte opcodes (0x00-0xd2), 0xFC-prefixed misc opcodes,
// and 0xFD-prefixed SIMD opcodes (Phase 36).

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
    simd_prefix = 0xFD,

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

/// 0xFD-prefixed SIMD opcodes (Wasm SIMD proposal, 128-bit packed).
pub const SimdOpcode = enum(u32) {
    // Memory
    v128_load = 0x00,
    v128_load8x8_s = 0x01,
    v128_load8x8_u = 0x02,
    v128_load16x4_s = 0x03,
    v128_load16x4_u = 0x04,
    v128_load32x2_s = 0x05,
    v128_load32x2_u = 0x06,
    v128_load8_splat = 0x07,
    v128_load16_splat = 0x08,
    v128_load32_splat = 0x09,
    v128_load64_splat = 0x0A,
    v128_store = 0x0B,

    // Constant
    v128_const = 0x0C,

    // Shuffle / swizzle
    i8x16_shuffle = 0x0D,
    i8x16_swizzle = 0x0E,

    // Splat
    i8x16_splat = 0x0F,
    i16x8_splat = 0x10,
    i32x4_splat = 0x11,
    i64x2_splat = 0x12,
    f32x4_splat = 0x13,
    f64x2_splat = 0x14,

    // Extract / replace lane
    i8x16_extract_lane_s = 0x15,
    i8x16_extract_lane_u = 0x16,
    i8x16_replace_lane = 0x17,
    i16x8_extract_lane_s = 0x18,
    i16x8_extract_lane_u = 0x19,
    i16x8_replace_lane = 0x1A,
    i32x4_extract_lane = 0x1B,
    i32x4_replace_lane = 0x1C,
    i64x2_extract_lane = 0x1D,
    i64x2_replace_lane = 0x1E,
    f32x4_extract_lane = 0x1F,
    f32x4_replace_lane = 0x20,
    f64x2_extract_lane = 0x21,
    f64x2_replace_lane = 0x22,

    // i8x16 comparison
    i8x16_eq = 0x23,
    i8x16_ne = 0x24,
    i8x16_lt_s = 0x25,
    i8x16_lt_u = 0x26,
    i8x16_gt_s = 0x27,
    i8x16_gt_u = 0x28,
    i8x16_le_s = 0x29,
    i8x16_le_u = 0x2A,
    i8x16_ge_s = 0x2B,
    i8x16_ge_u = 0x2C,

    // i16x8 comparison
    i16x8_eq = 0x2D,
    i16x8_ne = 0x2E,
    i16x8_lt_s = 0x2F,
    i16x8_lt_u = 0x30,
    i16x8_gt_s = 0x31,
    i16x8_gt_u = 0x32,
    i16x8_le_s = 0x33,
    i16x8_le_u = 0x34,
    i16x8_ge_s = 0x35,
    i16x8_ge_u = 0x36,

    // i32x4 comparison
    i32x4_eq = 0x37,
    i32x4_ne = 0x38,
    i32x4_lt_s = 0x39,
    i32x4_lt_u = 0x3A,
    i32x4_gt_s = 0x3B,
    i32x4_gt_u = 0x3C,
    i32x4_le_s = 0x3D,
    i32x4_le_u = 0x3E,
    i32x4_ge_s = 0x3F,
    i32x4_ge_u = 0x40,

    // f32x4 comparison
    f32x4_eq = 0x41,
    f32x4_ne = 0x42,
    f32x4_lt = 0x43,
    f32x4_gt = 0x44,
    f32x4_le = 0x45,
    f32x4_ge = 0x46,

    // f64x2 comparison
    f64x2_eq = 0x47,
    f64x2_ne = 0x48,
    f64x2_lt = 0x49,
    f64x2_gt = 0x4A,
    f64x2_le = 0x4B,
    f64x2_ge = 0x4C,

    // v128 bitwise
    v128_not = 0x4D,
    v128_and = 0x4E,
    v128_andnot = 0x4F,
    v128_or = 0x50,
    v128_xor = 0x51,
    v128_bitselect = 0x52,
    v128_any_true = 0x53,

    // Lane-wise load/store
    v128_load8_lane = 0x54,
    v128_load16_lane = 0x55,
    v128_load32_lane = 0x56,
    v128_load64_lane = 0x57,
    v128_store8_lane = 0x58,
    v128_store16_lane = 0x59,
    v128_store32_lane = 0x5A,
    v128_store64_lane = 0x5B,

    // Zero-extending loads
    v128_load32_zero = 0x5C,
    v128_load64_zero = 0x5D,

    // Float conversion (interleaved with integer ops)
    f32x4_demote_f64x2_zero = 0x5E,
    f64x2_promote_low_f32x4 = 0x5F,

    // i8x16 integer ops
    i8x16_abs = 0x60,
    i8x16_neg = 0x61,
    i8x16_popcnt = 0x62,
    i8x16_all_true = 0x63,
    i8x16_bitmask = 0x64,
    i8x16_narrow_i16x8_s = 0x65,
    i8x16_narrow_i16x8_u = 0x66,

    // f32x4 rounding (interleaved)
    f32x4_ceil = 0x67,
    f32x4_floor = 0x68,
    f32x4_trunc = 0x69,
    f32x4_nearest = 0x6A,

    // i8x16 shifts and arithmetic
    i8x16_shl = 0x6B,
    i8x16_shr_s = 0x6C,
    i8x16_shr_u = 0x6D,
    i8x16_add = 0x6E,
    i8x16_add_sat_s = 0x6F,
    i8x16_add_sat_u = 0x70,
    i8x16_sub = 0x71,
    i8x16_sub_sat_s = 0x72,
    i8x16_sub_sat_u = 0x73,

    // f64x2 rounding (interleaved)
    f64x2_ceil = 0x74,
    f64x2_floor = 0x75,

    // i8x16 min/max
    i8x16_min_s = 0x76,
    i8x16_min_u = 0x77,
    i8x16_max_s = 0x78,
    i8x16_max_u = 0x79,

    // f64x2 rounding (interleaved)
    f64x2_trunc = 0x7A,

    // i8x16 average
    i8x16_avgr_u = 0x7B,

    // Pairwise add
    i16x8_extadd_pairwise_i8x16_s = 0x7C,
    i16x8_extadd_pairwise_i8x16_u = 0x7D,
    i32x4_extadd_pairwise_i16x8_s = 0x7E,
    i32x4_extadd_pairwise_i16x8_u = 0x7F,

    // i16x8 integer ops
    i16x8_abs = 0x80,
    i16x8_neg = 0x81,
    i16x8_q15mulr_sat_s = 0x82,
    i16x8_all_true = 0x83,
    i16x8_bitmask = 0x84,
    i16x8_narrow_i32x4_s = 0x85,
    i16x8_narrow_i32x4_u = 0x86,
    i16x8_extend_low_i8x16_s = 0x87,
    i16x8_extend_high_i8x16_s = 0x88,
    i16x8_extend_low_i8x16_u = 0x89,
    i16x8_extend_high_i8x16_u = 0x8A,
    i16x8_shl = 0x8B,
    i16x8_shr_s = 0x8C,
    i16x8_shr_u = 0x8D,
    i16x8_add = 0x8E,
    i16x8_add_sat_s = 0x8F,
    i16x8_add_sat_u = 0x90,
    i16x8_sub = 0x91,
    i16x8_sub_sat_s = 0x92,
    i16x8_sub_sat_u = 0x93,

    // f64x2 rounding (interleaved)
    f64x2_nearest = 0x94,

    // i16x8 multiply and min/max
    i16x8_mul = 0x95,
    i16x8_min_s = 0x96,
    i16x8_min_u = 0x97,
    i16x8_max_s = 0x98,
    i16x8_max_u = 0x99,

    // i16x8 average and extended multiply
    i16x8_avgr_u = 0x9B,
    i16x8_extmul_low_i8x16_s = 0x9C,
    i16x8_extmul_high_i8x16_s = 0x9D,
    i16x8_extmul_low_i8x16_u = 0x9E,
    i16x8_extmul_high_i8x16_u = 0x9F,

    // i32x4 integer ops
    i32x4_abs = 0xA0,
    i32x4_neg = 0xA1,
    i32x4_all_true = 0xA3,
    i32x4_bitmask = 0xA4,
    i32x4_extend_low_i16x8_s = 0xA7,
    i32x4_extend_high_i16x8_s = 0xA8,
    i32x4_extend_low_i16x8_u = 0xA9,
    i32x4_extend_high_i16x8_u = 0xAA,
    i32x4_shl = 0xAB,
    i32x4_shr_s = 0xAC,
    i32x4_shr_u = 0xAD,
    i32x4_add = 0xAE,
    i32x4_sub = 0xB1,
    i32x4_mul = 0xB5,
    i32x4_min_s = 0xB6,
    i32x4_min_u = 0xB7,
    i32x4_max_s = 0xB8,
    i32x4_max_u = 0xB9,
    i32x4_dot_i16x8_s = 0xBA,
    i32x4_extmul_low_i16x8_s = 0xBC,
    i32x4_extmul_high_i16x8_s = 0xBD,
    i32x4_extmul_low_i16x8_u = 0xBE,
    i32x4_extmul_high_i16x8_u = 0xBF,

    // i64x2 integer ops
    i64x2_abs = 0xC0,
    i64x2_neg = 0xC1,
    i64x2_all_true = 0xC3,
    i64x2_bitmask = 0xC4,
    i64x2_extend_low_i32x4_s = 0xC7,
    i64x2_extend_high_i32x4_s = 0xC8,
    i64x2_extend_low_i32x4_u = 0xC9,
    i64x2_extend_high_i32x4_u = 0xCA,
    i64x2_shl = 0xCB,
    i64x2_shr_s = 0xCC,
    i64x2_shr_u = 0xCD,
    i64x2_add = 0xCE,
    i64x2_sub = 0xD1,
    i64x2_mul = 0xD5,

    // i64x2 comparison
    i64x2_eq = 0xD6,
    i64x2_ne = 0xD7,
    i64x2_lt_s = 0xD8,
    i64x2_gt_s = 0xD9,
    i64x2_le_s = 0xDA,
    i64x2_ge_s = 0xDB,

    // i64x2 extended multiply
    i64x2_extmul_low_i32x4_s = 0xDC,
    i64x2_extmul_high_i32x4_s = 0xDD,
    i64x2_extmul_low_i32x4_u = 0xDE,
    i64x2_extmul_high_i32x4_u = 0xDF,

    // f32x4 arithmetic
    f32x4_abs = 0xE0,
    f32x4_neg = 0xE1,
    f32x4_sqrt = 0xE3,
    f32x4_add = 0xE4,
    f32x4_sub = 0xE5,
    f32x4_mul = 0xE6,
    f32x4_div = 0xE7,
    f32x4_min = 0xE8,
    f32x4_max = 0xE9,
    f32x4_pmin = 0xEA,
    f32x4_pmax = 0xEB,

    // f64x2 arithmetic
    f64x2_abs = 0xEC,
    f64x2_neg = 0xED,
    f64x2_sqrt = 0xEF,
    f64x2_add = 0xF0,
    f64x2_sub = 0xF1,
    f64x2_mul = 0xF2,
    f64x2_div = 0xF3,
    f64x2_min = 0xF4,
    f64x2_max = 0xF5,
    f64x2_pmin = 0xF6,
    f64x2_pmax = 0xF7,

    // Conversion
    i32x4_trunc_sat_f32x4_s = 0xF8,
    i32x4_trunc_sat_f32x4_u = 0xF9,
    f32x4_convert_i32x4_s = 0xFA,
    f32x4_convert_i32x4_u = 0xFB,
    i32x4_trunc_sat_f64x2_s_zero = 0xFC,
    i32x4_trunc_sat_f64x2_u_zero = 0xFD,
    f64x2_convert_low_i32x4_s = 0xFE,
    f64x2_convert_low_i32x4_u = 0xFF,

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

test "SimdOpcode — SIMD opcodes have correct values" {
    // Memory
    try std.testing.expectEqual(@as(u32, 0x00), @intFromEnum(SimdOpcode.v128_load));
    try std.testing.expectEqual(@as(u32, 0x0B), @intFromEnum(SimdOpcode.v128_store));
    try std.testing.expectEqual(@as(u32, 0x0C), @intFromEnum(SimdOpcode.v128_const));

    // Shuffle/splat
    try std.testing.expectEqual(@as(u32, 0x0D), @intFromEnum(SimdOpcode.i8x16_shuffle));
    try std.testing.expectEqual(@as(u32, 0x0F), @intFromEnum(SimdOpcode.i8x16_splat));
    try std.testing.expectEqual(@as(u32, 0x14), @intFromEnum(SimdOpcode.f64x2_splat));

    // Extract/replace
    try std.testing.expectEqual(@as(u32, 0x15), @intFromEnum(SimdOpcode.i8x16_extract_lane_s));
    try std.testing.expectEqual(@as(u32, 0x22), @intFromEnum(SimdOpcode.f64x2_replace_lane));

    // Comparison
    try std.testing.expectEqual(@as(u32, 0x23), @intFromEnum(SimdOpcode.i8x16_eq));
    try std.testing.expectEqual(@as(u32, 0x4C), @intFromEnum(SimdOpcode.f64x2_ge));

    // Bitwise
    try std.testing.expectEqual(@as(u32, 0x4D), @intFromEnum(SimdOpcode.v128_not));
    try std.testing.expectEqual(@as(u32, 0x53), @intFromEnum(SimdOpcode.v128_any_true));

    // Lane load/store
    try std.testing.expectEqual(@as(u32, 0x54), @intFromEnum(SimdOpcode.v128_load8_lane));
    try std.testing.expectEqual(@as(u32, 0x5D), @intFromEnum(SimdOpcode.v128_load64_zero));

    // i8x16 ops
    try std.testing.expectEqual(@as(u32, 0x60), @intFromEnum(SimdOpcode.i8x16_abs));
    try std.testing.expectEqual(@as(u32, 0x6E), @intFromEnum(SimdOpcode.i8x16_add));
    try std.testing.expectEqual(@as(u32, 0x7B), @intFromEnum(SimdOpcode.i8x16_avgr_u));

    // i16x8 ops
    try std.testing.expectEqual(@as(u32, 0x80), @intFromEnum(SimdOpcode.i16x8_abs));
    try std.testing.expectEqual(@as(u32, 0x95), @intFromEnum(SimdOpcode.i16x8_mul));

    // i32x4 ops
    try std.testing.expectEqual(@as(u32, 0xA0), @intFromEnum(SimdOpcode.i32x4_abs));
    try std.testing.expectEqual(@as(u32, 0xBA), @intFromEnum(SimdOpcode.i32x4_dot_i16x8_s));

    // i64x2 ops
    try std.testing.expectEqual(@as(u32, 0xC0), @intFromEnum(SimdOpcode.i64x2_abs));
    try std.testing.expectEqual(@as(u32, 0xD5), @intFromEnum(SimdOpcode.i64x2_mul));

    // f32x4 arithmetic
    try std.testing.expectEqual(@as(u32, 0xE0), @intFromEnum(SimdOpcode.f32x4_abs));
    try std.testing.expectEqual(@as(u32, 0xEB), @intFromEnum(SimdOpcode.f32x4_pmax));

    // f64x2 arithmetic
    try std.testing.expectEqual(@as(u32, 0xEC), @intFromEnum(SimdOpcode.f64x2_abs));
    try std.testing.expectEqual(@as(u32, 0xF7), @intFromEnum(SimdOpcode.f64x2_pmax));

    // Conversion
    try std.testing.expectEqual(@as(u32, 0xF8), @intFromEnum(SimdOpcode.i32x4_trunc_sat_f32x4_s));
    try std.testing.expectEqual(@as(u32, 0xFF), @intFromEnum(SimdOpcode.f64x2_convert_low_i32x4_u));
}

test "SimdOpcode — decode from raw u32" {
    const val: u32 = 0x6E; // i8x16.add
    const op: SimdOpcode = @enumFromInt(val);
    try std.testing.expectEqual(SimdOpcode.i8x16_add, op);
}

test "MAGIC and VERSION" {
    try std.testing.expectEqualSlices(u8, "\x00asm", &MAGIC);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0 }, &VERSION);
}
