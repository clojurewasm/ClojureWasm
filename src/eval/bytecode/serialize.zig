// SPDX-License-Identifier: EPL-2.0
//! Bytecode serializer + deserializer — §9.16 row 14.11(a), D-100(a).
//!
//! Wire format v3 (v3 adds the `type_descriptor` value tag per ADR-0034
//! am5; v2 added fn_val/ns_filters; extends cycle-1's instruction-only v1
//! per ADR-0034 §format-version policy "decoder-only permanent
//! compatibility"):
//!
//!   [0..4]    magic  = "CLJW"
//!   [4..6]    version (u16 LE, currently 3)
//!   [6..10]   instr_count (u32 LE)
//!   [10..]    instructions = instr_count * (opcode:u8 + operand:u16 LE)
//!   [...]     constants_count (u32 LE)
//!             for each constant: ValueTag:u8 + per-tag body
//!   [...]     call_sites_count (u32 LE)
//!             for each entry: method_name_len:u32 + bytes + arg_count:u16
//!                           + field_only:u8 + has_descriptor:u8
//!                           + (static-dispatch class fqcn: u32 len + bytes)?
//!   [...]     libspecs_count (u32 LE)
//!             for each entry: ns_name_len:u32 + bytes
//!                           + has_alias:u8 + (alias_len:u32 + bytes)?
//!                           + refers_count:u32
//!                             + each: refer_len:u32 + bytes
//!                           + refer_all:u8 + exclude_count:u32
//!                             + each: exclude_len:u32 + bytes
//!   [...]     ns_filters_count (u32 LE)   (ADR-0034 am3)
//!             for each entry: name_len:u32 + bytes + exclude_count:u32
//!                             + each: exclude_len:u32 + bytes
//!                           + has_only:u8 + (only_count:u32
//!                             + each: only_len:u32 + bytes)?
//!   [...]     ctor_sites_count (u32 LE)
//!             for each entry: type_name_len:u32 + bytes + arg_count:u16
//!   [...]     import_sites_count (u32 LE)
//!             for each entry: simple_len:u32 + bytes + fqcn_len:u32 + bytes
//!
//! Per-Value tag-byte approach (NOT raw 8-byte u64 bits) so the
//! `docs/spec/formats/<version>.edn` archive (ADR-0034 D11) records a
//! decoder-stable enum the decoder permanence policy can pin —
//! independent of F-004 NaN-box slot evolution.
//!
//! v0.1.0 tag set is the realistic compiler-produced constant
//! universe: immediates (nil / true / false / integer / float /
//! char) + interned literals (string / symbol / keyword / var_ref
//! / regex) + quoted collections (list / vector / array_map /
//! hash_set) + compiled `fn_val` (ADR-0034 am2) + class-value
//! `type_descriptor` (ADR-0034 am5, re-resolved by name). Out of scope (raise
//! explicit `UnsupportedValueTag`): atom / multi_fn / big_int /
//! wasm_* / transient_* / any runtime-only Value (per
//! `no_op_stub_forbidden.md` — no silent
//! nil-substitution like v0's `else => write nil`).

const std = @import("std");
const root_set = @import("../../runtime/gc/root_set.zig");
const opcode_mod = @import("../backend/vm/opcode.zig");
const Instruction = opcode_mod.Instruction;
const WireInstr = opcode_mod.WireInstr;
const Opcode = opcode_mod.Opcode;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const CallSiteEntry = opcode_mod.CallSiteEntry;
const CtorEntry = opcode_mod.CtorEntry;
const ImportPair = opcode_mod.ImportPair;
const LibspecEntry = opcode_mod.LibspecEntry;
const NsFilterEntry = opcode_mod.NsFilterEntry;
const value_mod = @import("../../runtime/value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const EmbeddedComponent = @import("../../runtime/runtime.zig").EmbeddedComponent;
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
pub const VERSION: u16 = 8; // v8 (ADR-0174): host-class fqcn identity unification — baked class-value constants carry JVM FQCNs ("java.util.Date", was "Date"/"cljw.java.*"), so ≤v7 artifacts are version-rejected; v7 (ADR-0173 C2'): 4B WireInstr wire + 4B-aligned instr sections + source_file/has_handlers in the chunk + interned-name constant pool (pool_ref) + headerless nested fn-method chunks; v6: rt ns merged into clojure.core (ADR-0171)

pub const SerializeError = error{
    OutOfMemory,
    WriteFailed,
    UnsupportedValueTag,
    HashMapNotSerializable,
    /// A `fn_val` constant carries `closure_bindings != null` — a runtime
    /// closure, which is never a compile-time constant (ADR-0034 am2 A2-D2).
    /// Raised as an invariant guard, not a feature gate.
    ClosureNotSerializable,
    /// A static-dispatch call-site's descriptor has a null `fqcn` (anonymous) —
    /// it cannot be re-resolved by name at deserialize. Static host-class calls
    /// always have a named class, so this is an invariant guard.
    StaticDescriptorUnnamed,
    /// A `.type_descriptor` constant wraps an anonymous descriptor (null `fqcn`,
    /// e.g. a `reify` descriptor). An anonymous descriptor is a runtime value,
    /// never an analyze-time class-symbol constant, so this is an invariant
    /// guard — it cannot be re-resolved by name at deserialize.
    TypeDescriptorUnnamed,
};

pub const DeserializeError = error{
    BytecodeTruncated,
    BadMagic,
    UnsupportedVersion,
    UnknownOpcode,
    UnknownValueTag,
    OutOfMemory,
    /// A static-call descriptor's class fqcn did not resolve in the embedded
    /// runtime (the host class is not registered). Surfaces a concrete error
    /// rather than the VM's "missing descriptor (compiler bug)".
    StaticClassUnresolved,
    /// A `.type_descriptor` constant's class name did not resolve at load
    /// (the type's `deftype`/`defrecord`/`defprotocol` chunk has not run, or
    /// the name is not a registered class). Surfaces a concrete error rather
    /// than silently substituting nil.
    TypeDescriptorUnresolved,
    /// v7: a `pool_ref` constant was found but no pool was supplied to the
    /// decoder (fail-closed — never guess).
    PoolMissing,
    /// v7: a `pool_ref` id is >= the pool's entry count.
    PoolRefOutOfRange,
};

/// Wire-format Value classifier. **Stable enum** — the
/// `docs/spec/formats/<version>.edn` archive records this byte for each
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
    /// Class-value constant (ADR-0034 am5): the boxed `.type_descriptor`
    /// ref a class symbol resolves to at analyze time (`resolveClassValue`).
    /// Serialized by NAME (the descriptor's `fqcn`), re-resolved on load via
    /// `resolveClassValue` to the runtime's canonical descriptor — the same
    /// re-resolution shape as `var_ref` and the static-call descriptor. The
    /// descriptor it names is registered by an EARLIER chunk's
    /// `deftype`/`defrecord`/`defprotocol` (which `runEnvelope` runs before
    /// this chunk deserializes), so the lookup always hits.
    type_descriptor = 0x10,
    /// v7 (ADR-0173): reference into the envelope/blob constant pool —
    /// body is a `u32` pool id. Pool entries are standalone constant
    /// encodings (tag + body, never themselves `pool_ref`) for the
    /// interned-name tags (string / symbol / keyword / var_ref / regex /
    /// type_descriptor), deduplicated per blob/payload.
    pool_ref = 0x11,
};

/// Parsed constant pool: each entry is a standalone constant encoding
/// (slice into the blob/payload bytes). Decoding an entry goes through the
/// SAME `readValue` arms as an inline constant — resolution timing is
/// unchanged (ADR-0173 Decision 3); memoized slots arrive in C4'.
pub const ConstPool = struct {
    entries: []const []const u8,
    /// C4' (ADR-0173): memoized decode slots, same length as `entries` —
    /// each unique pooled constant is decoded ONCE per pool lifetime
    /// (15.9K refs / 3.3K uniques in the bootstrap blob). The pool never
    /// solely owns a Value: a materialized slot is immediately stored into
    /// the requesting chunk's constants array, whose analysis-persist root
    /// keeps it alive for the session — so the slot array needs NO GC root
    /// of its own (see .dev/gc_rooting.md § constant pool).
    slots: []?Value = &.{},

    pub fn deinit(self: *ConstPool, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        if (self.slots.len > 0) allocator.free(self.slots);
        self.* = undefined;
    }
};

fn allocPoolSlots(allocator: std.mem.Allocator, count: usize) DeserializeError![]?Value {
    const slots = allocator.alloc(?Value, count) catch return DeserializeError.OutOfMemory;
    @memset(slots, null);
    return slots;
}

/// Serialize-side pool accumulator: dedupes poolable constants by their
/// standalone encoding. Shared across every chunk of a blob (cache_gen) or
/// payload (`cljw build`) so duplicates collapse cross-chunk/cross-region.
pub const PoolBuilder = struct {
    /// entry bytes -> pool id (keys are the owned entry slices themselves).
    map: std.StringHashMapUnmanaged(u32) = .empty,
    entries: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *PoolBuilder, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e);
        self.entries.deinit(allocator);
        self.map.deinit(allocator);
        self.* = undefined;
    }

    /// Intern `v`'s standalone encoding; returns its pool id.
    fn intern(self: *PoolBuilder, allocator: std.mem.Allocator, v: Value) SerializeError!u32 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var sub: WriteCtx = .{ .allocator = allocator, .base = 0, .pool = null };
        try writeValueRaw(&sub, &aw.writer, v);
        const bytes = try aw.toOwnedSlice();
        if (self.map.get(bytes)) |id| {
            allocator.free(bytes);
            return id;
        }
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(allocator, bytes);
        try self.map.put(allocator, bytes, id);
        return id;
    }
};

/// True when `v`'s wire encoding is a pure interned-name record (no nested
/// chunks, no collection recursion) — the poolable set (ADR-0173).
fn isPoolable(v: Value) bool {
    return switch (v.tag()) {
        .string, .symbol, .keyword, .var_ref, .regex, .type_descriptor => true,
        else => false,
    };
}

/// Serialize-side context threaded through the value/chunk writers:
/// `base` = absolute offset (within the final envelope bytes) of byte 0 of
/// the CURRENT writer, so instr sections can be padded to 4B alignment;
/// `pool` = the shared constant pool accumulator (null = inline everything).
pub const WriteCtx = struct {
    allocator: std.mem.Allocator,
    base: usize,
    pool: ?*PoolBuilder,
};

