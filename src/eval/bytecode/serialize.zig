// SPDX-License-Identifier: EPL-2.0
//! Bytecode serializer + deserializer — §9.16 row 14.11(a), D-100(a).
//!
//! Wire format v2 (extends cycle-1's instruction-only v1 per
//! ADR-0034 §format-version policy "decoder-only permanent
//! compatibility"):
//!
//!   [0..4]    magic  = "CLJW"
//!   [4..6]    version (u16 LE, currently 2)
//!   [6..10]   instr_count (u32 LE)
//!   [10..]    instructions = instr_count * (opcode:u8 + operand:u16 LE)
//!   [...]     constants_count (u32 LE)
//!             for each constant: ValueTag:u8 + per-tag body
//!   [...]     call_sites_count (u32 LE)
//!             for each entry: method_name_len:u32 + bytes + arg_count:u16
//!   [...]     libspecs_count (u32 LE)
//!             for each entry: ns_name_len:u32 + bytes
//!                           + has_alias:u8 + (alias_len:u32 + bytes)?
//!                           + refers_count:u32
//!                             + each: refer_len:u32 + bytes
//!
//! Per-Value tag-byte approach (NOT raw 8-byte u64 bits) so the
//! `cljw-formats/<version>.edn` archive (ADR-0034 D11) records a
//! decoder-stable enum the decoder permanence policy can pin —
//! independent of F-004 NaN-box slot evolution.
//!
//! v0.1.0 tag set is the realistic compiler-produced constant
//! universe: immediates (nil / true / false / integer / float /
//! char) + interned literals (string / symbol / keyword / var_ref
//! / regex) + quoted collections (list / vector / array_map /
//! hash_set). Out of scope (raise explicit `UnsupportedValueTag`):
//! fn_val / atom / multi_fn / big_int / wasm_* / transient_* / any
//! runtime-only Value (per `no_op_stub_forbidden.md` — no silent
//! nil-substitution like v0's `else => write nil`).

