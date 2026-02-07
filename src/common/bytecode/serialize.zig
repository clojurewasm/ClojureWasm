//! Bytecode serialization/deserialization for AOT compilation.
//!
//! Binary format (little-endian):
//!
//! Header:
//!   magic: "CLJC" (4 bytes)
//!   version: u16
//!   flags: u16 (reserved)
//!
//! String Table:
//!   count: u32
//!   For each: len: u32 + bytes: [len]u8
//!
//! FnProto Table:
//!   count: u32
//!   For each: FnProto fields + code + constants
//!
//! Top-level Chunk:
//!   code_len: u32 + code + constants
//!
//! Value encoding (tag byte + payload):
//!   0x00 nil
//!   0x01 boolean (u8: 0/1)
//!   0x02 integer (i64 little-endian)
//!   0x03 float (f64 little-endian)
//!   0x04 char (u32 little-endian)
//!   0x05 string (u32 string table index)
//!   0x06 symbol (i32 ns index + u32 name index)
//!   0x07 keyword (i32 ns index + u32 name index)
//!   0x08 fn_val (u32 FnProto table index)
//!   0x09 list (u32 count + [count]Value)
//!   0x0A vector (u32 count + [count]Value)
//!   0x0B map (u32 pair count + [count*2]Value)
//!   0x0C set (u32 count + [count]Value)
//!   0x0D var_ref (u32 ns name index + u32 var name index)

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const opcodes = @import("opcodes.zig");
const value_mod = @import("../value.zig");

pub const Chunk = chunk_mod.Chunk;
pub const FnProto = chunk_mod.FnProto;
pub const Instruction = opcodes.Instruction;
pub const OpCode = opcodes.OpCode;
pub const Value = value_mod.Value;

/// Format magic bytes.
pub const MAGIC = [4]u8{ 'C', 'L', 'J', 'C' };
/// Current format version.
pub const VERSION: u16 = 1;

/// Value type tags for serialization.
pub const ValueTag = enum(u8) {
    nil = 0x00,
    boolean = 0x01,
    integer = 0x02,
    float = 0x03,
    char = 0x04,
    string = 0x05,
    symbol = 0x06,
    keyword = 0x07,
    fn_val = 0x08,
    list = 0x09,
    vector = 0x0A,
    map = 0x0B,
    set = 0x0C,
    var_ref = 0x0D,
};

// --- Byte encoding helpers (little-endian) ---

fn encodeU16(v: u16) [2]u8 {
    return std.mem.toBytes(std.mem.nativeTo(u16, v, .little));
}

fn encodeU32(v: u32) [4]u8 {
    return std.mem.toBytes(std.mem.nativeTo(u32, v, .little));
}

fn encodeI32(v: i32) [4]u8 {
    return std.mem.toBytes(std.mem.nativeTo(i32, v, .little));
}

fn encodeI64(v: i64) [8]u8 {
    return std.mem.toBytes(std.mem.nativeTo(i64, v, .little));
}

fn encodeF64(v: f64) [8]u8 {
    return std.mem.toBytes(std.mem.nativeTo(u64, @as(u64, @bitCast(v)), .little));
}

fn decodeU16(bytes: *const [2]u8) u16 {
    return std.mem.nativeTo(u16, std.mem.bytesAsValue(u16, bytes).*, .little);
}

fn decodeU32(bytes: *const [4]u8) u32 {
    return std.mem.nativeTo(u32, std.mem.bytesAsValue(u32, bytes).*, .little);
}

fn decodeI32(bytes: *const [4]u8) i32 {
    return std.mem.nativeTo(i32, std.mem.bytesAsValue(i32, bytes).*, .little);
}

fn decodeI64(bytes: *const [8]u8) i64 {
    return std.mem.nativeTo(i64, std.mem.bytesAsValue(i64, bytes).*, .little);
}