/// Deserialize-side context: `pool` resolves `pool_ref` constants;
/// `source_file` is the OWNED label nested fn-method chunks dupe from.
const ReadCtx = struct {
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *@import("../../runtime/env.zig").Env,
    pool: ?*ConstPool,
    source_file: []const u8,
    /// C3': read instr arrays as borrowed in-place views (caller guarantees
    /// the bytes outlive every chunk — rodata blob / kept-alive payload).
    in_place: bool = false,
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

fn writeValue(ctx: *WriteCtx, w: *std.Io.Writer, v: Value) SerializeError!void {
    if (ctx.pool) |pb| {
        if (isPoolable(v)) {
            const id = try pb.intern(ctx.allocator, v);
            try writeU8(w, @intFromEnum(ValueTag.pool_ref));
            try writeU32(w, id);
            return;
        }
    }
    return writeValueRaw(ctx, w, v);
}

fn writeValueRaw(ctx: *WriteCtx, w: *std.Io.Writer, v: Value) SerializeError!void {
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
                try writeValue(ctx, w, list_mod.first(cur));
                cur = list_mod.rest(cur);
            }
        },
        .vector => {
            try writeU8(w, @intFromEnum(ValueTag.vector));
            const n = vector_mod.count(v);
            try writeU32(w, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) try writeValue(ctx, w, vector_mod.nth(v, i));
        },
        .array_map => {
            try writeU8(w, @intFromEnum(ValueTag.array_map));
            const am = v.decodePtr(*const map_mod.ArrayMap);
            try writeU32(w, am.count);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                try writeValue(ctx, w, am.entries[2 * i]);
                try writeValue(ctx, w, am.entries[2 * i + 1]);
            }
        },
        .hash_map => {
            // The bytecode serializer does not yet walk a HAMT body
            // (only the array_map path is wired); raise an explicit
            // error so the user sees a concrete diagnostic rather than
            // a partial archive.
            return SerializeError.HashMapNotSerializable;
        },
        .hash_set => {
            try writeU8(w, @intFromEnum(ValueTag.hash_set));
            const s = v.decodePtr(*const set_mod.PersistentHashSet);
            if (s.map.tag() != .array_map) return SerializeError.HashMapNotSerializable;
            const am = s.map.decodePtr(*const map_mod.ArrayMap);
            try writeU32(w, am.count);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) try writeValue(ctx, w, am.entries[2 * i]);
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
            for (f.methods) |m| try writeFnMethod(ctx, w, m);
            if (f.variadic) |variadic| {
                try writeU8(w, 1);
                try writeFnMethod(ctx, w, variadic);
            } else {
                try writeU8(w, 0);
            }
        },
        .regex => {
            // Mirror of readValue's `.regex` arm: write the pattern SOURCE; the
            // decoder recompiles via `regex_value.alloc` (the `re-pattern` /
            // `#"..."` path). Inline flags `(?i)` live in the source, so source
            // alone round-trips (the read side passes default Flags). Was
            // MISSING — the wire enum (0x0E), readValue, and the format
            // archive all carried regex, but writeValue did not, so a regex
            // CONSTANT (`#","` in a fn body) fell to `else` → UnsupportedValueTag
            // (surfaced building the bookshelf demo, D-365). The round-trip
            // symmetry test now gates this class.
            try writeU8(w, @intFromEnum(ValueTag.regex));
            const regex_value = @import("../../runtime/regex/value.zig");
            try writeLenPrefixed(w, regex_value.asRegex(v).source());
        },
        .type_descriptor => {
            // ADR-0034 am5: a class-value constant. Write the descriptor's
            // `fqcn` (its `rt.types` key — the SIMPLE name for a user
            // deftype/record/protocol, the dotted FQCN for a host surface);
            // readValue re-resolves it via `resolveClassValue` to the same
            // canonical ref. An anonymous (reify) descriptor has no name and
            // is never an analyze-time constant — guard it loudly.
            const ref = v.decodePtr(*const @import("../../runtime/type_descriptor.zig").TypeDescriptorRef);
            const fqcn = ref.td_ptr.fqcn orelse return SerializeError.TypeDescriptorUnnamed;
            try writeU8(w, @intFromEnum(ValueTag.type_descriptor));
            try writeLenPrefixed(w, fqcn);
        },
        else => return SerializeError.UnsupportedValueTag,
    }
}

/// Serialize one function method: `arity` + `has_rest` + a length-prefixed
/// recursive `serializeChunk` of the method body (the body IS a
/// BytecodeChunk). `has_bytecode == 0` is a reserved forward-compat slot
/// (a method with no eager bytecode); the current compiler always emits
/// bytecode.
fn writeFnMethod(ctx: *WriteCtx, w: *std.Io.Writer, m: tree_walk.FunctionMethod) SerializeError!void {
    try writeU16(w, m.arity);
    try writeU8(w, @intFromBool(m.has_rest));
    if (m.bytecode) |chunk| {
        try writeU8(w, 1);
        // v7: nested fn-method chunks are HEADERLESS bodies (no repeated
        // magic+version — the outer chunk's header covers them) with their
        // own instr-section alignment: the nested body's byte 0 will land at
        // ctx.base + w.end + 4 (after the u32 length prefix).
        var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer aw.deinit();
        var sub: WriteCtx = .{ .allocator = ctx.allocator, .base = ctx.base + w.end + 4, .pool = ctx.pool };
        try writeChunkBody(&sub, &aw.writer, chunk.*);
        try writeLenPrefixed(w, aw.writer.buffered());
    } else {
        try writeU8(w, 0);
    }
}