const std = @import("std");
const opcode_mod = @import("../backend/vm/opcode.zig");
const Instruction = opcode_mod.Instruction;
const Opcode = opcode_mod.Opcode;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const CallSiteEntry = opcode_mod.CallSiteEntry;
const LibspecEntry = opcode_mod.LibspecEntry;
const value_mod = @import("../../runtime/value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const string_collection = @import("../../runtime/collection/string.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const list_mod = @import("../../runtime/collection/list.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const map_mod = @import("../../runtime/collection/map.zig");
const set_mod = @import("../../runtime/collection/set.zig");
const tree_walk = @import("../backend/tree_walk.zig");
const Function = tree_walk.Function;

pub const MAGIC: [4]u8 = .{ 'C', 'L', 'J', 'W' };
pub const VERSION: u16 = 2;

pub const SerializeError = error{
    OutOfMemory,
    WriteFailed,
    UnsupportedValueTag,
    HashMapNotSerializable,
    /// A `fn_val` constant carries `closure_bindings != null` — a runtime
    /// closure, which is never a compile-time constant (ADR-0034 am2 A2-D2).
    /// Raised as an invariant guard, not a feature gate.
    ClosureNotSerializable,
};

pub const DeserializeError = error{
    BytecodeTruncated,
    BadMagic,
    UnsupportedVersion,
    UnknownOpcode,
    UnknownValueTag,
    OutOfMemory,
};

/// Wire-format Value classifier. **Stable enum** — the
/// `cljw-formats/<version>.edn` archive records this byte for each
/// constant. Adding a tag is a version bump; removing one is
/// forbidden by the decoder-only-permanent policy.
pub const ValueTag = enum(u8) {
    nil = 0x00,
    true_val = 0x01,
    false_val = 0x02,
    integer = 0x03,
    float = 0x04,
    char = 0x05,
    string = 0x06,
    symbol = 0x07,
    keyword = 0x08,
    list = 0x09,
    vector = 0x0A,
    array_map = 0x0B,
    hash_set = 0x0C,
    var_ref = 0x0D,
    regex = 0x0E,
    /// Function constant (ADR-0034 am2). Body is its method bytecode
    /// chunk(s), serialized recursively via `serializeChunk`.
    fn_val = 0x0F,
};

// --- Writer helpers (length-prefixed UTF-8) ---

fn writeU8(w: *std.Io.Writer, n: u8) !void {
    try w.writeByte(n);
}
fn writeU16(w: *std.Io.Writer, n: u16) !void {
    try w.writeInt(u16, n, .little);
}
fn writeU32(w: *std.Io.Writer, n: u32) !void {
    try w.writeInt(u32, n, .little);
}
fn writeI64(w: *std.Io.Writer, n: i64) !void {
    try w.writeInt(i64, n, .little);
}
fn writeLenPrefixed(w: *std.Io.Writer, bytes: []const u8) !void {
    try writeU32(w, @intCast(bytes.len));
    try w.writeAll(bytes);
}

// --- Reader (byte-slice cursor) ---

const ByteReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *ByteReader, n: usize) !void {
        if (self.pos + n > self.bytes.len) return DeserializeError.BytecodeTruncated;
    }
    fn readU8(self: *ByteReader) !u8 {
        try self.need(1);
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }
    fn readU16(self: *ByteReader) !u16 {
        try self.need(2);
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *ByteReader) !u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readI64(self: *ByteReader) !i64 {
        try self.need(8);
        const v = std.mem.readInt(i64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn readLenPrefixed(self: *ByteReader) ![]const u8 {
        const len = try self.readU32();
        try self.need(len);
        const slice = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }
};

// --- Value serialize / deserialize (recursive) ---

fn writeValue(allocator: std.mem.Allocator, w: *std.Io.Writer, v: Value) SerializeError!void {
    switch (v.tag()) {
        .nil => try writeU8(w, @intFromEnum(ValueTag.nil)),
        .boolean => {
            const t: ValueTag = if (v.asBoolean()) .true_val else .false_val;
            try writeU8(w, @intFromEnum(t));
        },
        .integer => {
            try writeU8(w, @intFromEnum(ValueTag.integer));
            try writeI64(w, v.asInteger());
        },
        .float => {
            try writeU8(w, @intFromEnum(ValueTag.float));
            const bits: u64 = @bitCast(v.asFloat());
            try w.writeInt(u64, bits, .little);
        },
        .char => {
            try writeU8(w, @intFromEnum(ValueTag.char));
            try writeU32(w, @as(u32, v.asChar()));
        },
        .string => {
            try writeU8(w, @intFromEnum(ValueTag.string));
            try writeLenPrefixed(w, string_collection.asString(v));
        },
        .symbol => {
            const sym = symbol_mod.asSymbol(v);
            try writeU8(w, @intFromEnum(ValueTag.symbol));
            try writeLenPrefixed(w, sym.ns orelse "");
            try writeLenPrefixed(w, sym.name);
        },
        .keyword => {
            const kw = keyword_mod.asKeyword(v);
            try writeU8(w, @intFromEnum(ValueTag.keyword));
            try writeLenPrefixed(w, kw.ns orelse "");
            try writeLenPrefixed(w, kw.name);
        },
        .list => {
            try writeU8(w, @intFromEnum(ValueTag.list));
            const n = list_mod.countOf(v);
            try writeU32(w, n);
            var cur = v;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try writeValue(allocator, w, list_mod.first(cur));
                cur = list_mod.rest(cur);
            }
        },
        .vector => {
            try writeU8(w, @intFromEnum(ValueTag.vector));
            const n = vector_mod.count(v);
            try writeU32(w, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) try writeValue(allocator, w, vector_mod.nth(v, i));
        },
        .array_map => {
            try writeU8(w, @intFromEnum(ValueTag.array_map));
            const am = v.decodePtr(*const map_mod.ArrayMap);
            try writeU32(w, am.count);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                try writeValue(allocator, w, am.entries[2 * i]);
                try writeValue(allocator, w, am.entries[2 * i + 1]);
            }
        },
        .hash_map => {
            // HAMT body iteration (D-045) not landed at v0.1.0;
            // raise explicit error so the user sees a concrete diagnostic
            // rather than partial archive.
            return SerializeError.HashMapNotSerializable;
        },
        .hash_set => {
            try writeU8(w, @intFromEnum(ValueTag.hash_set));
            const s = v.decodePtr(*const set_mod.PersistentHashSet);
            if (s.map.tag() != .array_map) return SerializeError.HashMapNotSerializable;
            const am = s.map.decodePtr(*const map_mod.ArrayMap);
            try writeU32(w, am.count);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) try writeValue(allocator, w, am.entries[2 * i]);
        },
        .var_ref => {
            try writeU8(w, @intFromEnum(ValueTag.var_ref));
            const var_ptr = v.decodePtr(*const @import("../../runtime/env.zig").Var);
            try writeLenPrefixed(w, var_ptr.ns.name);
            try writeLenPrefixed(w, var_ptr.name);
        },
        .fn_val => {
            // ADR-0034 am2: serialize a function constant by its CONTENTS.
            // A `fn_val` that appears as a compile-time constant always has
            // `closure_bindings == null`; a runtime closure is never a
            // constant, so non-null here is a corrupt-invariant guard.
            const f = v.decodePtr(*const Function);
            if (f.closure_bindings != null) return SerializeError.ClosureNotSerializable;
            try writeU8(w, @intFromEnum(ValueTag.fn_val));
            try writeU16(w, f.slot_base);
            try writeU32(w, @intCast(f.methods.len));
            for (f.methods) |m| try writeFnMethod(allocator, w, m);
            if (f.variadic) |variadic| {
                try writeU8(w, 1);
                try writeFnMethod(allocator, w, variadic);
            } else {
                try writeU8(w, 0);
            }
        },
        else => return SerializeError.UnsupportedValueTag,
    }
}

