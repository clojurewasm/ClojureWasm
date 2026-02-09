// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

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
//!   0x08 fn_val (u32 proto_index + u32 extra_count + [extra_count]u32 indices + i32 defining_ns)
//!   0x09 list (u32 count + [count]Value)
//!   0x0A vector (u32 count + [count]Value)
//!   0x0B map (u32 pair count + [count*2]Value)
//!   0x0C set (u32 count + [count]Value)
//!   0x0D var_ref (u32 ns name index + u32 var name index)

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const opcodes = @import("opcodes.zig");
const value_mod = @import("../value.zig");
const env_mod = @import("../env.zig");
const ns_mod = @import("../namespace.zig");
const var_mod = @import("../var.zig");

pub const Chunk = chunk_mod.Chunk;
pub const FnProto = chunk_mod.FnProto;
pub const Instruction = opcodes.Instruction;
pub const OpCode = opcodes.OpCode;
pub const Value = value_mod.Value;
pub const Env = env_mod.Env;
pub const Namespace = ns_mod.Namespace;
pub const Var = var_mod.Var;

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
    atom = 0x0E,
    volatile_ref = 0x0F,
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
    /// Map from FnProto opaque pointers to their indices in the fn_protos list.
    fn_proto_map: std.AutoHashMapUnmanaged(*const anyopaque, u32) = .empty,
    /// Ordered list of FnProto pointers (inner-first ordering for serialization).
    fn_protos: std.ArrayListUnmanaged(*const anyopaque) = .empty,

    pub fn deinit(self: *Serializer, allocator: std.mem.Allocator) void {
        self.strings.deinit(allocator);
        self.string_map.deinit(allocator);
        self.buf.deinit(allocator);
        self.fn_proto_map.deinit(allocator);
        self.fn_protos.deinit(allocator);
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
                const fn_obj = val.asFn();
                // TreeWalk closures store Closure*, not FnProto* — cannot be serialized.
                if (fn_obj.kind == .treewalk) return error.TreeWalkClosureNotSerializable;
                const proto_idx = self.fn_proto_map.get(fn_obj.proto) orelse return error.UnregisteredFnProto;
                try self.writeBytes(allocator, &encodeU32(proto_idx));
                // Extra arities
                const extra_count: u32 = if (fn_obj.extra_arities) |e| @intCast(e.len) else 0;
                try self.writeBytes(allocator, &encodeU32(extra_count));
                if (fn_obj.extra_arities) |extras| {
                    for (extras) |extra_opaque| {
                        const eidx = self.fn_proto_map.get(extra_opaque) orelse return error.UnregisteredFnProto;
                        try self.writeBytes(allocator, &encodeU32(eidx));
                    }
                }
                // Defining namespace
                if (fn_obj.defining_ns) |ns| {
                    const ns_idx = try self.internString(allocator, ns);
                    try self.writeBytes(allocator, &encodeI32(@intCast(ns_idx)));
                } else {
                    try self.writeBytes(allocator, &encodeI32(-1));
                }
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
            .var_ref => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.var_ref));
                const v = val.asVarRef();
                const ns_idx = try self.internString(allocator, v.ns_name);
                try self.writeBytes(allocator, &encodeU32(ns_idx));
                const name_idx = try self.internString(allocator, v.sym.name);
                try self.writeBytes(allocator, &encodeU32(name_idx));
            },
            .atom => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.atom));
                try self.serializeValue(allocator, val.asAtom().value);
            },
            .volatile_ref => {
                try self.buf.append(allocator, @intFromEnum(ValueTag.volatile_ref));
                try self.serializeValue(allocator, val.asVolatile().value);
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

    /// Recursively collect all FnProtos reachable from a Value (inner-first ordering).
    pub fn collectFnProtos(self: *Serializer, allocator: std.mem.Allocator, val: Value) !void {
        if (val.tag() != .fn_val) return;
        const fn_obj = val.asFn();
        // TreeWalk closures store Closure*, not FnProto* — cannot be serialized.
        if (fn_obj.kind == .treewalk) return error.TreeWalkClosureNotSerializable;
        if (self.fn_proto_map.get(fn_obj.proto) != null) return;

        const proto: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));
        // Collect inner FnProtos from constants first (depth-first)
        for (proto.constants) |c| {
            try self.collectFnProtos(allocator, c);
        }
        // Register this proto
        const idx: u32 = @intCast(self.fn_protos.items.len);
        try self.fn_protos.append(allocator, fn_obj.proto);
        try self.fn_proto_map.put(allocator, fn_obj.proto, idx);

        // Also register extra arity protos
        if (fn_obj.extra_arities) |extras| {
            for (extras) |extra_opaque| {
                if (self.fn_proto_map.get(extra_opaque) != null) continue;
                const extra_proto: *const FnProto = @ptrCast(@alignCast(extra_opaque));
                for (extra_proto.constants) |c| {
                    try self.collectFnProtos(allocator, c);
                }
                const eidx: u32 = @intCast(self.fn_protos.items.len);
                try self.fn_protos.append(allocator, extra_opaque);
                try self.fn_proto_map.put(allocator, extra_opaque, eidx);
            }
        }
    }

    /// Collect all FnProtos from a Chunk's constants.
    pub fn collectChunkFnProtos(self: *Serializer, allocator: std.mem.Allocator, c: *const Chunk) !void {
        for (c.constants.items) |val| {
            try self.collectFnProtos(allocator, val);
        }
    }

    /// Write the FnProto table.
    pub fn writeFnProtoTable(self: *Serializer, allocator: std.mem.Allocator) !void {
        try self.writeBytes(allocator, &encodeU32(@intCast(self.fn_protos.items.len)));
        for (self.fn_protos.items) |proto_opaque| {
            const proto: *const FnProto = @ptrCast(@alignCast(proto_opaque));
            try self.serializeFnProto(allocator, proto);
        }
    }

    /// Serialize a top-level Chunk (code + constants + debug info).
    pub fn serializeChunk(self: *Serializer, allocator: std.mem.Allocator, c: *const Chunk) !void {
        // Code
        try self.writeBytes(allocator, &encodeU32(@intCast(c.code.items.len)));
        for (c.code.items) |instr| {
            try self.buf.append(allocator, @intFromEnum(instr.op));
            try self.writeBytes(allocator, &encodeU16(instr.operand));
        }
        // Constants
        try self.writeBytes(allocator, &encodeU32(@intCast(c.constants.items.len)));
        for (c.constants.items) |val| {
            try self.serializeValue(allocator, val);
        }
        // Debug info
        try self.writeBytes(allocator, &encodeU32(@intCast(c.lines.items.len)));
        for (c.lines.items) |line| {
            try self.writeBytes(allocator, &encodeU32(line));
        }
        try self.writeBytes(allocator, &encodeU32(@intCast(c.columns.items.len)));
        for (c.columns.items) |col| {
            try self.writeBytes(allocator, &encodeU32(col));
        }
    }

    /// Serialize a complete module: header + string table + FnProto table + chunk.
    /// Uses a two-phase approach: serializes body first to populate string table,
    /// then writes header + string table + body in correct order.
    pub fn serializeModule(self: *Serializer, allocator: std.mem.Allocator, c: *const Chunk) !void {
        // Phase 1: collect all FnProtos (inner-first ordering)
        try self.collectChunkFnProtos(allocator, c);

        // Phase 2: serialize body to temp buffer (populates string table)
        const saved_buf = self.buf;
        self.buf = .empty;

        try self.writeFnProtoTable(allocator);
        try self.serializeChunk(allocator, c);

        var body_buf = self.buf;
        self.buf = saved_buf;

        // Phase 3: write header + string table + body to output
        try self.writeHeader(allocator);
        try self.writeStringTable(allocator);
        try self.writeBytes(allocator, body_buf.items);

        body_buf.deinit(allocator);
    }

    // --- Env snapshot serialization ---

    /// Helper: serialize optional string as i32 (-1 if null, string_idx otherwise).
    fn serializeOptString(self: *Serializer, allocator: std.mem.Allocator, s: ?[]const u8) !void {
        if (s) |str| {
            const idx = try self.internString(allocator, str);
            try self.writeBytes(allocator, &encodeI32(@intCast(idx)));
        } else {
            try self.writeBytes(allocator, &encodeI32(-1));
        }
    }

    /// Collect all FnProtos from all Var root values in the environment.
    pub fn collectEnvFnProtos(self: *Serializer, allocator: std.mem.Allocator, env: *const Env) !void {
        var ns_iter = env.namespaces.iterator();
        while (ns_iter.next()) |ns_entry| {
            const ns = ns_entry.value_ptr.*;
            var var_iter = ns.mappings.iterator();
            while (var_iter.next()) |var_entry| {
                const v = var_entry.value_ptr.*;
                try self.collectFnProtos(allocator, v.root);
            }
        }
    }

    /// Serialize a single Var.
    pub fn serializeVar(self: *Serializer, allocator: std.mem.Allocator, v: *const Var) !void {
        // Name
        const name_idx = try self.internString(allocator, v.sym.name);
        try self.writeBytes(allocator, &encodeU32(name_idx));

        // Flags (packed into u8)
        var flags: u8 = 0;
        if (v.dynamic) flags |= 0x01;
        if (v.macro) flags |= 0x02;
        if (v.private) flags |= 0x04;
        if (v.is_const) flags |= 0x08;
        try self.buf.append(allocator, flags);

        // Optional string fields: doc, arglists, added, file
        try self.serializeOptString(allocator, v.doc);
        try self.serializeOptString(allocator, v.arglists);
        try self.serializeOptString(allocator, v.added);
        try self.serializeOptString(allocator, v.file);

        // Source location
        try self.writeBytes(allocator, &encodeU32(v.line));
        try self.writeBytes(allocator, &encodeU32(v.column));

        // Root value
        if (v.root.tag() == .builtin_fn) {
            try self.buf.append(allocator, 1); // root_kind = builtin (keep existing)
        } else {
            try self.buf.append(allocator, 0); // root_kind = value
            try self.serializeValue(allocator, v.root);
        }

        // Meta (optional PersistentArrayMap)
        if (v.meta) |meta_map| {
            try self.buf.append(allocator, 1); // has_meta
            const meta_val = Value.initMap(meta_map);
            try self.serializeValue(allocator, meta_val);
        } else {
            try self.buf.append(allocator, 0); // no meta
        }
    }

    /// Serialize env state: all namespaces with vars, refers, and aliases.
    pub fn serializeEnvState(self: *Serializer, allocator: std.mem.Allocator, env: *const Env) !void {
        // Count namespaces
        var ns_count: u32 = 0;
        {
            var it = env.namespaces.iterator();
            while (it.next()) |_| ns_count += 1;
        }
        try self.writeBytes(allocator, &encodeU32(ns_count));

        // Serialize each namespace
        var ns_iter = env.namespaces.iterator();
        while (ns_iter.next()) |ns_entry| {
            const ns = ns_entry.value_ptr.*;

            // Namespace name
            const ns_name_idx = try self.internString(allocator, ns.name);
            try self.writeBytes(allocator, &encodeU32(ns_name_idx));

            // Mappings (own vars)
            var var_count: u32 = 0;
            {
                var it = ns.mappings.iterator();
                while (it.next()) |_| var_count += 1;
            }
            try self.writeBytes(allocator, &encodeU32(var_count));
            var var_iter = ns.mappings.iterator();
            while (var_iter.next()) |var_entry| {
                try self.serializeVar(allocator, var_entry.value_ptr.*);
            }

            // Refers (name -> source_ns)
            var refer_count: u32 = 0;
            {
                var it = ns.refers.iterator();
                while (it.next()) |_| refer_count += 1;
            }
            try self.writeBytes(allocator, &encodeU32(refer_count));
            var refer_iter = ns.refers.iterator();
            while (refer_iter.next()) |refer_entry| {
                const ref_name_idx = try self.internString(allocator, refer_entry.key_ptr.*);
                try self.writeBytes(allocator, &encodeU32(ref_name_idx));
                const source_ns_idx = try self.internString(allocator, refer_entry.value_ptr.*.ns_name);
                try self.writeBytes(allocator, &encodeU32(source_ns_idx));
            }

            // Aliases (alias_name -> target_ns_name)
            var alias_count: u32 = 0;
            {
                var it = ns.aliases.iterator();
                while (it.next()) |_| alias_count += 1;
            }
            try self.writeBytes(allocator, &encodeU32(alias_count));
            var alias_iter = ns.aliases.iterator();
            while (alias_iter.next()) |alias_entry| {
                const alias_name_idx = try self.internString(allocator, alias_entry.key_ptr.*);
                try self.writeBytes(allocator, &encodeU32(alias_name_idx));
                const target_ns_idx = try self.internString(allocator, alias_entry.value_ptr.*.name);
                try self.writeBytes(allocator, &encodeU32(target_ns_idx));
            }
        }
    }

    /// Serialize a complete env snapshot: header + string table + FnProto table + env state.
    pub fn serializeEnvSnapshot(self: *Serializer, allocator: std.mem.Allocator, env: *const Env) !void {
        // Phase 1: collect all FnProtos from var roots
        try self.collectEnvFnProtos(allocator, env);

        // Phase 2: serialize body to temp buffer (populates string table)
        const saved_buf = self.buf;
        self.buf = .empty;

        try self.writeFnProtoTable(allocator);
        try self.serializeEnvState(allocator, env);

        var body_buf = self.buf;
        self.buf = saved_buf;

        // Phase 3: write header + string table + body to output
        try self.writeHeader(allocator);
        try self.writeStringTable(allocator);
        try self.writeBytes(allocator, body_buf.items);

        body_buf.deinit(allocator);
    }

    /// Get the serialized bytes.
    pub fn getBytes(self: *const Serializer) []const u8 {
        return self.buf.items;
    }
};