fn decodeF64(bytes: *const [8]u8) f64 {
    const bits = std.mem.nativeTo(u64, std.mem.bytesAsValue(u64, bytes).*, .little);
    return @bitCast(bits);
}

/// Serialization context — tracks string interning and FnProto indices.
pub const Serializer = struct {
    /// String table: deduplicated strings.
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    /// String lookup for dedup.
    string_map: std.StringHashMapUnmanaged(u32) = .empty,
    /// Output buffer.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// FnProto count (assigned externally before serialization).
    fn_proto_count: u32 = 0,

    pub fn deinit(self: *Serializer, allocator: std.mem.Allocator) void {
        self.strings.deinit(allocator);
        self.string_map.deinit(allocator);
        self.buf.deinit(allocator);
    }

    /// Intern a string, returning its index in the string table.
    pub fn internString(self: *Serializer, allocator: std.mem.Allocator, s: []const u8) !u32 {
        if (self.string_map.get(s)) |idx| return idx;
        const idx: u32 = @intCast(self.strings.items.len);
        try self.strings.append(allocator, s);
        try self.string_map.put(allocator, s, idx);
        return idx;
    }

    /// Write raw bytes.
    fn writeBytes(self: *Serializer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
    }

    /// Serialize a single Value.
    pub fn serializeValue(self: *Serializer, allocator: std.mem.Allocator, val: Value) !void {
        switch (val.tag()) {
            .nil => try self.buf.append(allocator, @intFromEnum(ValueTag.nil)),
            .boolean => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.boolean));
                try self.buf.append(allocator, if (val.asBoolean()) 1 else 0);
            },
            .integer => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.integer));
                try self.writeBytes(allocator, &encodeI64(val.asInteger()));
            },
            .float => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.float));
                try self.writeBytes(allocator, &encodeF64(val.asFloat()));
            },
            .char => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.char));
                try self.writeBytes(allocator, &encodeU32(val.asChar()));
            },
            .string => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.string));
                const idx = try self.internString(allocator, val.asString());
                try self.writeBytes(allocator, &encodeU32(idx));
            },
            .symbol => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.symbol));
                const sym = val.asSymbol();
                if (sym.ns) |ns| {
                    const ns_idx = try self.internString(allocator, ns);
                    try self.writeBytes(allocator, &encodeI32(@intCast(ns_idx)));
                } else {
                    try self.writeBytes(allocator, &encodeI32(-1));
                }
                const name_idx = try self.internString(allocator, sym.name);
                try self.writeBytes(allocator, &encodeU32(name_idx));
            },
            .keyword => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.keyword));
                const kw = val.asKeyword();
                if (kw.ns) |ns| {
                    const ns_idx = try self.internString(allocator, ns);
                    try self.writeBytes(allocator, &encodeI32(@intCast(ns_idx)));
                } else {
                    try self.writeBytes(allocator, &encodeI32(-1));
                }
                const name_idx = try self.internString(allocator, kw.name);
                try self.writeBytes(allocator, &encodeU32(name_idx));
            },
            .fn_val => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.fn_val));
                // TODO: Map fn_val pointer to FnProto table index
                try self.writeBytes(allocator, &encodeU32(0));
            },
            .vector => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.vector));
                const items = val.asVector().items;
                try self.writeBytes(allocator, &encodeU32(@intCast(items.len)));
                for (items) |item| {
                    try self.serializeValue(allocator, item);
                }
            },
            .list => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.list));
                const items = val.asList().items;
                try self.writeBytes(allocator, &encodeU32(@intCast(items.len)));
                for (items) |item| {
                    try self.serializeValue(allocator, item);
                }
            },
            .map => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.map));
                const entries = val.asMap().entries;
                try self.writeBytes(allocator, &encodeU32(@intCast(entries.len / 2)));
                for (entries) |entry| {
                    try self.serializeValue(allocator, entry);
                }
            },
            .set => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.set));
                const items = val.asSet().items;
                try self.writeBytes(allocator, &encodeU32(@intCast(items.len)));
                for (items) |item| {
                    try self.serializeValue(allocator, item);
                }
            },
            else => {
                // Unsupported type — serialize as nil
                try self.buf.append(allocator, @intFromEnum(ValueTag.nil));
            },
        }
    }

    /// Serialize a FnProto.
    pub fn serializeFnProto(self: *Serializer, allocator: std.mem.Allocator, proto: *const FnProto) !void {
        // Name (string table index or -1)
        if (proto.name) |name| {
            const idx = try self.internString(allocator, name);
            try self.writeBytes(allocator, &encodeI32(@intCast(idx)));
        } else {
            try self.writeBytes(allocator, &encodeI32(-1));
        }

        // Metadata
        try self.buf.append(allocator, proto.arity);
        try self.buf.append(allocator, if (proto.variadic) 1 else 0);
        try self.writeBytes(allocator, &encodeU16(proto.local_count));
        try self.writeBytes(allocator, &encodeU16(proto.capture_count));
        try self.buf.append(allocator, if (proto.has_self_ref) 1 else 0);

        // Capture slots
        for (proto.capture_slots) |slot| {
            try self.writeBytes(allocator, &encodeU16(slot));
        }

        // Code
        try self.writeBytes(allocator, &encodeU32(@intCast(proto.code.len)));
        for (proto.code) |instr| {
            try self.buf.append(allocator, @intFromEnum(instr.op));
            try self.writeBytes(allocator, &encodeU16(instr.operand));
        }

        // Constants
        try self.writeBytes(allocator, &encodeU32(@intCast(proto.constants.len)));
        for (proto.constants) |val| {
            try self.serializeValue(allocator, val);
        }

        // Debug info (lines, columns)
        try self.writeBytes(allocator, &encodeU32(@intCast(proto.lines.len)));
        for (proto.lines) |line| {
            try self.writeBytes(allocator, &encodeU32(line));
        }
        try self.writeBytes(allocator, &encodeU32(@intCast(proto.columns.len)));
        for (proto.columns) |col| {
            try self.writeBytes(allocator, &encodeU32(col));
        }
    }

    /// Write the file header.
    pub fn writeHeader(self: *Serializer, allocator: std.mem.Allocator) !void {
        try self.writeBytes(allocator, &MAGIC);
        try self.writeBytes(allocator, &encodeU16(VERSION));
        try self.writeBytes(allocator, &encodeU16(0)); // flags
    }

    /// Write the string table.
    pub fn writeStringTable(self: *Serializer, allocator: std.mem.Allocator) !void {
        try self.writeBytes(allocator, &encodeU32(@intCast(self.strings.items.len)));
        for (self.strings.items) |s| {
            try self.writeBytes(allocator, &encodeU32(@intCast(s.len)));
            try self.writeBytes(allocator, s);
        }
    }

    /// Get the serialized bytes.
    pub fn getBytes(self: *const Serializer) []const u8 {
        return self.buf.items;
    }
};