/// Serialize one function method: `arity` + `has_rest` + a length-prefixed
/// recursive `serializeChunk` of the method body (the body IS a
/// BytecodeChunk). `has_bytecode == 0` is allowed for forward-compat with a
/// future lazy-JIT method, though the v0.1.0 compiler always emits bytecode.
fn writeFnMethod(allocator: std.mem.Allocator, w: *std.Io.Writer, m: tree_walk.FunctionMethod) SerializeError!void {
    try writeU16(w, m.arity);
    try writeU8(w, @intFromBool(m.has_rest));
    if (m.bytecode) |chunk| {
        try writeU8(w, 1);
        const chunk_bytes = try serializeChunk(allocator, chunk.*);
        defer allocator.free(chunk_bytes);
        try writeLenPrefixed(w, chunk_bytes);
    } else {
        try writeU8(w, 0);
    }
}

fn readValue(allocator: std.mem.Allocator, r: *ByteReader, rt: *Runtime, env: *@import("../../runtime/env.zig").Env) DeserializeError!Value {
    const tag_byte = try r.readU8();
    const tag = std.enums.fromInt(ValueTag, tag_byte) orelse return DeserializeError.UnknownValueTag;
    switch (tag) {
        .nil => return .nil_val,
        .true_val => return .true_val,
        .false_val => return .false_val,
        .integer => return Value.initInteger(try r.readI64()),
        .float => {
            try r.need(8);
            const bits = std.mem.readInt(u64, r.bytes[r.pos..][0..8], .little);
            r.pos += 8;
            return Value.initFloat(@bitCast(bits));
        },
        .char => return Value.initChar(@intCast(try r.readU32())),
        .string => {
            const bytes = try r.readLenPrefixed();
            return string_collection.alloc(rt, bytes) catch return DeserializeError.OutOfMemory;
        },
        .symbol => {
            const ns_bytes = try r.readLenPrefixed();
            const name_bytes = try r.readLenPrefixed();
            const ns: ?[]const u8 = if (ns_bytes.len == 0) null else ns_bytes;
            return symbol_mod.intern(rt, ns, name_bytes) catch return DeserializeError.OutOfMemory;
        },
        .keyword => {
            const ns_bytes = try r.readLenPrefixed();
            const name_bytes = try r.readLenPrefixed();
            const ns: ?[]const u8 = if (ns_bytes.len == 0) null else ns_bytes;
            return keyword_mod.intern(rt, ns, name_bytes) catch return DeserializeError.OutOfMemory;
        },
        .list => {
            const n = try r.readU32();
            // Read forward into a stack-allocated buffer, then cons-fold
            // back to preserve the head-first source order. Caps at a
            // bounded stack alloc; very-large quoted lists are rare in
            // the constant pool — long sequences come through `list`
            // primitive at runtime.
            const buf = std.heap.page_allocator.alloc(Value, n) catch return DeserializeError.OutOfMemory;
            defer std.heap.page_allocator.free(buf);
            var i: u32 = 0;
            while (i < n) : (i += 1) buf[i] = try readValue(allocator, r, rt, env);
            var lst: Value = .nil_val;
            i = n;
            while (i > 0) {
                i -= 1;
                lst = list_mod.consHeap(rt, buf[i], lst) catch return DeserializeError.OutOfMemory;
            }
            return lst;
        },
        .vector => {
            const n = try r.readU32();
            var out = vector_mod.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const elt = try readValue(allocator, r, rt, env);
                out = vector_mod.conj(rt, out, elt) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .array_map => {
            const n = try r.readU32();
            var out = map_mod.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const k = try readValue(allocator, r, rt, env);
                const val = try readValue(allocator, r, rt, env);
                out = map_mod.assoc(rt, out, k, val) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .hash_set => {
            const n = try r.readU32();
            var out = set_mod.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const elt = try readValue(allocator, r, rt, env);
                out = set_mod.conj(rt, out, elt) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .var_ref => {
            const ns_bytes = try r.readLenPrefixed();
            const name_bytes = try r.readLenPrefixed();
            const ns = env.findNs(ns_bytes) orelse {
                // ns missing at deserialize time: defer resolution to
                // first use is out of v0.1.0 minimum scope; the
                // bytecode chunk is built post-bootstrap so the ns
                // should be present. Return a placeholder error.
                return DeserializeError.UnknownValueTag;
            };
            const v_ptr = ns.resolve(name_bytes) orelse return DeserializeError.UnknownValueTag;
            return Value.encodeHeapPtr(.var_ref, v_ptr);
        },
        .regex => {
            // Regex source string; decoder re-compiles via the runtime
            // regex_value.alloc constructor (matches reader's `#"..."`
            // path). Flags carry no v0.1.0 surface (no `(?i)` etc. in
            // the constant pool) — pass default Flags.
            const src = try r.readLenPrefixed();
            const regex_value = @import("../../runtime/regex/value.zig");
            const regex_compile = @import("../../runtime/regex/compile.zig");
            return regex_value.alloc(rt, src, regex_compile.Flags{}) catch return DeserializeError.OutOfMemory;
        },
        .fn_val => {
            // ADR-0034 am2: reconstruct a Function from its serialized
            // contents. Method bytecode sub-chunks are owned by `allocator`
            // (freed by `freeChunk` recursion); the Function itself is
            // gpa+trackHeap like a compiled top-level fn (params dropped per
            // D-139, body = sentinel, closure_bindings = null).
            const slot_base = try r.readU16();
            const methods_count = try r.readU32();
            const methods = allocator.alloc(tree_walk.SerializedMethod, methods_count) catch return DeserializeError.OutOfMemory;
            defer allocator.free(methods);
            var i: u32 = 0;
            while (i < methods_count) : (i += 1) methods[i] = try readFnMethod(allocator, r, rt, env);
            const has_variadic = try r.readU8();
            const variadic: ?tree_walk.SerializedMethod = if (has_variadic != 0)
                try readFnMethod(allocator, r, rt, env)
            else
                null;
            return tree_walk.allocFunctionFromSerialized(rt, slot_base, methods, variadic) catch return DeserializeError.OutOfMemory;
        },
    }
}

/// Read one function method (arity + has_rest + optional length-prefixed
/// recursive chunk). The chunk is deserialized into a fresh `allocator`-
/// owned `*BytecodeChunk`; the reconstructed Function borrows it and
/// `freeChunk` frees it. May itself contain nested `fn_val` constants
/// (handled by `deserializeChunk` → `readValue` recursion).
fn readFnMethod(allocator: std.mem.Allocator, r: *ByteReader, rt: *Runtime, env: *@import("../../runtime/env.zig").Env) DeserializeError!tree_walk.SerializedMethod {
    const arity = try r.readU16();
    const has_rest = (try r.readU8()) != 0;
    const has_bytecode = try r.readU8();
    var bytecode: ?*const BytecodeChunk = null;
    if (has_bytecode != 0) {
        const chunk_bytes = try r.readLenPrefixed();
        const sub = allocator.create(BytecodeChunk) catch return DeserializeError.OutOfMemory;
        errdefer allocator.destroy(sub);
        sub.* = try deserializeChunk(allocator, rt, env, chunk_bytes);
        bytecode = sub;
    }
    return .{ .arity = arity, .has_rest = has_rest, .bytecode = bytecode };
}

// --- Chunk serialize / deserialize ---

pub fn serializeChunk(allocator: std.mem.Allocator, chunk: BytecodeChunk) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(&MAGIC);
    try writeU16(w, VERSION);
    try writeU32(w, @intCast(chunk.instructions.len));
    for (chunk.instructions) |ins| {
        try writeU8(w, @intFromEnum(ins.opcode));
        try writeU16(w, ins.operand);
    }
    try writeU32(w, @intCast(chunk.constants.len));
    for (chunk.constants) |c| try writeValue(allocator, w, c);
    try writeU32(w, @intCast(chunk.call_sites.len));
    for (chunk.call_sites) |cs| {
        try writeLenPrefixed(w, cs.method_name);
        try writeU16(w, cs.arg_count);
    }
    try writeU32(w, @intCast(chunk.libspecs.len));
    for (chunk.libspecs) |ls| {
        try writeLenPrefixed(w, ls.ns_name);
        if (ls.alias) |a| {
            try writeU8(w, 1);
            try writeLenPrefixed(w, a);
        } else {
            try writeU8(w, 0);
        }
        try writeU32(w, @intCast(ls.refers.len));
        for (ls.refers) |refer| try writeLenPrefixed(w, refer);
    }
    return try aw.toOwnedSlice();
}

/// Deserialize a full BytecodeChunk. Returned chunk holds slices
/// allocated via `allocator`; the caller frees via `freeChunk`.
/// Constants are heap-allocated via `rt.gc.alloc` (string / list /
/// vector / map / set / regex paths) — they participate in GC.
pub fn deserializeChunk(allocator: std.mem.Allocator, rt: *Runtime, env: *@import("../../runtime/env.zig").Env, bytes: []const u8) !BytecodeChunk {
    if (bytes.len < 10) return DeserializeError.BytecodeTruncated;
    if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return DeserializeError.BadMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != VERSION) return DeserializeError.UnsupportedVersion;

    var r: ByteReader = .{ .bytes = bytes, .pos = 6 };
    const instr_count = try r.readU32();
    const instrs = try allocator.alloc(Instruction, instr_count);
    errdefer allocator.free(instrs);
    var i: u32 = 0;
    while (i < instr_count) : (i += 1) {
        const op_raw = try r.readU8();
        const op = std.enums.fromInt(Opcode, op_raw) orelse return DeserializeError.UnknownOpcode;
        const operand = try r.readU16();
        instrs[i] = .{ .opcode = op, .operand = operand };
    }

    const constants_count = try r.readU32();
    const constants = try allocator.alloc(Value, constants_count);
    errdefer allocator.free(constants);
    i = 0;
    while (i < constants_count) : (i += 1) constants[i] = try readValue(allocator, &r, rt, env);

    const cs_count = try r.readU32();
    const call_sites = try allocator.alloc(CallSiteEntry, cs_count);
    errdefer allocator.free(call_sites);
    i = 0;
    while (i < cs_count) : (i += 1) {
        const name_bytes = try r.readLenPrefixed();
        const name_dup = try allocator.dupe(u8, name_bytes);
        const arg_count = try r.readU16();
        call_sites[i] = .{ .method_name = name_dup, .arg_count = arg_count };
    }

    const ls_count = try r.readU32();
    const libspecs = try allocator.alloc(LibspecEntry, ls_count);
    errdefer allocator.free(libspecs);
    i = 0;
    while (i < ls_count) : (i += 1) {
        const ns_bytes = try r.readLenPrefixed();
        const ns_dup = try allocator.dupe(u8, ns_bytes);
        const has_alias = try r.readU8();
        var alias_dup: ?[]const u8 = null;
        if (has_alias != 0) {
            const a = try r.readLenPrefixed();
            alias_dup = try allocator.dupe(u8, a);
        }
        const refers_count = try r.readU32();
        const refers = try allocator.alloc([]const u8, refers_count);
        var j: u32 = 0;
        while (j < refers_count) : (j += 1) {
            const refer = try r.readLenPrefixed();
            refers[j] = try allocator.dupe(u8, refer);
        }
        libspecs[i] = .{ .ns_name = ns_dup, .alias = alias_dup, .refers = refers };
    }

    return BytecodeChunk{
        .instructions = instrs,
        .constants = constants,
        .call_sites = call_sites,
        .libspecs = libspecs,
    };
}

/// Free the method bytecode sub-chunks a deserialized `fn_val` constant
/// owns (ADR-0034 am2 A2-D3). Non-`fn_val` constants own nothing here.
/// Recurses via `freeChunk` so nested `fn_val`s inside a method body are
/// freed too. Does NOT free the Function struct / methods slice — those
/// are gpa+trackHeap, freed by `freeFunction` at `rt.deinit`.
fn freeValueOwnedChunks(allocator: std.mem.Allocator, v: Value) void {
    if (v.tag() != .fn_val) return;
    const f = v.decodePtr(*const Function);
    for (f.methods) |m| {
        if (m.bytecode) |chunk| {
            freeChunk(allocator, chunk.*);
            allocator.destroy(@constCast(chunk));
        }
    }
    if (f.variadic) |variadic| {
        if (variadic.bytecode) |chunk| {
            freeChunk(allocator, chunk.*);
            allocator.destroy(@constCast(chunk));
        }
    }
}

/// Free a chunk produced by `deserializeChunk`. Mirror of the
/// allocator-owned slice set; does not touch the GC-allocated Values in
/// `constants` (those are owned by `rt.gc`) except a deserialized
/// `fn_val`'s method sub-chunks, which this allocator owns.
pub fn freeChunk(allocator: std.mem.Allocator, chunk: BytecodeChunk) void {
    allocator.free(chunk.instructions);
    // ADR-0034 am2: a deserialized `fn_val` constant owns its method
    // bytecode sub-chunks via this `allocator`; free them recursively
    // before the constants array. This reads the Function's gpa-owned
    // `methods` slice, so `freeChunk`/`freeEnvelope` MUST run before
    // `rt.deinit` (which frees that slice via `freeFunction`); the run
    // sequence + defer-LIFO satisfy this. Compiled (non-deserialized)
    // fns hold arena-owned chunks and never reach this path because their
    // top chunk is arena-freed, not `freeChunk`-freed.
    for (chunk.constants) |c| freeValueOwnedChunks(allocator, c);
    allocator.free(chunk.constants);
    for (chunk.call_sites) |cs| allocator.free(cs.method_name);
    allocator.free(chunk.call_sites);
    for (chunk.libspecs) |ls| {
        allocator.free(ls.ns_name);
        if (ls.alias) |a| allocator.free(a);
        for (ls.refers) |refer| allocator.free(refer);
        allocator.free(ls.refers);
    }
    allocator.free(chunk.libspecs);
}

// === Multi-chunk payload envelope (D-100(b), `cljw build`) ===
//
// A built artifact's payload is a *sequence* of BytecodeChunks (one per
// top-level form / compilation unit, ADR-0034 amendment 1 Alt B). The
// envelope frames them so the loader can walk chunk boundaries without
// parsing each chunk's interior: `[u32 n_chunks]` then, per chunk,
// `[u32 byte_len][chunk bytes]` where the bytes are exactly what
// `serializeChunk` produces. Length-prefixing lets the loader sub-slice
// and hand each chunk to `deserializeChunk` unchanged (no codec dup).

pub fn serializeEnvelope(allocator: std.mem.Allocator, chunks: []const BytecodeChunk) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try writeU32(w, @intCast(chunks.len));
    for (chunks) |chunk| {
        const chunk_bytes = try serializeChunk(allocator, chunk);
        defer allocator.free(chunk_bytes);
        try writeU32(w, @intCast(chunk_bytes.len));
        try w.writeAll(chunk_bytes);
    }
    return try aw.toOwnedSlice();
}