/// Deserialization context.
/// Deferred var_ref fixup entry: var wasn't available yet during FnProto
/// constant deserialization. Resolved after all vars are created.
const DeferredVarRef = struct {
    constants: []Value, // mutable constants array of the FnProto/Chunk
    index: usize, // which constant slot to fix up
    ns_name: []const u8,
    var_name: []const u8,
};

pub const Deserializer = struct {
    data: []const u8,
    pos: usize = 0,
    /// Reconstructed string table.
    strings: []const []const u8 = &.{},
    /// Reconstructed FnProto pointers for fn_val resolution.
    fn_protos: []const *const anyopaque = &.{},
    /// Environment for var_ref resolution during deserialization.
    env: ?*Env = null,
    /// Deferred var_ref fixups.
    deferred_var_refs: std.ArrayListUnmanaged(DeferredVarRef) = .empty,

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
                const proto_idx = try self.readU32();
                // Extra arities
                const extra_count = try self.readU32();
                var extra_arities: ?[]const *const anyopaque = null;
                if (extra_count > 0) {
                    const extras = try allocator.alloc(*const anyopaque, extra_count);
                    for (0..extra_count) |i| {
                        const eidx = try self.readU32();
                        if (eidx >= self.fn_protos.len) return error.InvalidFnProtoIndex;
                        extras[i] = self.fn_protos[eidx];
                    }
                    extra_arities = extras;
                }
                // Defining namespace
                const ns_idx = try self.readI32();
                const defining_ns: ?[]const u8 = if (ns_idx >= 0) blk2: {
                    const idx: u32 = @intCast(ns_idx);
                    if (idx >= self.strings.len) return error.InvalidStringIndex;
                    break :blk2 self.strings[idx];
                } else null;

                if (proto_idx >= self.fn_protos.len) return error.InvalidFnProtoIndex;
                const fn_obj = try allocator.create(value_mod.Fn);
                fn_obj.* = .{
                    .proto = self.fn_protos[proto_idx],
                    .extra_arities = extra_arities,
                    .defining_ns = defining_ns,
                };
                break :blk Value.initFn(fn_obj);
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
                const ns_idx = try self.readU32();
                const name_idx = try self.readU32();
                if (ns_idx >= self.strings.len) return error.InvalidStringIndex;
                if (name_idx >= self.strings.len) return error.InvalidStringIndex;
                const ns_name = self.strings[ns_idx];
                const var_name = self.strings[name_idx];
                // Try to resolve var from env if available.
                if (self.env) |env| {
                    if (env.findNamespace(ns_name)) |ns| {
                        if (ns.resolve(var_name)) |v| {
                            break :blk Value.initVarRef(v);
                        }
                    }
                }
                // Var not yet available — record for deferred fixup.
                // Constants/index filled in by deserializeChunk after append.
                try self.deferred_var_refs.append(allocator, .{
                    .constants = &.{},
                    .index = 0,
                    .ns_name = ns_name,
                    .var_name = var_name,
                });
                break :blk Value.nil_val;
            },
            .atom => blk: {
                const inner = try self.deserializeValue(allocator);
                const a = try allocator.create(value_mod.Atom);
                a.* = .{ .value = inner };
                break :blk Value.initAtom(a);
            },
            .volatile_ref => blk: {
                const inner = try self.deserializeValue(allocator);
                const v = try allocator.create(value_mod.Volatile);
                v.* = .{ .value = inner };
                break :blk Value.initVolatile(v);
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
            const deferred_before = self.deferred_var_refs.items.len;
            constants[i] = try self.deserializeValue(allocator);
            // Wire up deferred var_ref entry with this constants array and index.
            if (self.deferred_var_refs.items.len > deferred_before) {
                self.deferred_var_refs.items[self.deferred_var_refs.items.len - 1].constants = constants;
                self.deferred_var_refs.items[self.deferred_var_refs.items.len - 1].index = i;
            }
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

    /// Read the FnProto table and populate fn_protos for fn_val resolution.
    pub fn readFnProtoTable(self: *Deserializer, allocator: std.mem.Allocator) !void {
        const count = try self.readU32();
        const protos = try allocator.alloc(*const anyopaque, count);
        // Set early so fn_vals in constants can resolve during deserialization.
        // Inner-first ordering guarantees proto[j] is populated before proto[i] (j < i) references it.
        self.fn_protos = protos;
        for (0..count) |i| {
            const proto = try self.deserializeFnProto(allocator);
            const proto_ptr = try allocator.create(FnProto);
            proto_ptr.* = proto;
            protos[i] = proto_ptr;
        }
    }

    /// Deserialize a top-level Chunk (code + constants + debug info).
    pub fn deserializeChunk(self: *Deserializer, allocator: std.mem.Allocator) !Chunk {
        var c = Chunk.init(allocator);
        // Code
        const code_len = try self.readU32();
        for (0..code_len) |_| {
            const op: OpCode = @enumFromInt(try self.readU8());
            const operand = try self.readU16();
            try c.code.append(allocator, .{ .op = op, .operand = operand });
        }
        // Constants
        const const_len = try self.readU32();
        for (0..const_len) |_| {
            const val = try self.deserializeValue(allocator);
            try c.constants.append(allocator, val);
        }
        // Debug info
        const lines_len = try self.readU32();
        for (0..lines_len) |_| {
            try c.lines.append(allocator, try self.readU32());
        }
        const cols_len = try self.readU32();
        for (0..cols_len) |_| {
            try c.columns.append(allocator, try self.readU32());
        }
        return c;
    }

    /// Deserialize a complete module: header + string table + FnProto table + chunk.
    pub fn deserializeModule(self: *Deserializer, allocator: std.mem.Allocator) !Chunk {
        try self.readHeader();
        try self.readStringTable(allocator);
        try self.readFnProtoTable(allocator);
        return self.deserializeChunk(allocator);
    }

    // --- Env snapshot restoration ---

    /// Helper: read optional string (i32 index, -1 = null).
    fn readOptString(self: *Deserializer) !?[]const u8 {
        const idx = try self.readI32();
        if (idx < 0) return null;
        const i: u32 = @intCast(idx);
        if (i >= self.strings.len) return error.InvalidStringIndex;
        return self.strings[i];
    }

    /// Restore a single Var into the given namespace.
    /// If root_kind is builtin (1), the existing root is preserved.
    pub fn restoreVar(self: *Deserializer, allocator: std.mem.Allocator, ns: *Namespace) !void {
        // Name
        const name_idx = try self.readU32();
        if (name_idx >= self.strings.len) return error.InvalidStringIndex;
        const var_name = self.strings[name_idx];

        // Flags
        const flags = try self.readU8();

        // Optional string fields
        const doc = try self.readOptString();
        const arglists = try self.readOptString();
        const added = try self.readOptString();
        const file = try self.readOptString();

        // Source location
        const line = try self.readU32();
        const column = try self.readU32();

        // Root value
        const root_kind = try self.readU8();
        var root_value: ?Value = null;
        if (root_kind == 0) {
            root_value = try self.deserializeValue(allocator);
        }

        // Meta
        const has_meta = try self.readU8();
        var meta_map: ?*value_mod.PersistentArrayMap = null;
        if (has_meta != 0) {
            const meta_val = try self.deserializeValue(allocator);
            if (meta_val.tag() == .map) {
                meta_map = @constCast(meta_val.asMap());
            }
        }

        // Intern var and apply fields
        const v = try ns.intern(var_name);
        v.dynamic = (flags & 0x01) != 0;
        v.macro = (flags & 0x02) != 0;
        v.private = (flags & 0x04) != 0;
        v.is_const = (flags & 0x08) != 0;
        v.doc = doc;
        v.arglists = arglists;
        v.added = added;
        v.file = file;
        v.line = line;
        v.column = column;
        if (root_value) |rv| {
            v.bindRoot(rv);
        }
        // Only set meta if snapshot has it (don't clear existing meta from registerBuiltins)
        if (meta_map) |m| {
            v.meta = m;
        }
    }

    /// Restore env state from snapshot. Expects registerBuiltins already called.
    /// Creates/updates namespaces and vars, then connects refers and aliases.
    pub fn restoreEnvState(self: *Deserializer, allocator: std.mem.Allocator, env: *Env) !void {
        // Make env available for var_ref resolution during deserialization.
        self.env = env;
        const ns_count = try self.readU32();

        // Temporary storage for deferred refer/alias setup
        const ReferEntry = struct { ns_name: []const u8, refer_name: []const u8, source_ns: []const u8 };
        const AliasEntry = struct { ns_name: []const u8, alias_name: []const u8, target_ns: []const u8 };
        var refers = std.ArrayListUnmanaged(ReferEntry).empty;
        var aliases = std.ArrayListUnmanaged(AliasEntry).empty;

        // Pass 1: create namespaces and vars
        for (0..ns_count) |_| {
            const ns_name_idx = try self.readU32();
            if (ns_name_idx >= self.strings.len) return error.InvalidStringIndex;
            const ns_name = self.strings[ns_name_idx];
            const ns = try env.findOrCreateNamespace(ns_name);

            // Vars
            const var_count = try self.readU32();
            for (0..var_count) |_| {
                try self.restoreVar(allocator, ns);
            }

            // Refers (defer to pass 2)
            const refer_count = try self.readU32();
            for (0..refer_count) |_| {
                const ref_name_idx = try self.readU32();
                const src_ns_idx = try self.readU32();
                if (ref_name_idx >= self.strings.len) return error.InvalidStringIndex;
                if (src_ns_idx >= self.strings.len) return error.InvalidStringIndex;
                try refers.append(allocator, .{
                    .ns_name = ns_name,
                    .refer_name = self.strings[ref_name_idx],
                    .source_ns = self.strings[src_ns_idx],
                });
            }

            // Aliases (defer to pass 2)
            const alias_count = try self.readU32();
            for (0..alias_count) |_| {
                const alias_name_idx = try self.readU32();
                const target_ns_idx = try self.readU32();
                if (alias_name_idx >= self.strings.len) return error.InvalidStringIndex;
                if (target_ns_idx >= self.strings.len) return error.InvalidStringIndex;
                try aliases.append(allocator, .{
                    .ns_name = ns_name,
                    .alias_name = self.strings[alias_name_idx],
                    .target_ns = self.strings[target_ns_idx],
                });
            }
        }

        // Pass 2: connect refers
        for (refers.items) |ref| {
            const ns = env.findNamespace(ref.ns_name) orelse continue;
            const source_ns = env.findNamespace(ref.source_ns) orelse continue;
            if (source_ns.mappings.get(ref.refer_name)) |source_var| {
                try ns.refer(ref.refer_name, source_var);
            }
        }

        // Pass 3: connect aliases
        for (aliases.items) |al| {
            const ns = env.findNamespace(al.ns_name) orelse continue;
            const target = env.findNamespace(al.target_ns) orelse continue;
            try ns.setAlias(al.alias_name, target);
        }
    }

    /// Restore a complete env snapshot: header + string table + FnProto table + env state.
    /// Expects registerBuiltins(env) already called.
    pub fn restoreEnvSnapshot(self: *Deserializer, allocator: std.mem.Allocator, env: *Env) !void {
        try self.readHeader();
        try self.readStringTable(allocator);
        try self.readFnProtoTable(allocator);
        try self.restoreEnvState(allocator, env);
        // Resolve deferred var_refs now that all vars exist.
        try self.resolveDeferredVarRefs(env);
    }

    /// Resolve var_refs that were deferred during FnProto deserialization.
    /// Called after restoreEnvState when all namespaces and vars are available.
    fn resolveDeferredVarRefs(self: *Deserializer, env: *Env) !void {
        for (self.deferred_var_refs.items) |entry| {
            const ns = env.findNamespace(entry.ns_name) orelse return error.InvalidVarRef;
            const v = ns.resolve(entry.var_name) orelse return error.InvalidVarRef;
            entry.constants[entry.index] = Value.initVarRef(v);
        }
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

test "serialize/deserialize fn_val with FnProto resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a FnProto
    const fn_code = [_]Instruction{
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{Value.initInteger(42)};
    const proto = try alloc.create(FnProto);
    proto.* = .{
        .name = "test-fn",
        .arity = 0,
        .variadic = false,
        .local_count = 0,
        .code = &fn_code,
        .constants = &fn_constants,
    };

    // Create a Fn referencing the proto
    const fn_obj = try alloc.create(value_mod.Fn);
    fn_obj.* = .{
        .proto = proto,
        .defining_ns = "user",
    };
    const fn_val = Value.initFn(fn_obj);

    // Create a Chunk containing the fn_val as a constant
    var chunk = Chunk.init(alloc);
    const idx = try chunk.addConstant(fn_val);
    chunk.current_line = 1;
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    // Serialize
    var ser: Serializer = .{};
    try ser.serializeModule(alloc, &chunk);

    // Deserialize
    var de: Deserializer = .{ .data = ser.getBytes() };
    var result = try de.deserializeModule(alloc);
    _ = &result;

    // Verify chunk
    try std.testing.expectEqual(@as(usize, 2), result.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, result.code.items[0].op);
    try std.testing.expectEqual(OpCode.ret, result.code.items[1].op);

    // Verify fn_val constant was reconstructed
    try std.testing.expectEqual(@as(usize, 1), result.constants.items.len);
    const result_fn_val = result.constants.items[0];
    try std.testing.expect(result_fn_val.tag() == .fn_val);

    const result_fn = result_fn_val.asFn();
    const result_proto: *const FnProto = @ptrCast(@alignCast(result_fn.proto));
    try std.testing.expectEqualStrings("test-fn", result_proto.name.?);
    try std.testing.expectEqual(@as(u8, 0), result_proto.arity);
    try std.testing.expectEqual(@as(usize, 2), result_proto.code.len);
    try std.testing.expectEqual(@as(usize, 1), result_proto.constants.len);
    try std.testing.expectEqual(Value.initInteger(42), result_proto.constants[0]);
    try std.testing.expectEqualStrings("user", result_fn.defining_ns.?);
}

test "serialize/deserialize multi-arity fn_val" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Primary proto (arity 1)
    const code1 = [_]Instruction{
        .{ .op = .local_load, .operand = 0 },
        .{ .op = .ret },
    };
    const constants1 = [_]Value{};
    const proto1 = try alloc.create(FnProto);
    proto1.* = .{
        .name = "multi",
        .arity = 1,
        .variadic = false,
        .local_count = 1,
        .code = &code1,
        .constants = &constants1,
    };

    // Extra arity proto (arity 2)
    const code2 = [_]Instruction{
        .{ .op = .local_load, .operand = 0 },
        .{ .op = .local_load, .operand = 1 },
        .{ .op = .add },
        .{ .op = .ret },
    };
    const constants2 = [_]Value{};
    const proto2 = try alloc.create(FnProto);
    proto2.* = .{
        .name = "multi",
        .arity = 2,
        .variadic = false,
        .local_count = 2,
        .code = &code2,
        .constants = &constants2,
    };

    // Create multi-arity Fn
    const extra_arities = try alloc.alloc(*const anyopaque, 1);
    extra_arities[0] = proto2;
    const fn_obj = try alloc.create(value_mod.Fn);
    fn_obj.* = .{
        .proto = proto1,
        .extra_arities = extra_arities,
        .defining_ns = "clojure.core",
    };

    // Create chunk
    var chunk = Chunk.init(alloc);
    _ = try chunk.addConstant(Value.initFn(fn_obj));
    try chunk.emit(.const_load, 0);
    try chunk.emitOp(.ret);

    // Serialize + Deserialize
    var ser: Serializer = .{};
    try ser.serializeModule(alloc, &chunk);
    var de: Deserializer = .{ .data = ser.getBytes() };
    var result = try de.deserializeModule(alloc);
    _ = &result;

    // Verify fn_val
    const result_fn = result.constants.items[0].asFn();
    const result_proto: *const FnProto = @ptrCast(@alignCast(result_fn.proto));
    try std.testing.expectEqualStrings("multi", result_proto.name.?);
    try std.testing.expectEqual(@as(u8, 1), result_proto.arity);

    // Verify extra arities
    try std.testing.expect(result_fn.extra_arities != null);
    try std.testing.expectEqual(@as(usize, 1), result_fn.extra_arities.?.len);
    const extra_proto: *const FnProto = @ptrCast(@alignCast(result_fn.extra_arities.?[0]));
    try std.testing.expectEqualStrings("multi", extra_proto.name.?);
    try std.testing.expectEqual(@as(u8, 2), extra_proto.arity);
    try std.testing.expectEqual(@as(usize, 4), extra_proto.code.len);
    try std.testing.expectEqualStrings("clojure.core", result_fn.defining_ns.?);
}

test "serializeModule/deserializeModule full round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Inner function proto: (fn [x] (+ x 1))
    const inner_code = [_]Instruction{
        .{ .op = .local_load, .operand = 0 },
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .add },
        .{ .op = .ret },
    };
    const inner_constants = [_]Value{Value.initInteger(1)};
    const inner_proto = try alloc.create(FnProto);
    inner_proto.* = .{
        .name = "inc",
        .arity = 1,
        .variadic = false,
        .local_count = 1,
        .code = &inner_code,
        .constants = &inner_constants,
    };
    const inner_fn_obj = try alloc.create(value_mod.Fn);
    inner_fn_obj.* = .{ .proto = inner_proto };
    const inner_fn_val = Value.initFn(inner_fn_obj);

    // Outer function proto that references inner fn as a constant
    const outer_code = [_]Instruction{
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .ret },
    };
    const outer_constants = [_]Value{inner_fn_val};
    const outer_proto = try alloc.create(FnProto);
    outer_proto.* = .{
        .name = "make-inc",
        .arity = 0,
        .variadic = false,
        .local_count = 0,
        .code = &outer_code,
        .constants = &outer_constants,
    };
    const outer_fn_obj = try alloc.create(value_mod.Fn);
    outer_fn_obj.* = .{ .proto = outer_proto, .defining_ns = "user" };
    const outer_fn_val = Value.initFn(outer_fn_obj);

    // Top-level chunk references the outer function
    var chunk = Chunk.init(alloc);
    chunk.current_line = 10;
    chunk.current_column = 0;
    _ = try chunk.addConstant(outer_fn_val);
    try chunk.emit(.const_load, 0);
    _ = try chunk.addConstant(Value.initInteger(99));
    try chunk.emit(.const_load, 1);
    try chunk.emitOp(.ret);

    // Serialize
    var ser: Serializer = .{};
    try ser.serializeModule(alloc, &chunk);

    // Verify FnProto collection (inner-first)
    try std.testing.expectEqual(@as(usize, 2), ser.fn_protos.items.len);

    // Deserialize
    var de: Deserializer = .{ .data = ser.getBytes() };
    var result = try de.deserializeModule(alloc);
    _ = &result;

    // Verify chunk structure
    try std.testing.expectEqual(@as(usize, 3), result.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, result.code.items[0].op);
    try std.testing.expectEqual(OpCode.const_load, result.code.items[1].op);
    try std.testing.expectEqual(OpCode.ret, result.code.items[2].op);

    // Verify constants
    try std.testing.expectEqual(@as(usize, 2), result.constants.items.len);
    try std.testing.expectEqual(Value.initInteger(99), result.constants.items[1]);

    // Verify outer fn → inner fn nesting
    const r_outer_fn = result.constants.items[0].asFn();
    const r_outer_proto: *const FnProto = @ptrCast(@alignCast(r_outer_fn.proto));
    try std.testing.expectEqualStrings("make-inc", r_outer_proto.name.?);
    try std.testing.expectEqualStrings("user", r_outer_fn.defining_ns.?);

    // Outer proto's constant[0] should be fn_val pointing to inner proto
    try std.testing.expectEqual(@as(usize, 1), r_outer_proto.constants.len);
    const r_inner_fn_val = r_outer_proto.constants[0];
    try std.testing.expect(r_inner_fn_val.tag() == .fn_val);
    const r_inner_proto: *const FnProto = @ptrCast(@alignCast(r_inner_fn_val.asFn().proto));
    try std.testing.expectEqualStrings("inc", r_inner_proto.name.?);
    try std.testing.expectEqual(@as(u8, 1), r_inner_proto.arity);
    try std.testing.expectEqual(Value.initInteger(1), r_inner_proto.constants[0]);

    // Verify debug info round-trip
    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqual(@as(u32, 10), result.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 3), result.columns.items.len);
    try std.testing.expectEqual(@as(u32, 0), result.columns.items[0]);
}