/// Deserialization context.
pub const Deserializer = struct {
    data: []const u8,
    pos: usize = 0,
    /// Reconstructed string table.
    strings: []const []const u8 = &.{},

    pub fn readU8(self: *Deserializer) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *Deserializer) !u16 {
        if (self.pos + 2 > self.data.len) return error.UnexpectedEof;
        const v = decodeU16(self.data[self.pos..][0..2]);
        self.pos += 2;
        return v;
    }

    pub fn readU32(self: *Deserializer) !u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEof;
        const v = decodeU32(self.data[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    pub fn readI32(self: *Deserializer) !i32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEof;
        const v = decodeI32(self.data[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    pub fn readI64(self: *Deserializer) !i64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEof;
        const v = decodeI64(self.data[self.pos..][0..8]);
        self.pos += 8;
        return v;
    }

    pub fn readF64(self: *Deserializer) !f64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEof;
        const v = decodeF64(self.data[self.pos..][0..8]);
        self.pos += 8;
        return v;
    }

    pub fn readSlice(self: *Deserializer, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.UnexpectedEof;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    /// Read and validate header.
    pub fn readHeader(self: *Deserializer) !void {
        const magic = try self.readSlice(4);
        if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
        const version = try self.readU16();
        if (version != VERSION) return error.UnsupportedVersion;
        _ = try self.readU16(); // flags
    }

    /// Read string table.
    pub fn readStringTable(self: *Deserializer, allocator: std.mem.Allocator) !void {
        const count = try self.readU32();
        const table = try allocator.alloc([]const u8, count);
        for (0..count) |i| {
            const len = try self.readU32();
            const bytes = try self.readSlice(len);
            table[i] = try allocator.dupe(u8, bytes);
        }
        self.strings = table;
    }

    /// Deserialize a single Value.
    pub fn deserializeValue(self: *Deserializer, allocator: std.mem.Allocator) !Value {
        const tag_byte = try self.readU8();
        const tag: ValueTag = @enumFromInt(tag_byte);

        return switch (tag) {
            .nil => Value.nil_val,
            .boolean => if ((try self.readU8()) != 0) Value.true_val else Value.false_val,
            .integer => Value.initInteger(try self.readI64()),
            .float => Value.initFloat(try self.readF64()),
            .char => Value.initChar(@intCast(try self.readU32())),
            .string => blk: {
                const idx = try self.readU32();
                if (idx >= self.strings.len) return error.InvalidStringIndex;
                break :blk Value.initString(allocator, self.strings[idx]);
            },
            .symbol => blk: {
                const ns_idx = try self.readI32();
                const name_idx = try self.readU32();
                if (name_idx >= self.strings.len) return error.InvalidStringIndex;
                const ns: ?[]const u8 = if (ns_idx >= 0) blk2: {
                    const idx: u32 = @intCast(ns_idx);
                    if (idx >= self.strings.len) return error.InvalidStringIndex;
                    break :blk2 self.strings[idx];
                } else null;
                break :blk Value.initSymbol(allocator, .{ .ns = ns, .name = self.strings[name_idx] });
            },
            .keyword => blk: {
                const ns_idx = try self.readI32();
                const name_idx = try self.readU32();
                if (name_idx >= self.strings.len) return error.InvalidStringIndex;
                const ns: ?[]const u8 = if (ns_idx >= 0) blk2: {
                    const idx: u32 = @intCast(ns_idx);
                    if (idx >= self.strings.len) return error.InvalidStringIndex;
                    break :blk2 self.strings[idx];
                } else null;
                break :blk Value.initKeyword(allocator, .{ .ns = ns, .name = self.strings[name_idx] });
            },
            .fn_val => blk: {
                _ = try self.readU32(); // FnProto index (TODO: resolve)
                break :blk Value.nil_val; // placeholder
            },
            .vector => blk: {
                const count = try self.readU32();
                const items = try allocator.alloc(Value, count);
                for (0..count) |i| {
                    items[i] = try self.deserializeValue(allocator);
                }
                const vec = try allocator.create(value_mod.PersistentVector);
                vec.* = .{ .items = items, .meta = null };
                break :blk Value.initVector(vec);
            },
            .list => blk: {
                const count = try self.readU32();
                const items = try allocator.alloc(Value, count);
                for (0..count) |i| {
                    items[i] = try self.deserializeValue(allocator);
                }
                const list = try allocator.create(value_mod.PersistentList);
                list.* = .{ .items = items, .meta = null };
                break :blk Value.initList(list);
            },
            .map => blk: {
                const pair_count = try self.readU32();
                const entries = try allocator.alloc(Value, pair_count * 2);
                for (0..pair_count * 2) |i| {
                    entries[i] = try self.deserializeValue(allocator);
                }
                const map = try allocator.create(value_mod.PersistentArrayMap);
                map.* = .{ .entries = entries, .meta = null };
                break :blk Value.initMap(map);
            },
            .set => blk: {
                const count = try self.readU32();
                const items = try allocator.alloc(Value, count);
                for (0..count) |i| {
                    items[i] = try self.deserializeValue(allocator);
                }
                const set = try allocator.create(value_mod.PersistentHashSet);
                set.* = .{ .items = items, .meta = null };
                break :blk Value.initSet(set);
            },
            .var_ref => blk: {
                _ = try self.readU32(); // ns name index
                _ = try self.readU32(); // var name index
                break :blk Value.nil_val; // placeholder — resolved during loading
            },
        };
    }

    /// Deserialize a FnProto.
    pub fn deserializeFnProto(self: *Deserializer, allocator: std.mem.Allocator) !FnProto {
        // Name
        const name_idx = try self.readI32();
        const name: ?[]const u8 = if (name_idx >= 0) blk: {
            const idx: u32 = @intCast(name_idx);
            if (idx >= self.strings.len) return error.InvalidStringIndex;
            break :blk self.strings[idx];
        } else null;

        // Metadata
        const arity = try self.readU8();
        const variadic = (try self.readU8()) != 0;
        const local_count = try self.readU16();
        const capture_count = try self.readU16();
        const has_self_ref = (try self.readU8()) != 0;

        // Capture slots
        const capture_slots = try allocator.alloc(u16, capture_count);
        for (0..capture_count) |i| {
            capture_slots[i] = try self.readU16();
        }

        // Code
        const code_len = try self.readU32();
        const code = try allocator.alloc(Instruction, code_len);
        for (0..code_len) |i| {
            const op: OpCode = @enumFromInt(try self.readU8());
            const operand = try self.readU16();
            code[i] = .{ .op = op, .operand = operand };
        }

        // Constants
        const const_len = try self.readU32();
        const constants = try allocator.alloc(Value, const_len);
        for (0..const_len) |i| {
            constants[i] = try self.deserializeValue(allocator);
        }

        // Debug info
        const lines_len = try self.readU32();
        const lines = try allocator.alloc(u32, lines_len);
        for (0..lines_len) |i| {
            lines[i] = try self.readU32();
        }
        const cols_len = try self.readU32();
        const columns = try allocator.alloc(u32, cols_len);
        for (0..cols_len) |i| {
            columns[i] = try self.readU32();
        }

        return .{
            .name = name,
            .arity = arity,
            .variadic = variadic,
            .local_count = local_count,
            .capture_count = capture_count,
            .capture_slots = capture_slots,
            .has_self_ref = has_self_ref,
            .code = code,
            .constants = constants,
            .lines = lines,
            .columns = columns,
        };
    }
};

// ============================================================
// Tests
// ============================================================

/// Helper: serialize values, prepend header + string table, return full bytes.
fn buildTestBytes(allocator: std.mem.Allocator, ser: *Serializer) ![]const u8 {
    var out: Serializer = .{};
    out.strings = ser.strings;
    out.string_map = ser.string_map;
    try out.writeHeader(allocator);
    try out.writeStringTable(allocator);
    try out.writeBytes(allocator, ser.getBytes());
    return out.getBytes();
}

test "serialize/deserialize nil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.nil_val);

    var de: Deserializer = .{ .data = ser.getBytes() };
    const val = try de.deserializeValue(alloc);
    try std.testing.expectEqual(Value.nil_val, val);
}

test "serialize/deserialize boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.true_val);
    try ser.serializeValue(alloc, Value.false_val);

    var de: Deserializer = .{ .data = ser.getBytes() };
    try std.testing.expectEqual(Value.true_val, try de.deserializeValue(alloc));
    try std.testing.expectEqual(Value.false_val, try de.deserializeValue(alloc));
}