/// Deserialize an envelope into owned chunks (free via `freeEnvelope`).
/// Each chunk's heap Values are reconstructed through `rt`'s GC.
pub fn deserializeEnvelope(
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *@import("../../runtime/env.zig").Env,
    bytes: []const u8,
) ![]BytecodeChunk {
    var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
    const n = try r.readU32();
    var chunks: std.ArrayList(BytecodeChunk) = .empty;
    errdefer {
        for (chunks.items) |c| freeChunk(allocator, c);
        chunks.deinit(allocator);
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const len = try r.readU32();
        try r.need(len);
        const chunk = try deserializeChunk(allocator, rt, env, bytes[r.pos .. r.pos + len]);
        try chunks.append(allocator, chunk);
        r.pos += len;
    }
    return chunks.toOwnedSlice(allocator);
}

/// Free an envelope's chunk array + each chunk's owned slices.
pub fn freeEnvelope(allocator: std.mem.Allocator, chunks: []BytecodeChunk) void {
    for (chunks) |c| freeChunk(allocator, c);
    allocator.free(chunks);
}

/// Walk an envelope's chunk byte-slices one at a time, for the
/// **interleaved** deserialize-then-run startup path. A later chunk's
/// `var_ref` to an earlier chunk's `def` only resolves once that def has
/// RUN (`op_def` interns the Var at runtime), so the loader must
/// deserialize + execute chunk N before deserializing chunk N+1; eager
/// `deserializeEnvelope` fails on such cross-chunk references. Each
/// `next()` returns a slice INTO the envelope bytes (no copy) for the
/// caller to `deserializeChunk` — typically into a run-lifetime arena so
/// all chunks (and their `fn_val` method sub-chunks) outlive every call,
/// then bulk-free at the end (a fn def'd in chunk N is still callable in
/// chunk N+M, so per-chunk freeing would use-after-free).
pub const EnvelopeIterator = struct {
    r: ByteReader,
    remaining: u32,

    pub fn init(bytes: []const u8) DeserializeError!EnvelopeIterator {
        var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
        const n = try r.readU32();
        return .{ .r = r, .remaining = n };
    }

    /// The next chunk's raw bytes, or null when the envelope is exhausted.
    pub fn next(self: *EnvelopeIterator) DeserializeError!?[]const u8 {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try self.r.readLenPrefixed();
    }
};