test "serializeModule with no fn_vals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simple chunk with only scalar constants
    var chunk = Chunk.init(alloc);
    _ = try chunk.addConstant(Value.initInteger(1));
    _ = try chunk.addConstant(Value.initInteger(2));
    try chunk.emit(.const_load, 0);
    try chunk.emit(.const_load, 1);
    try chunk.emitOp(.add);
    try chunk.emitOp(.ret);

    var ser: Serializer = .{};
    try ser.serializeModule(alloc, &chunk);

    // No FnProtos should be collected
    try std.testing.expectEqual(@as(usize, 0), ser.fn_protos.items.len);

    var de: Deserializer = .{ .data = ser.getBytes() };
    var result = try de.deserializeModule(alloc);
    _ = &result;

    try std.testing.expectEqual(@as(usize, 4), result.code.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.constants.items.len);
    try std.testing.expectEqual(Value.initInteger(1), result.constants.items[0]);
    try std.testing.expectEqual(Value.initInteger(2), result.constants.items[1]);
}

test "env snapshot round-trip with scalar vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create source env
    var env1 = Env.init(alloc);

    const ns1 = try env1.findOrCreateNamespace("test.core");
    const v1 = try ns1.intern("x");
    v1.bindRoot(Value.initInteger(42));
    v1.doc = "The answer";

    const v2 = try ns1.intern("greeting");
    v2.bindRoot(Value.initString(alloc, "hello"));
    v2.private = true;

    const v3 = try ns1.intern("flag");
    v3.bindRoot(Value.true_val);
    v3.dynamic = true;

    const ns2 = try env1.findOrCreateNamespace("test.user");
    const v4 = try ns2.intern("y");
    v4.bindRoot(Value.initFloat(3.14));

    // Set up a refer: test.user refers "x" from test.core
    try ns2.refer("x", v1);

    // Set up an alias: test.user aliases "tc" -> test.core
    try ns2.setAlias("tc", ns1);

    // Serialize
    var ser: Serializer = .{};
    try ser.serializeEnvSnapshot(alloc, &env1);

    // Create target env and restore
    var env2 = Env.init(alloc);
    var de: Deserializer = .{ .data = ser.getBytes() };
    try de.restoreEnvSnapshot(alloc, &env2);

    // Verify namespaces exist
    const r_ns1 = env2.findNamespace("test.core");
    try std.testing.expect(r_ns1 != null);
    const r_ns2 = env2.findNamespace("test.user");
    try std.testing.expect(r_ns2 != null);

    // Verify vars in test.core
    const r_v1 = r_ns1.?.mappings.get("x");
    try std.testing.expect(r_v1 != null);
    try std.testing.expectEqual(Value.initInteger(42), r_v1.?.root);
    try std.testing.expectEqualStrings("The answer", r_v1.?.doc.?);

    const r_v2 = r_ns1.?.mappings.get("greeting");
    try std.testing.expect(r_v2 != null);
    try std.testing.expectEqualStrings("hello", r_v2.?.root.asString());
    try std.testing.expect(r_v2.?.private);

    const r_v3 = r_ns1.?.mappings.get("flag");
    try std.testing.expect(r_v3 != null);
    try std.testing.expectEqual(Value.true_val, r_v3.?.root);
    try std.testing.expect(r_v3.?.dynamic);

    // Verify var in test.user
    const r_v4 = r_ns2.?.mappings.get("y");
    try std.testing.expect(r_v4 != null);
    try std.testing.expectEqual(@as(f64, 3.14), r_v4.?.root.asFloat());

    // Verify refer: test.user -> x from test.core
    const referred_x = r_ns2.?.refers.get("x");
    try std.testing.expect(referred_x != null);
    try std.testing.expectEqual(Value.initInteger(42), referred_x.?.root);

    // Verify alias: test.user -> "tc" -> test.core
    const aliased_ns = r_ns2.?.getAlias("tc");
    try std.testing.expect(aliased_ns != null);
    try std.testing.expectEqualStrings("test.core", aliased_ns.?.name);
}