test "serialize/deserialize integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initInteger(42));
    try ser.serializeValue(alloc, Value.initInteger(-100));
    try ser.serializeValue(alloc, Value.initInteger(0));

    var de: Deserializer = .{ .data = ser.getBytes() };
    try std.testing.expectEqual(Value.initInteger(42), try de.deserializeValue(alloc));
    try std.testing.expectEqual(Value.initInteger(-100), try de.deserializeValue(alloc));
    try std.testing.expectEqual(Value.initInteger(0), try de.deserializeValue(alloc));
}

test "serialize/deserialize float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initFloat(3.14));
    try ser.serializeValue(alloc, Value.initFloat(-0.0));

    var de: Deserializer = .{ .data = ser.getBytes() };
    const v1 = try de.deserializeValue(alloc);
    try std.testing.expectEqual(@as(f64, 3.14), v1.asFloat());
    const v2 = try de.deserializeValue(alloc);
    try std.testing.expectEqual(@as(f64, -0.0), v2.asFloat());
}

test "serialize/deserialize char" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initChar('A'));
    try ser.serializeValue(alloc, Value.initChar(0x3042)); // あ

    var de: Deserializer = .{ .data = ser.getBytes() };
    try std.testing.expectEqual(Value.initChar('A'), try de.deserializeValue(alloc));
    try std.testing.expectEqual(Value.initChar(0x3042), try de.deserializeValue(alloc));
}