fn readValue(ctx: *ReadCtx, r: *ByteReader) DeserializeError!Value {
    const allocator = ctx.allocator;
    const rt = ctx.rt;
    const env = ctx.env;
    const tag_byte = try r.readU8();
    const tag = std.enums.fromInt(ValueTag, tag_byte) orelse return DeserializeError.UnknownValueTag;
    switch (tag) {
        .pool_ref => {
            // v7 (ADR-0173): decode the pooled standalone encoding through
            // the SAME arms — the FIRST reference resolves exactly when
            // today's inline copy would have (timing preserved); later
            // references memoize (C4': 15.9K refs -> 3.3K decodes). The
            // rooting story is on ConstPool.slots' doc comment.
            const id = try r.readU32();
            const cp = ctx.pool orelse return DeserializeError.PoolMissing;
            if (id >= cp.entries.len) return DeserializeError.PoolRefOutOfRange;
            if (id < cp.slots.len) {
                if (cp.slots[id]) |cached| return cached;
            }
            var er: ByteReader = .{ .bytes = cp.entries[id], .pos = 0 };
            const v = try readValue(ctx, &er);
            if (id < cp.slots.len) cp.slots[id] = v;
            return v;
        },
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
            // A count-0 list constant is the interned empty list `()`, NOT
            // nil (D-164) — fold-from-nil would otherwise lose the distinct
            // `()` for a quoted empty list baked into the AOT blob.
            if (n == 0) return list_mod.emptyList(rt) catch return DeserializeError.OutOfMemory;
            // Read forward into a stack-allocated buffer, then cons-fold
            // back to preserve the head-first source order. Caps at a
            // bounded stack alloc; very-large quoted lists are rare in
            // the constant pool — long sequences come through `list`
            // primitive at runtime.
            const buf = std.heap.page_allocator.alloc(Value, n) catch return DeserializeError.OutOfMemory;
            defer std.heap.page_allocator.free(buf);
            var i: u32 = 0;
            while (i < n) : (i += 1) buf[i] = try readValue(ctx, r);
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
                const elt = try readValue(ctx, r);
                out = vector_mod.conj(rt, out, elt) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .array_map => {
            const n = try r.readU32();
            var out = map_mod.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const k = try readValue(ctx, r);
                const val = try readValue(ctx, r);
                out = map_mod.assoc(rt, out, k, val) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .hash_set => {
            const n = try r.readU32();
            var out = set_mod.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const elt = try readValue(ctx, r);
                out = set_mod.conj(rt, out, elt) catch return DeserializeError.OutOfMemory;
            }
            return out;
        },
        .var_ref => {
            const ns_bytes = try r.readLenPrefixed();
            const name_bytes = try r.readLenPrefixed();
            const ns = env.findNs(ns_bytes) orelse {
                // ns missing at deserialize time — a var_ref into a
                // namespace no chunk has created yet. Lazy-require /
                // cross-ns forward refs are a later cycle (ADR-0056 D3);
                // a present-ns forward ref is handled below.
                return DeserializeError.UnknownValueTag;
            };
            // A var_ref may target a var the SAME chunk `def`s later — a
            // self-recursive `(def map (fn … (map …)))` whose constant
            // pool is read before the chunk's `op_def` runs — or a
            // forward ref to a not-yet-run later chunk. Forward-declare
            // it: `env.intern` is get-or-create, so the eventual `op_def`
            // binds this very var, and the captured var_ref points at it.
            // cljw has no unbound sentinel, so the placeholder root is
            // nil until the def runs — consistent with any not-yet-def'd
            // var's nil-root default (ADR-0056 Cycle 1; this also fixes a
            // latent recursive-fn gap in the `cljw build` embedded-run).
            const v_ptr = ns.resolve(name_bytes) orelse
                (env.intern(ns, name_bytes, .nil_val, null) catch return DeserializeError.OutOfMemory);
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
        .type_descriptor => {
            // ADR-0034 am5: re-resolve a class-value constant by its canonical
            // key (the `fqcn` writeValue emitted) through the import-BLIND
            // `resolveDescriptorByKey` — NOT `resolveClassValue`, whose
            // ns-import + simple-name-fallback layers serve source symbols, not
            // a wire key, and could mis-resolve under a shadowing import at the
            // deserialize-time current ns (ADR-0034 am5 DA fork, Alt B). The
            // type's defining chunk has already run (interleaved `runEnvelope`),
            // so the lookup hits; `makeTypeDescriptorRef` returns the SAME
            // canonical ref the build-time constant held (ADR-0059). A miss is a
            // concrete error, never silent nil.
            const fqcn = try r.readLenPrefixed();
            const analyzer = @import("../analyzer/analyzer.zig");
            const td = (analyzer.resolveDescriptorByKey(rt, fqcn) catch
                return DeserializeError.OutOfMemory) orelse
                return DeserializeError.TypeDescriptorUnresolved;
            const td_mod = @import("../../runtime/type_descriptor.zig");
            return td_mod.makeTypeDescriptorRef(rt, td) catch return DeserializeError.OutOfMemory;
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
            while (i < methods_count) : (i += 1) methods[i] = try readFnMethod(ctx, r);
            const has_variadic = try r.readU8();
            const variadic: ?tree_walk.SerializedMethod = if (has_variadic != 0)
                try readFnMethod(ctx, r)
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
fn readFnMethod(ctx: *ReadCtx, r: *ByteReader) DeserializeError!tree_walk.SerializedMethod {
    const allocator = ctx.allocator;
    const arity = try r.readU16();
    const has_rest = (try r.readU8()) != 0;
    const has_bytecode = try r.readU8();
    var bytecode: ?*const BytecodeChunk = null;
    if (has_bytecode != 0) {
        // v7: nested fn-method chunks are headerless bodies; the label is
        // inherited from the enclosing top-level chunk (each nested chunk
        // OWNS its dupe so freeChunk stays uniform).
        const chunk_bytes = try r.readLenPrefixed();
        const sub = allocator.create(BytecodeChunk) catch return DeserializeError.OutOfMemory;
        errdefer allocator.destroy(sub);
        const sf = allocator.dupe(u8, ctx.source_file) catch return DeserializeError.OutOfMemory;
        errdefer allocator.free(sf);
        var br: ByteReader = .{ .bytes = chunk_bytes, .pos = 0 };
        var chunk = try readChunkBody(ctx, &br);
        chunk.source_file = sf;
        sub.* = chunk;
        bytecode = sub;
    }
    return .{ .arity = arity, .has_rest = has_rest, .bytecode = bytecode };
}

// --- Chunk serialize / deserialize ---

/// Serialize a top-level chunk: `[magic][version][source_file][body]`.
/// `base_offset` = the absolute offset (within the final envelope bytes)
/// where THIS chunk's byte 0 will land — the body pads its instr section
/// to a 4-byte boundary relative to it (ADR-0173 C2'). Standalone/test
/// callers pass 0 (the chunk bytes themselves are then 4B-consistent).
pub fn serializeChunk(allocator: std.mem.Allocator, chunk: BytecodeChunk, base_offset: usize, pool: ?*PoolBuilder) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(&MAGIC);
    try writeU16(w, VERSION);
    try writeLenPrefixed(w, chunk.source_file);
    var ctx: WriteCtx = .{ .allocator = allocator, .base = base_offset, .pool = pool };
    try writeChunkBody(&ctx, w, chunk);
    return try aw.toOwnedSlice();
}

/// The version-covered chunk body (v7): shared by top-level chunks and
/// headerless nested fn-method chunks.
fn writeChunkBody(ctx: *WriteCtx, w: *std.Io.Writer, chunk: BytecodeChunk) SerializeError!void {
    try writeU8(w, @intFromBool(chunk.has_handlers));
    // Pad so the instr array (which follows [pad_count u8][pad][count u32])
    // starts 4B-aligned relative to the envelope start (C3' reads it in
    // place via bytesAsSlice).
    const pad: u8 = @intCast((4 -% (ctx.base + w.end + 1 + 4) % 4) % 4);
    try writeU8(w, pad);
    var pi: u8 = 0;
    while (pi < pad) : (pi += 1) try writeU8(w, 0);
    try writeU32(w, @intCast(chunk.instructions.len));
    for (chunk.instructions) |ins| {
        try writeU8(w, @intFromEnum(ins.opcode));
        try writeU8(w, ins.reserved);
        try writeU16(w, ins.operand);
    }
    try writeU32(w, @intCast(chunk.constants.len));
    for (chunk.constants) |c| try writeValue(ctx, w, c);
    try writeU32(w, @intCast(chunk.call_sites.len));
    for (chunk.call_sites) |cs| {
        try writeLenPrefixed(w, cs.method_name);
        try writeU16(w, cs.arg_count);
        // field_only (`.-name` reader form) + the STATIC-dispatch descriptor
        // were BOTH dropped pre-D-365: op_static_method_call reads
        // `call_sites[i].descriptor` (the analyze-time class TypeDescriptor for
        // `Integer/parseInt` etc.), so a built binary that ran a static call
        // crashed with "missing descriptor (compiler bug)" on the VM. Serialize
        // the descriptor's fqcn; the decoder re-resolves it via the SAME
        // `resolveJavaSurface` the analyzer used (mirror of the ns_filters /
        // regex fixes — a chunk side-table field that was silently lost).
        try writeU8(w, if (cs.field_only) 1 else 0);
        if (cs.descriptor) |td| {
            const fqcn = td.fqcn orelse return SerializeError.StaticDescriptorUnnamed;
            try writeU8(w, 1);
            try writeLenPrefixed(w, fqcn);
        } else {
            try writeU8(w, 0);
        }
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
        try writeU8(w, if (ls.refer_all) 1 else 0);
        try writeU32(w, @intCast(ls.exclude.len));
        for (ls.exclude) |ex| try writeLenPrefixed(w, ex);
    }
    // ns_filters (ADR-0034 am3): `(ns x (:require …))` / `:refer-clojure`
    // filter side-table indexed by op_ns_with_filter. Required for the
    // require-closure embedding path — a user lib's `(ns …)` form compiles to
    // op_ns_with_filter, and a closure chunk that loses this table crashes at
    // run with "op_ns_with_filter index out of range".
    try writeU32(w, @intCast(chunk.ns_filters.len));
    for (chunk.ns_filters) |nf| {
        try writeLenPrefixed(w, nf.name);
        try writeU32(w, @intCast(nf.exclude.len));
        for (nf.exclude) |ex| try writeLenPrefixed(w, ex);
        if (nf.only) |only| {
            try writeU8(w, 1);
            try writeU32(w, @intCast(only.len));
            for (only) |o| try writeLenPrefixed(w, o);
        } else {
            try writeU8(w, 0);
        }
        // v4: docstring (has-flag + bytes) + refer_clojure flag (D-239 sibling).
        if (nf.doc) |d| {
            try writeU8(w, 1);
            try writeLenPrefixed(w, d);
        } else {
            try writeU8(w, 0);
        }
        try writeU8(w, if (nf.refer_clojure) 1 else 0);
        // v5: attr-map constants index (D-554; NO_ATTR when absent).
        try writeU32(w, nf.attr_const);
    }
    try writeU32(w, @intCast(chunk.ctor_sites.len));
    for (chunk.ctor_sites) |ct| {
        try writeLenPrefixed(w, ct.type_name);
        try writeU16(w, ct.arg_count);
    }
    try writeU32(w, @intCast(chunk.import_sites.len));
    for (chunk.import_sites) |ip| {
        try writeLenPrefixed(w, ip.simple);
        try writeLenPrefixed(w, ip.fqcn);
    }
}

/// Deserialize a full BytecodeChunk. Returned chunk holds slices
/// allocated via `allocator`; the caller frees via `freeChunk`.
/// Constants are heap-allocated via `rt.gc.alloc` (string / list /
/// vector / map / set / regex paths) — they participate in GC.
pub fn deserializeChunk(allocator: std.mem.Allocator, rt: *Runtime, env: *@import("../../runtime/env.zig").Env, bytes: []const u8, pool: ?*ConstPool, in_place: bool) !BytecodeChunk {
    if (bytes.len < 10) return DeserializeError.BytecodeTruncated;
    if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return DeserializeError.BadMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != VERSION) return DeserializeError.UnsupportedVersion;

    var r: ByteReader = .{ .bytes = bytes, .pos = 6 };
    const sf_wire = try r.readLenPrefixed();
    const sf = allocator.dupe(u8, if (sf_wire.len == 0) "unknown" else sf_wire) catch return DeserializeError.OutOfMemory;
    errdefer allocator.free(sf);
    var ctx: ReadCtx = .{ .allocator = allocator, .rt = rt, .env = env, .pool = pool, .source_file = sf, .in_place = in_place };
    var chunk = try readChunkBody(&ctx, &r);
    chunk.source_file = sf;
    return chunk;
}

/// The version-covered chunk body reader (v7) — mirror of `writeChunkBody`;
/// used for top-level chunks (after the magic/version/source_file header)
/// and headerless nested fn-method chunks. The returned chunk's
/// `source_file` is NOT set here (each caller assigns its owned label).
fn readChunkBody(ctx: *ReadCtx, r: *ByteReader) DeserializeError!BytecodeChunk {
    const allocator = ctx.allocator;
    const rt = ctx.rt;
    const env = ctx.env;
    const has_handlers = (try r.readU8()) != 0;
    const pad = try r.readU8();
    try r.need(pad);
    r.pos += pad;
    const instr_count = try r.readU32();
    var borrowed = false;
    const instrs: []const WireInstr = blk: {
        try r.need(instr_count * 4);
        const raw = r.bytes[r.pos .. r.pos + instr_count * 4];
        // C3' in-place: the wire record IS the in-memory WireInstr (4B, LE
        // targets only — comptime-asserted below). Validate the RAW BYTES
        // first (fail-closed for user CLJC files; an invalid enum value never
        // materializes in the typed slice — ADR-0173 Decision 2), then view.
        var k: usize = 0;
        while (k < raw.len) : (k += 4) {
            _ = std.enums.fromInt(Opcode, raw[k]) orelse return DeserializeError.UnknownOpcode;
            if (raw[k + 1] != 0) return DeserializeError.UnknownOpcode; // reserved MUST be 0
        }
        comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
        if (ctx.in_place and @intFromPtr(raw.ptr) % 4 == 0) {
            r.pos += instr_count * 4;
            borrowed = true;
            break :blk @alignCast(std.mem.bytesAsSlice(WireInstr, raw));
        }
        // Copy path (misaligned source, owned-chunk callers, tests).
        const owned = try allocator.alloc(WireInstr, instr_count);
        errdefer allocator.free(owned);
        var i: u32 = 0;
        while (i < instr_count) : (i += 1) {
            owned[i] = .{
                .opcode = std.enums.fromInt(Opcode, raw[i * 4]).?, // validated above
                .operand = std.mem.readInt(u16, raw[i * 4 + 2 ..][0..2], .little),
            };
        }
        r.pos += instr_count * 4;
        break :blk owned;
    };
    errdefer if (!borrowed) allocator.free(instrs);
    var i: u32 = 0;

    const constants_count = try r.readU32();
    const constants = try allocator.alloc(Value, constants_count);
    errdefer allocator.free(constants);
    i = 0;
    while (i < constants_count) : (i += 1) {
        constants[i] = try readValue(ctx, r);
        // D-430: `constants` is an arena slice, not a GC object — root each
        // deserialized constant on the analysis frame until the owning
        // bracket closes (constant N+1's alloc can auto-collect and would
        // otherwise sweep constant N before the chunk's EvalFrame exists).
        try root_set.pushAnalysisRoot(constants[i]);
    }

    const cs_count = try r.readU32();
    const call_sites = try allocator.alloc(CallSiteEntry, cs_count);
    errdefer allocator.free(call_sites);
    i = 0;
    while (i < cs_count) : (i += 1) {
        const name_bytes = try r.readLenPrefixed();
        const name_dup = try allocator.dupe(u8, name_bytes);
        const arg_count = try r.readU16();
        const field_only = (try r.readU8()) != 0;
        const has_desc = (try r.readU8()) != 0;
        var descriptor: ?*const @import("../../runtime/type_descriptor.zig").TypeDescriptor = null;
        if (has_desc) {
            const fqcn = try r.readLenPrefixed();
            const special_forms = @import("../analyzer/special_forms.zig");
            descriptor = special_forms.resolveJavaSurface(rt, env, fqcn) orelse
                return DeserializeError.StaticClassUnresolved;
        }
        call_sites[i] = .{ .method_name = name_dup, .arg_count = arg_count, .field_only = field_only, .descriptor = descriptor };
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
        const refer_all = (try r.readU8()) != 0;
        const exclude_count = try r.readU32();
        const exclude = try allocator.alloc([]const u8, exclude_count);
        var e: u32 = 0;
        while (e < exclude_count) : (e += 1) {
            const ex = try r.readLenPrefixed();
            exclude[e] = try allocator.dupe(u8, ex);
        }
        libspecs[i] = .{ .ns_name = ns_dup, .alias = alias_dup, .refers = refers, .refer_all = refer_all, .exclude = exclude };
    }

    const nf_count = try r.readU32();
    const ns_filters = try allocator.alloc(NsFilterEntry, nf_count);
    errdefer allocator.free(ns_filters);
    i = 0;
    while (i < nf_count) : (i += 1) {
        const name_bytes = try r.readLenPrefixed();
        const name_dup = try allocator.dupe(u8, name_bytes);
        const exclude_count = try r.readU32();
        const exclude = try allocator.alloc([]const u8, exclude_count);
        var e: u32 = 0;
        while (e < exclude_count) : (e += 1) {
            const ex = try r.readLenPrefixed();
            exclude[e] = try allocator.dupe(u8, ex);
        }
        const has_only = try r.readU8();
        var only: ?[]const []const u8 = null;
        if (has_only != 0) {
            const only_count = try r.readU32();
            const only_buf = try allocator.alloc([]const u8, only_count);
            var o: u32 = 0;
            while (o < only_count) : (o += 1) {
                const ob = try r.readLenPrefixed();
                only_buf[o] = try allocator.dupe(u8, ob);
            }
            only = only_buf;
        }
        // v4: docstring + refer_clojure flag (D-239 sibling).
        const has_doc = try r.readU8();
        var doc: ?[]const u8 = null;
        if (has_doc != 0) {
            const db = try r.readLenPrefixed();
            doc = try allocator.dupe(u8, db);
        }
        const refer_clojure = (try r.readU8()) != 0;
        // v5: attr-map constants index (D-554).
        const attr_const = try r.readU32();
        ns_filters[i] = .{ .name = name_dup, .exclude = exclude, .only = only, .doc = doc, .refer_clojure = refer_clojure, .attr_const = attr_const };
    }

    const ctor_count = try r.readU32();
    const ctor_sites = try allocator.alloc(CtorEntry, ctor_count);
    errdefer allocator.free(ctor_sites);
    i = 0;
    while (i < ctor_count) : (i += 1) {
        const tn_bytes = try r.readLenPrefixed();
        const tn_dup = try allocator.dupe(u8, tn_bytes);
        const arg_count = try r.readU16();
        ctor_sites[i] = .{ .type_name = tn_dup, .arg_count = arg_count };
    }

    const import_count = try r.readU32();
    const import_sites = try allocator.alloc(ImportPair, import_count);
    errdefer allocator.free(import_sites);
    i = 0;
    while (i < import_count) : (i += 1) {
        const simple_bytes = try r.readLenPrefixed();
        const simple_dup = try allocator.dupe(u8, simple_bytes);
        const fqcn_bytes = try r.readLenPrefixed();
        const fqcn_dup = try allocator.dupe(u8, fqcn_bytes);
        import_sites[i] = .{ .simple = simple_dup, .fqcn = fqcn_dup };
    }

    return BytecodeChunk{
        .instructions = instrs,
        .constants = constants,
        .call_sites = call_sites,
        .libspecs = libspecs,
        .ns_filters = ns_filters,
        .ctor_sites = ctor_sites,
        .import_sites = import_sites,
        .has_handlers = has_handlers,
        .borrowed_instrs = borrowed,
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
    // v7: every deserialized chunk (top-level AND nested fn-method) OWNS its
    // source_file dupe — free is uniform. Compiler-built chunks never reach
    // freeChunk (arena-owned; see the fn_val note below).
    allocator.free(chunk.source_file);
    if (!chunk.borrowed_instrs) allocator.free(chunk.instructions);
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
        for (ls.exclude) |ex| allocator.free(ex);
        allocator.free(ls.exclude);
    }
    allocator.free(chunk.libspecs);
    for (chunk.ns_filters) |nf| {
        allocator.free(nf.name);
        for (nf.exclude) |ex| allocator.free(ex);
        allocator.free(nf.exclude);
        if (nf.only) |only| {
            for (only) |o| allocator.free(o);
            allocator.free(only);
        }
        if (nf.doc) |d| allocator.free(d);
    }
    allocator.free(chunk.ns_filters);
    for (chunk.ctor_sites) |ct| allocator.free(ct.type_name);
    allocator.free(chunk.ctor_sites);
    for (chunk.import_sites) |ip| {
        allocator.free(ip.simple);
        allocator.free(ip.fqcn);
    }
    allocator.free(chunk.import_sites);
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

/// The artifact's entry point (ADR-0034 amendment 4 A4-D2). `cljw build -m
/// <ns>` records `{ ns, args }` here so the run-side invokes `(<ns>/-main …)`
/// at startup; a script-mode build records no entry (the chunks ARE the
/// program). Stored as a manifest at the FRONT of the envelope — the entry
/// point is artifact metadata (like ELF e_entry / jar Main-Class), not a code
/// chunk. `ns` / `args` slices point INTO the payload bytes (no copy); the
/// `args` outer array is allocated by `readEnvelopeEntry`'s caller arena.
pub const EnvelopeEntry = struct {
    ns: []const u8,
    args: []const []const u8 = &.{},
};

// === Embedded Wasm component table (D-100(b) + ADR-0158, D-404 Impl D) ===
//
// A `cljw build` binary that `:require`s Wasm components embeds their raw
// `.wasm` bytes so the binary is self-contained (no `.wasm` sidecar at run).
// The table is the OUTERMOST envelope section — it precedes the entry manifest
// and the chunk list: `[u32 n_components]` then, per component,
// `[u32 path_len][path bytes][u32 byte_len][wasm bytes]`. `path` is the
// resolved logical id the run-side `:require` desugar passes to
// `wasm/load-component` (ADR-0135 A2 resolution); the run-side table lookup is
// keyed by that exact string. Empty (`n=0`) for any build with no components.

/// Write the component table at the front of the envelope (mirror of
/// `readComponentTable` / `skipComponentTable`).
fn writeComponentTable(w: *std.Io.Writer, components: []const EmbeddedComponent) !void {
    try writeU32(w, @intCast(components.len));
    for (components) |c| {
        try writeLenPrefixed(w, c.path);
        try writeLenPrefixed(w, c.bytes);
    }
}

/// Advance `r` past the component table (without materialising it) so the
/// manifest / chunk readers reach the next section. Mirror of
/// `writeComponentTable`.
fn skipComponentTable(r: *ByteReader) DeserializeError!void {
    const n = try r.readU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readLenPrefixed(); // path
        _ = try r.readLenPrefixed(); // wasm bytes
    }
}

/// Read the embedded component table (slices INTO `bytes`; the outer array is
/// `arena`-allocated). Used by `cljw build`'s embedded-run startup to install
/// `rt.embedded_components` before the user payload's `:require` desugar runs.
/// Returns an empty slice for a script/main build with no components.
pub fn readComponentTable(arena: std.mem.Allocator, bytes: []const u8) ![]const EmbeddedComponent {
    var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
    const n = try r.readU32();
    const out = try arena.alloc(EmbeddedComponent, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const path = try r.readLenPrefixed();
        const wbytes = try r.readLenPrefixed();
        out[i] = .{ .path = path, .bytes = wbytes };
    }
    return out;
}

/// Write the entry manifest: `[has_entry:u8]` then, if 1, the entry ns
/// (len-prefixed) + `[args_count:u32]` + each arg (len-prefixed).
fn writeManifest(w: *std.Io.Writer, entry: ?EnvelopeEntry) !void {
    if (entry) |e| {
        try writeU8(w, 1);
        try writeLenPrefixed(w, e.ns);
        try writeU32(w, @intCast(e.args.len));
        for (e.args) |a| try writeLenPrefixed(w, a);
    } else {
        try writeU8(w, 0);
    }
}

/// Advance `r` past the entry manifest (without materialising it) so the chunk
/// readers reach `[u32 n_chunks]`. Mirror of `writeManifest`.
fn skipManifest(r: *ByteReader) DeserializeError!void {
    const has_entry = try r.readU8();
    if (has_entry == 0) return;
    _ = try r.readLenPrefixed(); // entry ns
    const args_n = try r.readU32();
    var i: u32 = 0;
    while (i < args_n) : (i += 1) _ = try r.readLenPrefixed();
}

/// Parse the entry manifest, returning the entry (ns + args as slices INTO
/// `bytes`; the args outer array is `arena`-allocated) or null for a
/// script-mode (no-entry) envelope. Used by `cljw build`'s embedded-run
/// startup to dispatch `(<ns>/-main …)`.
pub fn readEnvelopeEntry(arena: std.mem.Allocator, bytes: []const u8) !?EnvelopeEntry {
    var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
    try skipComponentTable(&r);
    const has_entry = try r.readU8();
    if (has_entry == 0) return null;
    const ns = try r.readLenPrefixed();
    const args_n = try r.readU32();
    const args = try arena.alloc([]const u8, args_n);
    var i: u32 = 0;
    while (i < args_n) : (i += 1) args[i] = try r.readLenPrefixed();
    return .{ .ns = ns, .args = args };
}

/// v7: `pool` = shared constant-pool accumulator (null = inline constants).
/// `inline_pool` appends the pool section to THIS envelope (the `cljw build`
/// payload path); blob regions pass false — their shared pool lives at the
/// region-blob level (`serializeRegions`). The pool section trails the
/// chunks (`[pool_count u32][(len+bytes)…]`), so chunk offsets — and the
/// 4B instr alignment computed from them — never depend on pool size.
pub fn serializeEnvelope(
    allocator: std.mem.Allocator,
    chunks: []const BytecodeChunk,
    entry: ?EnvelopeEntry,
    components: []const EmbeddedComponent,
    pool: ?*PoolBuilder,
    inline_pool: bool,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try writeComponentTable(w, components);
    try writeManifest(w, entry);
    try writeU32(w, @intCast(chunks.len));
    for (chunks) |chunk| {
        const chunk_bytes = try serializeChunk(allocator, chunk, w.end + 4, pool);
        defer allocator.free(chunk_bytes);
        try writeU32(w, @intCast(chunk_bytes.len));
        try w.writeAll(chunk_bytes);
    }
    if (inline_pool and pool != null) {
        const pb = pool.?;
        try writeU32(w, @intCast(pb.entries.items.len));
        for (pb.entries.items) |e| try writeLenPrefixed(w, e);
    } else {
        try writeU32(w, 0);
    }
    return try aw.toOwnedSlice();
}

/// Parse the trailing pool section of an envelope produced with
/// `inline_pool = true` (the `cljw build` payload). Returns null when the
/// envelope carries no pool (count 0). The entry slices point INTO `bytes`.
pub fn readEnvelopePool(allocator: std.mem.Allocator, bytes: []const u8) DeserializeError!?ConstPool {
    var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
    try skipComponentTable(&r);
    try skipManifest(&r);
    const n = try r.readU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) _ = try r.readLenPrefixed(); // skip chunks
    const pool_count = r.readU32() catch return null; // pre-v7 test fixtures: no section
    if (pool_count == 0) return null;
    const entries = allocator.alloc([]const u8, pool_count) catch return DeserializeError.OutOfMemory;
    errdefer allocator.free(entries);
    var j: u32 = 0;
    while (j < pool_count) : (j += 1) entries[j] = try r.readLenPrefixed();
    return .{ .entries = entries, .slots = try allocPoolSlots(allocator, pool_count) };
}

/// Deserialize an envelope into owned chunks (free via `freeEnvelope`).
/// Each chunk's heap Values are reconstructed through `rt`'s GC.
pub fn deserializeEnvelope(
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *@import("../../runtime/env.zig").Env,
    bytes: []const u8,
) ![]BytecodeChunk {
    var pool = try readEnvelopePool(allocator, bytes);
    defer if (pool) |*cp| cp.deinit(allocator);
    var r: ByteReader = .{ .bytes = bytes, .pos = 0 };
    try skipComponentTable(&r);
    try skipManifest(&r);
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
        const chunk = try deserializeChunk(allocator, rt, env, bytes[r.pos .. r.pos + len], if (pool) |*cp| cp else null, false);
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
        try skipComponentTable(&r);
        try skipManifest(&r);
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

/// Footer-seek variant of `extractPayload` for an already-open self-exe `file`
/// (D-140, ADR-0162 step 1). `stat`s the size and reads ONLY the 12-byte footer;
/// when the magic does not match (the common `cljw -e` case = a bare runtime with
/// no embedded trailer) it returns null after reading just those 12 bytes — never
/// the whole multi-MB binary. On a magic match it positioned-reads only the
/// `[size-12-payload_len .. size-12]` payload region. Returns an owned slice the
/// caller frees (distinct from `extractPayload`, which returns a view into bytes
/// already in hand — kept for callers with the full bytes, e.g. the build
/// round-trip tests). `io` drives the stat/seek/read.
pub fn readEmbeddedPayload(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !?[]u8 {
    const size = (try file.stat(io)).size;
    if (size < ARTIFACT_FOOTER_LEN) return null;
    var buf: [256]u8 = undefined;
    var r = file.reader(io, &buf);
    try r.seekTo(size - ARTIFACT_FOOTER_LEN);
    var footer: [ARTIFACT_FOOTER_LEN]u8 = undefined;
    try r.interface.readSliceAll(&footer);
    if (!std.mem.eql(u8, footer[8..12], &ARTIFACT_MAGIC)) return null;
    const payload_len: usize = @intCast(std.mem.readInt(u64, footer[0..8], .little));
    if (payload_len + ARTIFACT_FOOTER_LEN > size) return null;
    const payload = try gpa.alloc(u8, payload_len);
    errdefer gpa.free(payload);
    try r.seekTo(size - ARTIFACT_FOOTER_LEN - payload_len);
    try r.interface.readSliceAll(payload);
    return payload;
}

// === Multi-region blob (ADR-0163, D-516 lazy-namespace loading) ===
//
// One position-independent blob holding the eager core region + each lazy
// namespace's own envelope region, addressable by namespace name through a
// header index. Each region IS a self-contained `serializeEnvelope` output, so
// `EnvelopeIterator` / `driver.runEnvelope` consume a region verbatim — no new
// chunk format. Layout:
//   ["CLJR"][u32 region_count]
//   [per region: u32 name_len, name, u32 abs_offset, u32 env_len]   (the index)
//   [region envelopes, concatenated]
// `abs_offset` is measured from the blob start, so a lookup returns a sub-slice
// and the blob works at any load address (no absolute pointers — D-517-ready).

pub const REGION_MAGIC: [4]u8 = .{ 'C', 'L', 'J', 'R' };

/// One namespace's bytecode region: its name + its serialized envelope bytes.
pub const Region = struct {
    ns_name: []const u8,
    envelope: []const u8,
    /// C5' (ADR-0173 / ADR-0172 L2): store this region flate-compressed
    /// (`.raw` container). Only LAZY regions — the eager set stays raw so
    /// its instr sections remain zero-copy views into rodata.
    compress: bool = false,
};

/// A located region: raw bytes + compression metadata (index v2, C5').
pub const RegionRef = struct {
    bytes: []const u8,
    compressed: bool,
    uncompressed_len: u32,
};

/// flate-compress `bytes` (`.raw` container, best level). Caller frees.
pub fn flateCompress(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const flate = std.compress.flate;
    // Compress.init asserts output.buffer.len > 8 — an .init(alloc)
    // Allocating writer starts with an EMPTY buffer (cache_gen ABRT'd on
    // the assert), so pre-grow it.
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(64, bytes.len / 2));
    errdefer aw.deinit();
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var cmp = try flate.Compress.init(&aw.writer, window, .raw, .best);
    try cmp.writer.writeAll(bytes);
    try cmp.finish();
    return try aw.toOwnedSlice();
}

/// Decompress a located region into `allocator` (8-aligned, so the in-place
/// instr views work over the buffer). Returns `ref.bytes` as-is when the
/// region is stored raw. The caller's allocator owns the result for the
/// session (`rt.load_arena` — fns capture their bytecode).
pub fn decompressRegion(allocator: std.mem.Allocator, ref: RegionRef) ![]const u8 {
    if (!ref.compressed) return ref.bytes;
    return flateDecompress(allocator, ref.bytes, ref.uncompressed_len);
}

/// Decompress `bytes` (flate `.raw`) into a fresh 8-aligned buffer of
/// exactly `uncompressed_len`. A REAL history window is required: the
/// zero-buffer "direct mode" routes readSliceAll through the indirect
/// path, whose rebase computes buffer.len - history_len and
/// usize-underflows on an empty buffer (probed 2026-07-16, Debug trace at
/// Decompress.zig:104).
pub fn flateDecompress(allocator: std.mem.Allocator, bytes: []const u8, uncompressed_len: u32) ![]const u8 {
    const flate = std.compress.flate;
    const out = try allocator.alignedAlloc(u8, .fromByteUnits(8), uncompressed_len);
    errdefer allocator.free(out);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var in: std.Io.Reader = .fixed(bytes);
    var d: flate.Decompress = .init(&in, .raw, window);
    try d.reader.readSliceAll(out);
    return out;
}

/// Serialize `regions` into one position-independent blob (layout above). Each
/// `region.envelope` must be a `serializeEnvelope` output; the caller owns them.
pub fn serializeRegions(allocator: std.mem.Allocator, regions: []const Region, pool_entries: []const []const u8) ![]u8 {
    // C5': compress the flagged (lazy) regions first — the index stores the
    // STORED length + flags + uncompressed_len (index v2).
    const stored = try allocator.alloc([]const u8, regions.len);
    defer {
        for (regions, stored) |reg, st| if (reg.compress) allocator.free(st);
        allocator.free(stored);
    }
    for (regions, 0..) |reg, i|
        stored[i] = if (reg.compress) try flateCompress(allocator, reg.envelope) else reg.envelope;

    var index_size: usize = 4 + 4; // magic + count
    for (regions) |reg| index_size += 4 + reg.ns_name.len + 4 + 4 + 1 + 4; // name+off+stored_len+flags+uncompressed_len

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(&REGION_MAGIC);
    try writeU32(w, @intCast(regions.len));
    // v7: region starts are padded to 8B so every envelope-relative 4B
    // instr alignment (writeChunkBody) is blob-absolute too (the embed
    // wrapper aligns the whole blob to 8 — ADR-0173 Decision 2).
    var off: usize = std.mem.alignForward(usize, index_size, 8);
    for (regions, stored) |reg, st| {
        try writeLenPrefixed(w, reg.ns_name);
        try writeU32(w, @intCast(off));
        try writeU32(w, @intCast(st.len));
        try writeU8(w, if (reg.compress) 1 else 0);
        try writeU32(w, @intCast(reg.envelope.len));
        off = std.mem.alignForward(usize, off + st.len, 8);
    }
    var written: usize = index_size;
    for (stored) |st| {
        while (written % 8 != 0) : (written += 1) try writeU8(w, 0);
        try w.writeAll(st);
        written += st.len;
    }
    // Trailing blob-level pool (shared by every region's chunks): begins
    // right after the last region's padded end; `readBlobPool` derives the
    // offset from the index, so no placeholder patching is needed.
    while (written % 8 != 0) : (written += 1) try writeU8(w, 0);
    try writeU32(w, @intCast(pool_entries.len));
    for (pool_entries) |e| try writeLenPrefixed(w, e);
    return try aw.toOwnedSlice();
}

/// Parse the blob-level shared constant pool (v7): located at the 8B-aligned
/// offset after the LAST region (derived from the header index). Returns
/// null for a poolless blob. Entry slices point INTO `blob`.
pub fn readBlobPool(allocator: std.mem.Allocator, blob: []const u8) DeserializeError!?ConstPool {
    if (blob.len < 8 or !std.mem.eql(u8, blob[0..4], &REGION_MAGIC)) return null;
    var r: ByteReader = .{ .bytes = blob, .pos = 4 };
    const count = try r.readU32();
    var end: usize = r.pos;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try r.readLenPrefixed();
        const off = try r.readU32();
        const len = try r.readU32();
        _ = try r.readU8(); // flags (C5')
        _ = try r.readU32(); // uncompressed_len (C5')
        if (off + len > blob.len) return DeserializeError.BytecodeTruncated;
        if (off + len > end) end = off + len;
    }
    end = std.mem.alignForward(usize, end, 8);
    if (end + 4 > blob.len) return null;
    var pr: ByteReader = .{ .bytes = blob, .pos = end };
    const pool_count = try pr.readU32();
    if (pool_count == 0) return null;
    const entries = allocator.alloc([]const u8, pool_count) catch return DeserializeError.OutOfMemory;
    errdefer allocator.free(entries);
    var j: u32 = 0;
    while (j < pool_count) : (j += 1) entries[j] = try pr.readLenPrefixed();
    return .{ .entries = entries, .slots = try allocPoolSlots(allocator, pool_count) };
}

/// Return the envelope bytes for `ns_name` (a sub-slice into `blob`), or null if
/// `blob` is not a region blob or has no such region. O(region_count) linear scan
/// of the header index — region_count is ~30 and lazy `require` is not a hot path.
pub fn findRegion(blob: []const u8, ns_name: []const u8) ?RegionRef {
    if (blob.len < 8 or !std.mem.eql(u8, blob[0..4], &REGION_MAGIC)) return null;
    var r: ByteReader = .{ .bytes = blob, .pos = 4 };
    const count = r.readU32() catch return null;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = r.readLenPrefixed() catch return null;
        const off = r.readU32() catch return null;
        const len = r.readU32() catch return null;
        const flags = r.readU8() catch return null;
        const ulen = r.readU32() catch return null;
        if (std.mem.eql(u8, name, ns_name)) {
            if (off + len > blob.len) return null;
            return .{ .bytes = blob[off .. off + len], .compressed = (flags & 1) != 0, .uncompressed_len = ulen };
        }
    }
    return null;
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

    const bytes = try serializeEnvelope(testing.allocator, &.{ chunk_a, chunk_b }, null, &.{}, null, false);
    defer testing.allocator.free(bytes);

    var af_1198: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1198, testing.allocator);
    defer root_set.endAnalysis(&af_1198);
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