fn testBuiltinA(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return Value.nil_val;
}

fn testBuiltinB(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return Value.true_val;
}

test "env snapshot preserves builtin roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create env with a builtin var
    var env1 = Env.init(alloc);
    const ns = try env1.findOrCreateNamespace("test.ns");
    const v = try ns.intern("my-builtin");
    v.bindRoot(Value.initBuiltinFn(&testBuiltinA));
    v.doc = "A builtin function";
    v.arglists = "([x])";

    // Also add a non-builtin var
    const v2 = try ns.intern("my-val");
    v2.bindRoot(Value.initInteger(100));

    // Serialize
    var ser: Serializer = .{};
    try ser.serializeEnvSnapshot(alloc, &env1);

    // Restore into env that has "my-builtin" registered with DIFFERENT fn ptr
    var env2 = Env.init(alloc);
    const ns2 = try env2.findOrCreateNamespace("test.ns");
    const existing = try ns2.intern("my-builtin");
    existing.bindRoot(Value.initBuiltinFn(&testBuiltinB));

    var de: Deserializer = .{ .data = ser.getBytes() };
    try de.restoreEnvSnapshot(alloc, &env2);

    // Builtin root should be PRESERVED (not overwritten with snapshot's)
    const r_ns = env2.findNamespace("test.ns").?;
    const r_v = r_ns.mappings.get("my-builtin").?;
    try std.testing.expectEqual(Value.initBuiltinFn(&testBuiltinB), r_v.root);
    // But metadata should be updated from snapshot
    try std.testing.expectEqualStrings("A builtin function", r_v.doc.?);
    try std.testing.expectEqualStrings("([x])", r_v.arglists.?);

    // Non-builtin var should have its value restored
    const r_v2 = r_ns.mappings.get("my-val").?;
    try std.testing.expectEqual(Value.initInteger(100), r_v2.root);
}