// === Deno-style self-contained artifact trailer (D-100(b), ADR-0034) ===
//
// `cljw build` appends the bytecode payload to a copy of the cljw runtime
// binary, then a 12-byte footer `[u64 payload_len][4-byte "CLJC"]`. At
// startup the runtime reads its own tail: a valid footer means "run the
// embedded payload" instead of the REPL / argv path. The footer lives at
// the very end so the prepended runtime stays a valid executable.
// (D-131 defers the richer ADR-0034 D4 blocks — bootstrap cache /
// build-id / Tier-0 metadata — to post-v0.1.0; the built binary re-runs
// `bootstrap.loadCore` at startup for now.)

pub const ARTIFACT_MAGIC: [4]u8 = .{ 'C', 'L', 'J', 'C' };
const ARTIFACT_FOOTER_LEN: usize = 12; // u64 len + 4-byte magic

/// Frame `runtime ++ payload ++ [u64 payload_len][\"CLJC\"]`.
pub fn frameArtifact(allocator: std.mem.Allocator, runtime: []const u8, payload: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(runtime);
    try w.writeAll(payload);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(payload.len), .little);
    try w.writeAll(&len_buf);
    try w.writeAll(&ARTIFACT_MAGIC);
    return try aw.toOwnedSlice();
}

/// If `bytes` ends with a valid `"CLJC"` footer, return the embedded
/// payload sub-slice (a view into `bytes`); else null (a bare runtime /
/// non-artifact). Validates the declared length fits before the footer.
pub fn extractPayload(bytes: []const u8) ?[]const u8 {
    if (bytes.len < ARTIFACT_FOOTER_LEN) return null;
    const footer = bytes[bytes.len - 4 ..];
    if (!std.mem.eql(u8, footer, &ARTIFACT_MAGIC)) return null;
    const len = std.mem.readInt(u64, bytes[bytes.len - ARTIFACT_FOOTER_LEN ..][0..8], .little);
    const payload_len: usize = @intCast(len);
    if (payload_len + ARTIFACT_FOOTER_LEN > bytes.len) return null;
    const end = bytes.len - ARTIFACT_FOOTER_LEN;
    return bytes[end - payload_len .. end];
}