test "region blob: findRegion returns each ns's envelope; absent / non-region -> null (D-516)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    // Two single-chunk envelopes standing in for two namespaces' regions.
    const consts_a = [_]Value{Value.initInteger(7)};
    const chunk_a: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts_a };
    const env_a = try serializeEnvelope(testing.allocator, &.{chunk_a}, null, &.{}, null, false);
    defer testing.allocator.free(env_a);
    const consts_b = [_]Value{Value.initInteger(42)};
    const chunk_b: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts_b };
    const env_b = try serializeEnvelope(testing.allocator, &.{chunk_b}, null, &.{}, null, false);
    defer testing.allocator.free(env_b);

    const blob = try serializeRegions(testing.allocator, &.{
        .{ .ns_name = "clojure.core", .envelope = env_a },
        .{ .ns_name = "clojure.string", .envelope = env_b },
    }, &.{});
    defer testing.allocator.free(blob);

    // Each region's sub-slice equals its source envelope and deserializes to its chunk.
    const got_a = (findRegion(blob, "clojure.core") orelse return error.NoRegion).bytes;
    try testing.expectEqualSlices(u8, env_a, got_a);
    var af_1237: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1237, testing.allocator);
    defer root_set.endAnalysis(&af_1237);
    const chunks_a = try deserializeEnvelope(testing.allocator, &rt, &env, got_a);
    defer freeEnvelope(testing.allocator, chunks_a);
    try testing.expectEqual(@as(i64, 7), chunks_a[0].constants[0].asInteger());

    const got_b = (findRegion(blob, "clojure.string") orelse return error.NoRegion).bytes;
    try testing.expectEqualSlices(u8, env_b, got_b);

    // Absent ns + a non-region blob both yield null.
    try testing.expect(findRegion(blob, "clojure.set") == null);
    try testing.expect(findRegion("not a region blob!!", "x") == null);
}