test "env snapshot with fn_val root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a FnProto + Fn
    const fn_code = [_]Instruction{
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{Value.initInteger(7)};
    const proto = try alloc.create(FnProto);
    proto.* = .{
        .name = "my-fn",
        .arity = 0,
        .variadic = false,
        .local_count = 0,
        .code = &fn_code,
        .constants = &fn_constants,
    };
    const fn_obj = try alloc.create(value_mod.Fn);
    fn_obj.* = .{ .proto = proto, .defining_ns = "test.core" };

    // Create env with fn_val var
    var env1 = Env.init(alloc);
    const ns = try env1.findOrCreateNamespace("test.core");
    const v = try ns.intern("my-fn");
    v.bindRoot(Value.initFn(fn_obj));

    // Serialize
    var ser: Serializer = .{};
    try ser.serializeEnvSnapshot(alloc, &env1);
    try std.testing.expectEqual(@as(usize, 1), ser.fn_protos.items.len);

    // Restore
    var env2 = Env.init(alloc);
    var de: Deserializer = .{ .data = ser.getBytes() };
    try de.restoreEnvSnapshot(alloc, &env2);

    // Verify fn_val was restored
    const r_ns = env2.findNamespace("test.core").?;
    const r_v = r_ns.mappings.get("my-fn").?;
    try std.testing.expect(r_v.root.tag() == .fn_val);

    const r_fn = r_v.root.asFn();
    const r_proto: *const FnProto = @ptrCast(@alignCast(r_fn.proto));
    try std.testing.expectEqualStrings("my-fn", r_proto.name.?);
    try std.testing.expectEqual(@as(u8, 0), r_proto.arity);
    try std.testing.expectEqual(Value.initInteger(7), r_proto.constants[0]);
    try std.testing.expectEqualStrings("test.core", r_fn.defining_ns.?);
}

test "collectFnProtos rejects treewalk closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a fn_val with kind=treewalk (proto points to non-FnProto data)
    const fake_closure = try alloc.create([4]u64);
    fake_closure.* = .{ 0, 0, 0, 0 };
    const fn_obj = try alloc.create(value_mod.Fn);
    fn_obj.* = .{
        .proto = @ptrCast(fake_closure),
        .kind = .treewalk,
    };

    var ser: Serializer = .{};
    const result = ser.collectFnProtos(alloc, Value.initFn(fn_obj));
    try std.testing.expectError(error.TreeWalkClosureNotSerializable, result);
}

test "serializeValue rejects treewalk fn_val" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a fn_val with kind=treewalk
    const fake_closure = try alloc.create([4]u64);
    fake_closure.* = .{ 0, 0, 0, 0 };
    const fn_obj = try alloc.create(value_mod.Fn);
    fn_obj.* = .{
        .proto = @ptrCast(fake_closure),
        .kind = .treewalk,
    };

    var ser: Serializer = .{};
    const result = ser.serializeValue(alloc, Value.initFn(fn_obj));
    try std.testing.expectError(error.TreeWalkClosureNotSerializable, result);
}