// --- tests ---

const testing = std.testing;

test "payload envelope round-trips two chunks in order" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    const k = try keyword_mod.intern(&rt, null, "alpha");
    const consts_a = [_]Value{ Value.initInteger(7), k };
    const chunk_a: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts_a };
    const consts_b = [_]Value{Value.initInteger(99)};
    const chunk_b: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts_b };

    const bytes = try serializeEnvelope(testing.allocator, &.{ chunk_a, chunk_b });
    defer testing.allocator.free(bytes);

    const out = try deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer freeEnvelope(testing.allocator, out);

    // Order preserved: chunk_a (int 7 + :alpha), then chunk_b (int 99).
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(usize, 2), out[0].constants.len);
    try testing.expectEqual(@as(i64, 7), out[0].constants[0].asInteger());
    try testing.expect(out[0].constants[1].tag() == .keyword);
    try testing.expectEqual(@as(usize, 1), out[1].constants.len);
    try testing.expectEqual(@as(i64, 99), out[1].constants[0].asInteger());
}

test "artifact trailer frames and extracts the payload" {
    const runtime = "RUNTIME_BINARY_BYTES";
    const payload = "PAYLOAD_ENVELOPE_BYTES";
    const art = try frameArtifact(testing.allocator, runtime, payload);
    defer testing.allocator.free(art);

    // Runtime stays a prefix; payload recoverable from the footer.
    try testing.expectEqualStrings(runtime, art[0..runtime.len]);
    const got = extractPayload(art) orelse return error.NoTrailer;
    try testing.expectEqualStrings(payload, got);

    // A bare runtime (no footer) is not mistaken for an artifact.
    try testing.expect(extractPayload(runtime) == null);
    // An empty payload still frames + extracts cleanly.
    const empty_art = try frameArtifact(testing.allocator, runtime, "");
    defer testing.allocator.free(empty_art);
    try testing.expectEqual(@as(usize, 0), (extractPayload(empty_art) orelse return error.NoTrailer).len);
}