test "envelope entry manifest round-trips; chunk readers skip it (ADR-0034 am4)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var consts = [_]Value{Value.initInteger(5)};
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const args = [_][]const u8{ "8080", "foo" };

    // With an entry manifest: readEnvelopeEntry recovers it; the chunk readers
    // skip the manifest and still see the one chunk.
    const bytes = try serializeEnvelope(testing.allocator, &.{chunk}, .{ .ns = "my.app", .args = &args }, &.{}, null, false);
    defer testing.allocator.free(bytes);

    const entry = (try readEnvelopeEntry(arena, bytes)) orelse return error.NoEntry;
    try testing.expectEqualStrings("my.app", entry.ns);
    try testing.expectEqual(@as(usize, 2), entry.args.len);
    try testing.expectEqualStrings("8080", entry.args[0]);
    try testing.expectEqualStrings("foo", entry.args[1]);

    var af_1276: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1276, testing.allocator);
    defer root_set.endAnalysis(&af_1276);
    const out = try deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer freeEnvelope(testing.allocator, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(i48, 5), out[0].constants[0].asInteger());

    // No-entry (script mode) envelope: readEnvelopeEntry returns null.
    const bytes2 = try serializeEnvelope(testing.allocator, &.{chunk}, null, &.{}, null, false);
    defer testing.allocator.free(bytes2);
    try testing.expect((try readEnvelopeEntry(arena, bytes2)) == null);
}