test "serialize/deserialize string (full flow)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initString(alloc, "hello"));
    try ser.serializeValue(alloc, Value.initString(alloc, "hello")); // same string, dedup

    const data = try buildTestBytes(alloc, &ser);

    var de: Deserializer = .{ .data = data };
    try de.readHeader();
    try de.readStringTable(alloc);

    const v1 = try de.deserializeValue(alloc);
    const v2 = try de.deserializeValue(alloc);

    try std.testing.expectEqualStrings("hello", v1.asString());
    try std.testing.expectEqualStrings("hello", v2.asString());

    // String dedup: only 1 entry in string table
    try std.testing.expectEqual(@as(usize, 1), de.strings.len);
}

test "serialize/deserialize symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initSymbol(alloc, .{ .ns = null, .name = "foo" }));
    try ser.serializeValue(alloc, Value.initSymbol(alloc, .{ .ns = "clojure.core", .name = "map" }));

    const data = try buildTestBytes(alloc, &ser);

    var de: Deserializer = .{ .data = data };
    try de.readHeader();
    try de.readStringTable(alloc);

    const v1 = try de.deserializeValue(alloc);
    try std.testing.expectEqualStrings("foo", v1.asSymbol().name);
    try std.testing.expect(v1.asSymbol().ns == null);

    const v2 = try de.deserializeValue(alloc);
    try std.testing.expectEqualStrings("map", v2.asSymbol().name);
    try std.testing.expectEqualStrings("clojure.core", v2.asSymbol().ns.?);
}