test "header magic + version round-trips on empty chunk" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const empty: BytecodeChunk = .{ .instructions = &.{}, .constants = &.{} };
    const bytes = try serializeChunk(testing.allocator, empty);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &MAGIC, bytes[0..4]);
    try testing.expectEqual(@as(u16, VERSION), std.mem.readInt(u16, bytes[4..6], .little));
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 0), round.instructions.len);
    try testing.expectEqual(@as(usize, 0), round.constants.len);
    try testing.expectEqual(@as(usize, 0), round.call_sites.len);
    try testing.expectEqual(@as(usize, 0), round.libspecs.len);
}

test "round-trips instructions" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 42 },
        .{ .opcode = .op_ret, .operand = 0 },
    };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &.{} };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 2), round.instructions.len);
    try testing.expectEqual(Opcode.op_const, round.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 42), round.instructions[0].operand);
}

test "round-trips immediate constants (nil / bool / int / float / char)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const consts = [_]Value{
        .nil_val,
        .true_val,
        .false_val,
        Value.initInteger(-42),
        Value.initFloat(3.14),
        Value.initChar('A'),
    };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 6), round.constants.len);
    try testing.expect(round.constants[0].tag() == .nil);
    try testing.expect(round.constants[1].asBoolean());
    try testing.expect(!round.constants[2].asBoolean());
    try testing.expectEqual(@as(i64, -42), round.constants[3].asInteger());
    try testing.expectApproxEqAbs(@as(f64, 3.14), round.constants[4].asFloat(), 0.0001);
    try testing.expectEqual(@as(u21, 'A'), round.constants[5].asChar());
}