test "embedded component table round-trips; chunk + entry readers skip it (ADR-0158)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var consts = [_]Value{Value.initInteger(42)};
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const args = [_][]const u8{"9090"};
    const components = [_]EmbeddedComponent{
        .{ .path = "./greet.wasm", .bytes = "\x00asm\x01\x00\x00\x00" },
        .{ .path = "/abs/calc.wasm", .bytes = "RAWBYTES" },
    };

    // A full envelope: component table + an entry manifest + one chunk. The
    // component table is the OUTERMOST section, so the entry/chunk readers must
    // skip past it and still recover the manifest + chunk unchanged.
    const bytes = try serializeEnvelope(testing.allocator, &.{chunk}, .{ .ns = "my.app", .args = &args }, &components, null, false);
    defer testing.allocator.free(bytes);

    const table = try readComponentTable(arena, bytes);
    try testing.expectEqual(@as(usize, 2), table.len);
    try testing.expectEqualStrings("./greet.wasm", table[0].path);
    try testing.expectEqualStrings("\x00asm\x01\x00\x00\x00", table[0].bytes);
    try testing.expectEqualStrings("/abs/calc.wasm", table[1].path);
    try testing.expectEqualStrings("RAWBYTES", table[1].bytes);

    // The entry manifest survives behind the table.
    const entry = (try readEnvelopeEntry(arena, bytes)) orelse return error.NoEntry;
    try testing.expectEqualStrings("my.app", entry.ns);
    try testing.expectEqualStrings("9090", entry.args[0]);

    // The chunk readers (deserializeEnvelope / EnvelopeIterator) skip both the
    // table and the manifest and still see the one chunk.
    var af_1327: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1327, testing.allocator);
    defer root_set.endAnalysis(&af_1327);
    const out = try deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer freeEnvelope(testing.allocator, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(i64, 42), out[0].constants[0].asInteger());

    var it = try EnvelopeIterator.init(bytes);
    var seen: usize = 0;
    while (try it.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 1), seen);

    // An empty table (n=0) still round-trips with no components.
    const bytes_empty = try serializeEnvelope(testing.allocator, &.{chunk}, null, &.{}, null, false);
    defer testing.allocator.free(bytes_empty);
    try testing.expectEqual(@as(usize, 0), (try readComponentTable(arena, bytes_empty)).len);
}

test "every wire ValueTag has BOTH a write and a read arm (symmetry gate)" {
    // Structural gate for the write↔read asymmetry class. writeValue (switch on
    // Value.Tag, with an `else`) and readValue (exhaustive switch on ValueTag)
    // are TWO separate switches kept in sync BY HAND — plus the format
    // archive + the module-header doc, four places total. Nothing mechanical
    // enforced cross-symmetry, so `regex` (0x0E) shipped with a wire enum slot +
    // a readValue arm + an archive entry + a doc mention but NO writeValue arm —
    // undetected until the bookshelf demo's `#","` hit it (D-365).
    //
    // This `inline for` + exhaustive `switch (tag)` (no `else`) is the gate: a
    // NEW ValueTag makes the switch non-exhaustive → a COMPILE ERROR here →
    // the author MUST supply a representative, which round-trips it and thereby
    // proves both a write arm and a read arm exist + agree on the tag byte.
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    const regex_value = @import("../../runtime/regex/value.zig");
    const regex_compile = @import("../../runtime/regex/compile.zig");
    const user_ns = env.current_ns.?; // Env.init creates `user` + sets current_ns
    const one = Value.initInteger(1);

    inline for (std.meta.fields(ValueTag)) |field| {
        const tag: ValueTag = @enumFromInt(field.value);
        // pool_ref is a reference INTO a pool, not a standalone constant —
        // its round-trip is covered by the dedicated pool tests below.
        if (tag == .pool_ref) continue;
        const rep: Value = switch (tag) {
            .pool_ref => unreachable, // continue'd above
            .nil => Value.nil_val,
            .true_val => Value.initBoolean(true),
            .false_val => Value.initBoolean(false),
            .integer => one,
            .float => Value.initFloat(1.5),
            .char => Value.initChar('a'),
            .string => try string_collection.alloc(&rt, "s"),
            .symbol => try symbol_mod.intern(&rt, null, "sym"),
            .keyword => try keyword_mod.intern(&rt, null, "kw"),
            .list => try list_mod.consHeap(&rt, one, try list_mod.emptyList(&rt)),
            .vector => try vector_mod.conj(&rt, vector_mod.empty(), one),
            .array_map => try map_mod.assoc(&rt, map_mod.empty(), one, one),
            .hash_set => try set_mod.conj(&rt, set_mod.empty(), one),
            .var_ref => Value.encodeHeapPtr(.var_ref, try env.intern(user_ns, "v", .nil_val, null)),
            .regex => try regex_value.alloc(&rt, "ab.", regex_compile.Flags{}),
            .fn_val => try tree_walk.allocFunctionFromSerialized(&rt, 0, &[_]tree_walk.SerializedMethod{}, null),
            .type_descriptor => blk: {
                const td_mod = @import("../../runtime/type_descriptor.zig");
                const td = try td_mod.registerType(&rt, "SymGateType", null, &.{}, &.{}, .deftype);
                break :blk try td_mod.makeTypeDescriptorRef(&rt, td);
            },
        };
        var sbuf: [4096]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&sbuf);
        var wctx: WriteCtx = .{ .allocator = testing.allocator, .base = 0, .pool = null };
        writeValue(&wctx, &sw, rep) catch |e| {
            std.debug.print("writeValue has NO arm for ValueTag.{s}: {}\n", .{ @tagName(tag), e });
            return error.WriteArmMissing;
        };
        const bytes = sw.buffered();
        try testing.expectEqual(@intFromEnum(tag), bytes[0]); // write emits the right wire tag
        var rr: ByteReader = .{ .bytes = bytes, .pos = 0 };
        var rctx: ReadCtx = .{ .allocator = testing.allocator, .rt = &rt, .env = &env, .pool = null, .source_file = "test" };
        _ = readValue(&rctx, &rr) catch |e| {
            std.debug.print("readValue has NO arm for ValueTag.{s}: {}\n", .{ @tagName(tag), e });
            return error.ReadArmMissing;
        };
    }
}

test "type_descriptor constant round-trips by name (ADR-0034 am5; D-452)" {
    // A class-value constant — the `.type_descriptor` ref `resolveClassValue`
    // mints for a class symbol — round-trips by NAME: writeValue emits the
    // descriptor's fqcn, readValue re-resolves it through `resolveClassValue`
    // to the runtime's canonical ref. This is the serializer half of D-452's
    // non-core-.clj AOT unblock (the prior `UnsupportedValueTag` blocker).
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    const type_descriptor = @import("../../runtime/type_descriptor.zig");
    // The defining chunk has run by load time → the type is registered. Mirror
    // that here by registering BEFORE deserialize.
    const td = try type_descriptor.registerType(&rt, "ZipLoc", null, &.{}, &.{}, .defrecord);
    const ref = try type_descriptor.makeTypeDescriptorRef(&rt, td);

    const consts = [_]Value{ Value.initInteger(1), ref };
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &consts };
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);

    var af_1433: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1433, testing.allocator);
    defer root_set.endAnalysis(&af_1433);
    const out = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.constants.len);
    try testing.expect(out.constants[1].tag() == .type_descriptor);
    // ADR-0059 one-ref-per-descriptor: the re-resolved ref decodes to the SAME
    // canonical descriptor as the original constant.
    try testing.expectEqual(td, out.constants[1].decodePtr(*const type_descriptor.TypeDescriptorRef).td_ptr);

    // An UNREGISTERED class name → a concrete error, never silent nil.
    const consts2 = [_]Value{ref};
    const bogus = try serializeChunk(testing.allocator, (BytecodeChunk{ .instructions = &.{}, .constants = &consts2 }), 0, null);
    defer testing.allocator.free(bogus);
    // Overwrite the embedded name "ZipLoc" region is fragile; instead drop the
    // type and re-deserialize: a fresh runtime without the registration misses.
    var rt2 = Runtime.init(th.io(), testing.allocator);
    defer rt2.deinit();
    var env2 = try @import("../../runtime/env.zig").Env.init(&rt2);
    defer env2.deinit();
    var af_1451: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1451, testing.allocator);
    defer root_set.endAnalysis(&af_1451);
    try testing.expectError(DeserializeError.TypeDescriptorUnresolved, deserializeChunk(testing.allocator, &rt2, &env2, bogus, null, false));
}