test "serialize/deserialize keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.serializeValue(alloc, Value.initKeyword(alloc, .{ .ns = null, .name = "foo" }));

    const data = try buildTestBytes(alloc, &ser);

    var de: Deserializer = .{ .data = data };
    try de.readHeader();
    try de.readStringTable(alloc);

    const v1 = try de.deserializeValue(alloc);
    try std.testing.expectEqualStrings("foo", v1.asKeyword().name);
    try std.testing.expect(v1.asKeyword().ns == null);
}

test "serialize/deserialize FnProto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code = [_]Instruction{
        .{ .op = .local_load, .operand = 0 },
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .add },
        .{ .op = .ret },
    };
    const constants = [_]Value{Value.initInteger(1)};
    const lines = [_]u32{ 5, 5, 5, 5 };
    const columns = [_]u32{ 0, 4, 0, 0 };

    const proto = FnProto{
        .name = "inc",
        .arity = 1,
        .variadic = false,
        .local_count = 1,
        .capture_count = 0,
        .has_self_ref = false,
        .code = &code,
        .constants = &constants,
        .lines = &lines,
        .columns = &columns,
    };

    var ser: Serializer = .{};
    try ser.serializeFnProto(alloc, &proto);

    const data = try buildTestBytes(alloc, &ser);

    var de: Deserializer = .{ .data = data };
    try de.readHeader();
    try de.readStringTable(alloc);

    const result = try de.deserializeFnProto(alloc);

    try std.testing.expectEqualStrings("inc", result.name.?);
    try std.testing.expectEqual(@as(u8, 1), result.arity);
    try std.testing.expect(!result.variadic);
    try std.testing.expectEqual(@as(u16, 1), result.local_count);
    try std.testing.expectEqual(@as(u16, 0), result.capture_count);
    try std.testing.expect(!result.has_self_ref);
    try std.testing.expectEqual(@as(usize, 4), result.code.len);
    try std.testing.expectEqual(OpCode.local_load, result.code[0].op);
    try std.testing.expectEqual(@as(u16, 0), result.code[0].operand);
    try std.testing.expectEqual(OpCode.add, result.code[2].op);
    try std.testing.expectEqual(OpCode.ret, result.code[3].op);
    try std.testing.expectEqual(@as(usize, 1), result.constants.len);
    try std.testing.expectEqual(Value.initInteger(1), result.constants[0]);
    try std.testing.expectEqual(@as(usize, 4), result.lines.len);
    try std.testing.expectEqual(@as(u32, 5), result.lines[0]);
}