test "round-trips a string constant" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const s = try string_collection.alloc(&rt, "hello");
    const consts = [_]Value{s};
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqualStrings("hello", string_collection.asString(round.constants[0]));
}

test "round-trips keyword + symbol with and without ns" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const k_bare = try keyword_mod.intern(&rt, null, "k");
    const k_ns = try keyword_mod.intern(&rt, "user", "kw");
    const s_bare = try symbol_mod.intern(&rt, null, "sym");
    const consts = [_]Value{ k_bare, k_ns, s_bare };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqualStrings("k", keyword_mod.asKeyword(round.constants[0]).name);
    try testing.expect(keyword_mod.asKeyword(round.constants[0]).ns == null);
    try testing.expectEqualStrings("user", keyword_mod.asKeyword(round.constants[1]).ns.?);
    try testing.expectEqualStrings("kw", keyword_mod.asKeyword(round.constants[1]).name);
    try testing.expectEqualStrings("sym", symbol_mod.asSymbol(round.constants[2]).name);
}

test "round-trips vector + list constants" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    var vec = vector_mod.empty();
    vec = try vector_mod.conj(&rt, vec, Value.initInteger(1));
    vec = try vector_mod.conj(&rt, vec, Value.initInteger(2));
    vec = try vector_mod.conj(&rt, vec, Value.initInteger(3));
    // Build (10 20) via cons.
    var lst: Value = .nil_val;
    lst = try list_mod.consHeap(&rt, Value.initInteger(20), lst);
    lst = try list_mod.consHeap(&rt, Value.initInteger(10), lst);
    const consts = [_]Value{ vec, lst };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(u32, 3), vector_mod.count(round.constants[0]));
    try testing.expectEqual(@as(i64, 1), vector_mod.nth(round.constants[0], 0).asInteger());
    try testing.expectEqual(@as(i64, 3), vector_mod.nth(round.constants[0], 2).asInteger());
    try testing.expectEqual(@as(u32, 2), list_mod.countOf(round.constants[1]));
    try testing.expectEqual(@as(i64, 10), list_mod.first(round.constants[1]).asInteger());
}

test "round-trips call_sites side-table" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const cs = [_]CallSiteEntry{
        .{ .method_name = "foo", .arg_count = 3 },
        .{ .method_name = "bar-bar", .arg_count = 1 },
    };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &.{}, .call_sites = @constCast(&cs) };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 2), round.call_sites.len);
    try testing.expectEqualStrings("foo", round.call_sites[0].method_name);
    try testing.expectEqual(@as(u16, 3), round.call_sites[0].arg_count);
    try testing.expectEqualStrings("bar-bar", round.call_sites[1].method_name);
}

test "round-trips libspecs side-table with alias and refers" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const refers1 = [_][]const u8{ "x", "y" };
    const ls = [_]LibspecEntry{
        .{ .ns_name = "a.b", .alias = "ab", .refers = &refers1 },
        .{ .ns_name = "c.d" },
    };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &.{}, .libspecs = @constCast(&ls) };
    const bytes = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 2), round.libspecs.len);
    try testing.expectEqualStrings("a.b", round.libspecs[0].ns_name);
    try testing.expectEqualStrings("ab", round.libspecs[0].alias.?);
    try testing.expectEqual(@as(usize, 2), round.libspecs[0].refers.len);
    try testing.expectEqualStrings("x", round.libspecs[0].refers[0]);
    try testing.expect(round.libspecs[1].alias == null);
}

test "bad magic rejected with BadMagic" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const bytes = [_]u8{ 'X', 'X', 'X', 'X', 2, 0, 0, 0, 0, 0 };
    try testing.expectError(DeserializeError.BadMagic, deserializeChunk(testing.allocator, &rt, &env, &bytes));
}

test "unsupported version rejected with UnsupportedVersion" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const bytes = [_]u8{ 'C', 'L', 'J', 'W', 99, 0, 0, 0, 0, 0 };
    try testing.expectError(DeserializeError.UnsupportedVersion, deserializeChunk(testing.allocator, &rt, &env, &bytes));
}