test "chunk completeness gate: every side-table + entry field round-trips (D-365 residual)" {
    // Structural gate for the two serialize-incompleteness axes the Value-tag
    // symmetry gate does NOT cover: (a) a whole chunk SIDE-TABLE dropped
    // (ns_filters, D-356) and (b) a side-table FIELD dropped
    // (call_sites.descriptor + field_only, D-365). Both shipped undetected —
    // write/read are hand-synced and nothing forced a new table/field to be
    // serialized — and surfaced only when the bookshelf built binary ran on the
    // VM. This gate closes the class two ways:
    //   (1) a COMPILE-TIME exhaustiveness check (std.meta.FieldEnum + an
    //       else-less switch, mirroring the Value-tag inline-for gate) over the
    //       BytecodeChunk side-tables AND each side-table entry struct — a NEW
    //       field is a compile error here until it is classified
    //       serialized-or-exempt; and
    //   (2) a populated round-trip that fills EVERY side-table and asserts EVERY
    //       serialized field survives. The existing per-table tests under-assert
    //       (the "round-trips call_sites" test never checked descriptor /
    //       field_only — exactly the field that was silently dropped).
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    const type_descriptor = @import("../../runtime/type_descriptor.zig");

    // --- (1) compile-time field-exhaustiveness gates ---
    // A new field on any of these structs makes the switch non-exhaustive → a
    // compile error → the author MUST classify it (serialized-and-asserted
    // below, or documented exempt). This is the mechanical close of the user's
    // "structural drift" concern (a forget-to-update hazard). The `classified` bool only gives each switch a
    // result (so the prong bodies are non-empty); the exhaustiveness IS the gate.
    inline for (std.meta.fields(BytecodeChunk)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(BytecodeChunk), f.name)) {
            // serialized + asserted in the round-trip below
            .instructions, .constants, .call_sites, .libspecs, .ns_filters, .ctor_sites, .import_sites => true,
            // EXEMPT: AOT omits source_file by design; a deserialized chunk
            // defaults to "unknown" (per the BytecodeChunk doc-comment).
            .source_file => true,
            // EXEMPT: per-op loc sidecar is compiler-only (ADR-0173 C1 /
            // ADR-0118 — AOT chunks report 0:0; the wire carries no loc).
            .locs => true,
            // EXEMPT: runtime ownership flag (C3' in-place views), not wire data.
            .borrowed_instrs => true,
            // EXEMPT: `has_handlers` is a DERIVED field (ADR-0131 2b) — recomputable
            // by scanning the instructions. AOT omits it; a deserialized chunk
            // defaults to `true` (conservatively not flattened by the in-VM call
            // frame path, which is a perf opt with an identical-Value slow fallback).
            .has_handlers => true,
        };
        try testing.expect(classified);
    }
    inline for (std.meta.fields(CallSiteEntry)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(CallSiteEntry), f.name)) {
            .method_name, .arg_count, .field_only, .descriptor => true,
            // EXEMPT: `cache` is the runtime monomorphic inline cache (mutated
            // at first dispatch), not compile-time chunk state — never serialized.
            .cache => true,
        };
        try testing.expect(classified);
    }
    inline for (std.meta.fields(LibspecEntry)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(LibspecEntry), f.name)) {
            .ns_name, .alias, .refers, .refer_all, .exclude => true,
        };
        try testing.expect(classified);
    }
    inline for (std.meta.fields(CtorEntry)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(CtorEntry), f.name)) {
            .type_name, .arg_count => true,
        };
        try testing.expect(classified);
    }
    inline for (std.meta.fields(ImportPair)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(ImportPair), f.name)) {
            .simple, .fqcn => true,
        };
        try testing.expect(classified);
    }
    inline for (std.meta.fields(NsFilterEntry)) |f| {
        const classified: bool = switch (@field(std.meta.FieldEnum(NsFilterEntry), f.name)) {
            .name, .exclude, .only, .doc, .refer_clojure, .attr_const => true,
        };
        try testing.expect(classified);
    }

    // --- (2) populated round-trip: every side-table non-empty, every field asserted ---
    // A registered host class so the static-dispatch descriptor re-resolves at
    // deserialize (resolveJavaSurface(rt, env, fqcn) returns this rt.types entry;
    // freeChunk does NOT free `descriptor`, which rt.types owns → no double-free).
    const int_td = try type_descriptor.registerType(&rt, "java.lang.Integer", null, &.{}, &.{}, .native);

    const call_sites = [_]CallSiteEntry{
        // instance dispatch (descriptor null, field_only false)
        .{ .method_name = "size", .arg_count = 0 },
        // a `.-field` read (field_only true) + a STATIC descriptor — the two
        // fields D-365 found silently dropped.
        .{ .method_name = "parseInt", .arg_count = 1, .field_only = true, .descriptor = int_td },
    };
    const refers = [_][]const u8{ "inc", "dec" };
    const ls_exclude = [_][]const u8{"map"};
    const libspecs = [_]LibspecEntry{
        .{ .ns_name = "a.b", .alias = "ab", .refers = &refers, .refer_all = true, .exclude = &ls_exclude },
    };
    const nf_exclude = [_][]const u8{"reduce"};
    const nf_only = [_][]const u8{"inc"};
    const ns_filters = [_]NsFilterEntry{
        .{ .name = "app.core", .exclude = &nf_exclude, .only = &nf_only, .doc = "the ns doc", .refer_clojure = false, .attr_const = 7 },
    };
    const ctor_sites = [_]CtorEntry{
        .{ .type_name = "java.io.File", .arg_count = 1 },
    };
    const import_sites = [_]ImportPair{
        .{ .simple = "File", .fqcn = "java.io.File" },
    };
    const instrs = [_]WireInstr{.from(.op_const, 0)};
    const consts = [_]Value{Value.initInteger(7)};
    const chunk: BytecodeChunk = .{
        .instructions = &instrs,
        .constants = &consts,
        .call_sites = @constCast(&call_sites),
        .libspecs = @constCast(&libspecs),
        .ns_filters = @constCast(&ns_filters),
        .ctor_sites = @constCast(&ctor_sites),
        .import_sites = @constCast(&import_sites),
    };

    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1578: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1578, testing.allocator);
    defer root_set.endAnalysis(&af_1578);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, round);

    // instructions + constants
    try testing.expectEqual(@as(usize, 1), round.instructions.len);
    try testing.expectEqual(@as(usize, 1), round.constants.len);
    try testing.expectEqual(@as(i64, 7), round.constants[0].asInteger());

    // call_sites — including the previously-dropped field_only + descriptor
    try testing.expectEqual(@as(usize, 2), round.call_sites.len);
    try testing.expectEqualStrings("size", round.call_sites[0].method_name);
    try testing.expect(!round.call_sites[0].field_only);
    try testing.expect(round.call_sites[0].descriptor == null);
    try testing.expectEqualStrings("parseInt", round.call_sites[1].method_name);
    try testing.expectEqual(@as(u16, 1), round.call_sites[1].arg_count);
    try testing.expect(round.call_sites[1].field_only);
    try testing.expect(round.call_sites[1].descriptor != null);
    try testing.expectEqualStrings("java.lang.Integer", round.call_sites[1].descriptor.?.fqcn.?);

    // libspecs — alias + refers + refer_all + exclude
    try testing.expectEqual(@as(usize, 1), round.libspecs.len);
    try testing.expectEqualStrings("a.b", round.libspecs[0].ns_name);
    try testing.expectEqualStrings("ab", round.libspecs[0].alias.?);
    try testing.expectEqual(@as(usize, 2), round.libspecs[0].refers.len);
    try testing.expectEqualStrings("inc", round.libspecs[0].refers[0]);
    try testing.expect(round.libspecs[0].refer_all);
    try testing.expectEqual(@as(usize, 1), round.libspecs[0].exclude.len);
    try testing.expectEqualStrings("map", round.libspecs[0].exclude[0]);

    // ns_filters — exclude + only + doc + refer_clojure (v4)
    try testing.expectEqual(@as(usize, 1), round.ns_filters.len);
    try testing.expectEqualStrings("app.core", round.ns_filters[0].name);
    try testing.expectEqualStrings("reduce", round.ns_filters[0].exclude[0]);
    try testing.expectEqualStrings("inc", round.ns_filters[0].only.?[0]);
    try testing.expectEqualStrings("the ns doc", round.ns_filters[0].doc.?);
    try testing.expect(!round.ns_filters[0].refer_clojure);
    try testing.expectEqual(@as(u32, 7), round.ns_filters[0].attr_const);

    // ctor_sites
    try testing.expectEqual(@as(usize, 1), round.ctor_sites.len);
    try testing.expectEqualStrings("java.io.File", round.ctor_sites[0].type_name);
    try testing.expectEqual(@as(u16, 1), round.ctor_sites[0].arg_count);

    // import_sites
    try testing.expectEqual(@as(usize, 1), round.import_sites.len);
    try testing.expectEqualStrings("File", round.import_sites[0].simple);
    try testing.expectEqualStrings("java.io.File", round.import_sites[0].fqcn);
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