test "header validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};
    try ser.writeHeader(alloc);

    var de: Deserializer = .{ .data = ser.getBytes() };
    try de.readHeader();

    // Invalid magic
    var bad_data = [_]u8{ 'X', 'L', 'J', 'C', 0x01, 0x00, 0x00, 0x00 };
    var de2: Deserializer = .{ .data = &bad_data };
    try std.testing.expectError(error.InvalidMagic, de2.readHeader());
}

test "string table deduplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ser: Serializer = .{};

    const idx1 = try ser.internString(alloc, "hello");
    const idx2 = try ser.internString(alloc, "world");
    const idx3 = try ser.internString(alloc, "hello"); // dedup

    try std.testing.expectEqual(@as(u32, 0), idx1);
    try std.testing.expectEqual(@as(u32, 1), idx2);
    try std.testing.expectEqual(@as(u32, 0), idx3);
    try std.testing.expectEqual(@as(usize, 2), ser.strings.items.len);
}

test "serialize/deserialize FnProto with captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code = [_]Instruction{
        .{ .op = .upvalue_load, .operand = 0 },
        .{ .op = .ret },
    };
    const constants = [_]Value{};
    const capture_slots = [_]u16{ 3, 7 };

    const proto = FnProto{
        .name = null,
        .arity = 0,
        .variadic = true,
        .local_count = 2,
        .capture_count = 2,
        .capture_slots = &capture_slots,
        .has_self_ref = true,
        .code = &code,
        .constants = &constants,
    };

    var ser: Serializer = .{};
    try ser.serializeFnProto(alloc, &proto);

    const data = try buildTestBytes(alloc, &ser);

    var de: Deserializer = .{ .data = data };
    try de.readHeader();
    try de.readStringTable(alloc);

    const result = try de.deserializeFnProto(alloc);

    try std.testing.expect(result.name == null);
    try std.testing.expectEqual(@as(u8, 0), result.arity);
    try std.testing.expect(result.variadic);
    try std.testing.expectEqual(@as(u16, 2), result.local_count);
    try std.testing.expectEqual(@as(u16, 2), result.capture_count);
    try std.testing.expect(result.has_self_ref);
    try std.testing.expectEqual(@as(u16, 3), result.capture_slots[0]);
    try std.testing.expectEqual(@as(u16, 7), result.capture_slots[1]);
}