test "readEmbeddedPayload: footer-seek round-trips the payload; bare runtime + short file → null (D-140)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const runtime = "RUNTIME_BINARY_BYTES_LONG_ENOUGH_TO_MATTER";
    const payload = "PAYLOAD_ENVELOPE_BYTES";

    const writeFile = struct {
        fn go(d: std.Io.Dir, i: std.Io, name: []const u8, bytes: []const u8) !void {
            const f = try d.createFile(i, name, .{ .truncate = true });
            defer f.close(i);
            var wbuf: [256]u8 = undefined;
            var w = f.writer(i, &wbuf);
            try w.interface.writeAll(bytes);
            try w.interface.flush();
        }
    }.go;

    // A real artifact: footer-seek recovers exactly the payload.
    const art = try frameArtifact(testing.allocator, runtime, payload);
    defer testing.allocator.free(art);
    try writeFile(tmp.dir, io, "art.bin", art);
    {
        const f = try tmp.dir.openFile(io, "art.bin", .{});
        defer f.close(io);
        const got = (try readEmbeddedPayload(io, testing.allocator, f)) orelse return error.NoTrailer;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(payload, got);
    }

    // A bare runtime (no footer) → null, without reading it as an artifact.
    try writeFile(tmp.dir, io, "bare.bin", runtime);
    {
        const f = try tmp.dir.openFile(io, "bare.bin", .{});
        defer f.close(io);
        try testing.expect((try readEmbeddedPayload(io, testing.allocator, f)) == null);
    }

    // A file shorter than the 12-byte footer → null (no underflow).
    try writeFile(tmp.dir, io, "tiny.bin", "ab");
    {
        const f = try tmp.dir.openFile(io, "tiny.bin", .{});
        defer f.close(io);
        try testing.expect((try readEmbeddedPayload(io, testing.allocator, f)) == null);
    }

    // An empty payload still frames + footer-seeks cleanly (zero-length result).
    const empty_art = try frameArtifact(testing.allocator, runtime, "");
    defer testing.allocator.free(empty_art);
    try writeFile(tmp.dir, io, "empty.bin", empty_art);
    {
        const f = try tmp.dir.openFile(io, "empty.bin", .{});
        defer f.close(io);
        const got = (try readEmbeddedPayload(io, testing.allocator, f)) orelse return error.NoTrailer;
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "header magic + version round-trips on empty chunk" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const empty: BytecodeChunk = .{ .instructions = &.{}, .constants = &.{} };
    const bytes = try serializeChunk(testing.allocator, empty, 0, null);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &MAGIC, bytes[0..4]);
    try testing.expectEqual(@as(u16, VERSION), std.mem.readInt(u16, bytes[4..6], .little));
    var af_1715: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1715, testing.allocator);
    defer root_set.endAnalysis(&af_1715);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 0), round.instructions.len);
    try testing.expectEqual(@as(usize, 0), round.constants.len);
    try testing.expectEqual(@as(usize, 0), round.call_sites.len);
    try testing.expectEqual(@as(usize, 0), round.libspecs.len);
}

test "round-trips ns_filters side-table (ADR-0034 am3 — require-closure embedding)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    // A `(ns a (:require [b]) (:refer-clojure :exclude [map] :only [inc]))`
    // compiles to op_ns_with_filter indexing this entry. Before am3 the
    // serializer dropped ns_filters, so a deserialized closure chunk crashed
    // at run with "op_ns_with_filter index out of range".
    const exclude = [_][]const u8{"map"};
    const only = [_][]const u8{"inc"};
    var filters = [_]NsFilterEntry{.{ .name = "a", .exclude = &exclude, .only = &only }};
    const instrs = [_]WireInstr{.from(.op_ns_with_filter, 0)};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &.{}, .ns_filters = &filters };

    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1743: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1743, testing.allocator);
    defer root_set.endAnalysis(&af_1743);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, round);

    try testing.expectEqual(@as(usize, 1), round.ns_filters.len);
    try testing.expectEqualStrings("a", round.ns_filters[0].name);
    try testing.expectEqual(@as(usize, 1), round.ns_filters[0].exclude.len);
    try testing.expectEqualStrings("map", round.ns_filters[0].exclude[0]);
    try testing.expect(round.ns_filters[0].only != null);
    try testing.expectEqualStrings("inc", round.ns_filters[0].only.?[0]);
}

test "round-trips ns_filters with no :only (null) — bare (ns x (:require …))" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    var filters = [_]NsFilterEntry{.{ .name = "mylib.greet" }};
    const chunk: BytecodeChunk = .{ .instructions = &.{}, .constants = &.{}, .ns_filters = &filters };
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1765: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1765, testing.allocator);
    defer root_set.endAnalysis(&af_1765);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 1), round.ns_filters.len);
    try testing.expectEqualStrings("mylib.greet", round.ns_filters[0].name);
    try testing.expectEqual(@as(usize, 0), round.ns_filters[0].exclude.len);
    try testing.expect(round.ns_filters[0].only == null);
    try testing.expect(round.ns_filters[0].doc == null);
    try testing.expect(round.ns_filters[0].refer_clojure);
    try testing.expectEqual(NsFilterEntry.NO_ATTR, round.ns_filters[0].attr_const);
}

test "round-trips instructions" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const instrs = [_]WireInstr{
        .from(.op_const, 42),
        .from(.op_ret, 0),
    };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &.{} };
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1787: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1787, testing.allocator);
    defer root_set.endAnalysis(&af_1787);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
    defer freeChunk(testing.allocator, round);
    try testing.expectEqual(@as(usize, 2), round.instructions.len);
    try testing.expectEqual(Opcode.op_const, round.instructions[0].op());
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1812: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1812, testing.allocator);
    defer root_set.endAnalysis(&af_1812);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1835: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1835, testing.allocator);
    defer root_set.endAnalysis(&af_1835);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1854: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1854, testing.allocator);
    defer root_set.endAnalysis(&af_1854);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1882: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1882, testing.allocator);
    defer root_set.endAnalysis(&af_1882);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1905: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1905, testing.allocator);
    defer root_set.endAnalysis(&af_1905);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    const bytes = try serializeChunk(testing.allocator, chunk, 0, null);
    defer testing.allocator.free(bytes);
    var af_1928: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1928, testing.allocator);
    defer root_set.endAnalysis(&af_1928);
    const round = try deserializeChunk(testing.allocator, &rt, &env, bytes, null, false);
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
    var af_1946: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1946, testing.allocator);
    defer root_set.endAnalysis(&af_1946);
    try testing.expectError(DeserializeError.BadMagic, deserializeChunk(testing.allocator, &rt, &env, &bytes, null, false));
}

test "unsupported version rejected with UnsupportedVersion" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();
    const bytes = [_]u8{ 'C', 'L', 'J', 'W', 99, 0, 0, 0, 0, 0 };
    var af_1957: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af_1957, testing.allocator);
    defer root_set.endAnalysis(&af_1957);
    try testing.expectError(DeserializeError.UnsupportedVersion, deserializeChunk(testing.allocator, &rt, &env, &bytes, null, false));
}

test "v7 pool: duplicated interned-name constants dedupe and round-trip (blob level)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    // Two chunks sharing the same keyword + symbol constants — poolable tags.
    const kw = try @import("../../runtime/keyword.zig").intern(&rt, null, "shared-kw");
    const sym = try @import("../../runtime/symbol.zig").intern(&rt, null, "shared-sym");
    const consts = [_]Value{ kw, sym };
    const instrs = [_]WireInstr{ .from(.op_const, 0), .from(.op_ret, 0) };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &consts };

    var pb: PoolBuilder = .{};
    defer pb.deinit(testing.allocator);
    const env_a = try serializeEnvelope(testing.allocator, &.{chunk}, null, &.{}, &pb, false);
    defer testing.allocator.free(env_a);
    const env_b = try serializeEnvelope(testing.allocator, &.{chunk}, null, &.{}, &pb, false);
    defer testing.allocator.free(env_b);
    // 2 chunks x 2 poolable constants -> only 2 unique pool entries.
    try testing.expectEqual(@as(usize, 2), pb.entries.items.len);

    const blob = try serializeRegions(testing.allocator, &.{
        .{ .ns_name = "a", .envelope = env_a },
        .{ .ns_name = "b", .envelope = env_b },
    }, pb.entries.items);
    defer testing.allocator.free(blob);

    var pool = (try readBlobPool(testing.allocator, blob)) orelse return error.TestUnexpectedResult;
    defer pool.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), pool.entries.len);

    // Deserialize region b's chunk through the pool: constants resolve to
    // the SAME interned keyword/symbol (interning gives identity).
    const region_b = findRegion(blob, "b") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(false, region_b.compressed);
    var it = try EnvelopeIterator.init(region_b.bytes);
    const cb = (try it.next()) orelse return error.TestUnexpectedResult;
    var af: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af, testing.allocator);
    defer root_set.endAnalysis(&af);
    const out = try deserializeChunk(testing.allocator, &rt, &env, cb, &pool, false);
    defer freeChunk(testing.allocator, out);
    try testing.expectEqual(kw, out.constants[0]);
    try testing.expectEqual(sym, out.constants[1]);
}

test "v7 alignment: every instr section sits 4B-aligned relative to the envelope" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    _ = &rt;

    // Odd-length source_file labels force non-trivial padding.
    const instrs = [_]WireInstr{ .from(.op_const, 0), .from(.op_ret, 0) };
    const consts = [_]Value{Value.nil_val};
    const chunk_a: BytecodeChunk = .{ .instructions = &instrs, .constants = &consts, .source_file = "a.clj" };
    const chunk_b: BytecodeChunk = .{ .instructions = &instrs, .constants = &consts, .source_file = "longer_name.clj" };

    const bytes = try serializeEnvelope(testing.allocator, &.{ chunk_a, chunk_b }, null, &.{}, null, false);
    defer testing.allocator.free(bytes);

    // Walk the envelope; for each chunk, re-derive the instr-array offset
    // (magic 4 + ver 2 + sf(4+len) + has_handlers 1 + pad_count 1 + pad +
    // count 4) and assert it is 0 (mod 4) from the ENVELOPE start.
    var it = try EnvelopeIterator.init(bytes);
    while (true) {
        const before = it.r.pos; // position of the u32 len prefix
        const cb = (try it.next()) orelse break;
        const chunk_base = before + 4;
        var r: ByteReader = .{ .bytes = cb, .pos = 4 + 2 };
        const sf = try r.readLenPrefixed();
        _ = sf;
        _ = try r.readU8(); // has_handlers
        const pad = try r.readU8();
        r.pos += pad;
        const instr_off = chunk_base + r.pos + 4; // + count u32
        try testing.expectEqual(@as(usize, 0), instr_off % 4);
    }
}

test "C5': compressed lazy region round-trips through flateCompress/decompressRegion" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try @import("../../runtime/env.zig").Env.init(&rt);
    defer env.deinit();

    const instrs = [_]WireInstr{ .from(.op_const, 0), .from(.op_ret, 0) };
    const consts = [_]Value{Value.initInteger(7)};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &consts };
    const env_raw = try serializeEnvelope(testing.allocator, &.{chunk}, null, &.{}, null, false);
    defer testing.allocator.free(env_raw);

    const blob = try serializeRegions(testing.allocator, &.{
        .{ .ns_name = "lazy.ns", .envelope = env_raw, .compress = true },
    }, &.{});
    defer testing.allocator.free(blob);

    const ref = findRegion(blob, "lazy.ns") orelse return error.TestUnexpectedResult;
    try testing.expect(ref.compressed);
    try testing.expect(ref.bytes.len < env_raw.len); // it actually shrank
    try testing.expectEqual(@as(u32, @intCast(env_raw.len)), ref.uncompressed_len);

    const restored = try decompressRegion(testing.allocator, ref);
    const restored_owned: []align(8) const u8 = @alignCast(restored);
    defer testing.allocator.free(restored_owned);
    try testing.expectEqualSlices(u8, env_raw, restored);

    var af: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af, testing.allocator);
    defer root_set.endAnalysis(&af);
    const chunks = try deserializeEnvelope(testing.allocator, &rt, &env, restored);
    defer freeEnvelope(testing.allocator, chunks);
    try testing.expectEqual(@as(i64, 7), chunks[0].constants[0].asInteger());
}
