// Chunked sequence builtins — chunk-buffer, chunk-append, chunk, chunk-first, chunk-next, chunk-rest, chunked-seq?
//
// Chunked sequences are an optimization for lazy seq processing.
// A ChunkBuffer is a mutable builder, finalized via (chunk buf) into an ArrayChunk.
// ChunkedCons is the seq type: first-chunk + rest-seq.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ArrayChunk = value_mod.ArrayChunk;
const ChunkBuffer = value_mod.ChunkBuffer;
const ChunkedCons = value_mod.ChunkedCons;
const PersistentList = value_mod.PersistentList;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");

// ============================================================
// Implementations
// ============================================================

/// (chunk-buffer n) — create a new ChunkBuffer with capacity n.
fn chunkBufferFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-buffer", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-buffer expects integer capacity, got {s}", .{@tagName(args[0].tag())}),
    };
    if (n < 0) return err.setErrorFmt(.eval, .value_error, .{}, "chunk-buffer capacity must be non-negative", .{});
    const cb = try ChunkBuffer.initWithCapacity(allocator, @intCast(n));
    return Value.initChunkBuffer(cb);
}

/// (chunk-append buf val) — append val to ChunkBuffer. Returns nil.
fn chunkAppendFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-append", .{args.len});
    const cb = switch (args[0].tag()) {
        .chunk_buffer => args[0].asChunkBuffer(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-append expects ChunkBuffer, got {s}", .{@tagName(args[0].tag())}),
    };
    cb.add(allocator, args[1]) catch |e| {
        return switch (e) {
            error.ChunkBufferConsumed => err.setErrorFmt(.eval, .value_error, .{}, "ChunkBuffer already consumed", .{}),
            else => e,
        };
    };
    return Value.nil_val;
}

/// (chunk buf) — finalize ChunkBuffer into an ArrayChunk.
fn chunkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk", .{args.len});
    const cb = switch (args[0].tag()) {
        .chunk_buffer => args[0].asChunkBuffer(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk expects ChunkBuffer, got {s}", .{@tagName(args[0].tag())}),
    };
    const ac = cb.toChunk(allocator) catch |e| {
        return switch (e) {
            error.ChunkBufferConsumed => err.setErrorFmt(.eval, .value_error, .{}, "ChunkBuffer already consumed", .{}),
            else => e,
        };
    };
    return Value.initArrayChunk(ac);
}

/// (chunk-first s) — return the first ArrayChunk from a chunked seq.
fn chunkFirstFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-first", .{args.len});
    return switch (args[0].tag()) {
        .chunked_cons => Value.initArrayChunk(args[0].asChunkedCons().chunk),
        else => err.setErrorFmt(.eval, .type_error, .{}, "chunk-first expects chunked seq, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (chunk-next s) — return the seq after the first chunk, or nil.
fn chunkNextFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-next", .{args.len});
    const cc = switch (args[0].tag()) {
        .chunked_cons => args[0].asChunkedCons(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-next expects chunked seq, got {s}", .{@tagName(args[0].tag())}),
    };
    // Call seq on the rest to return nil for empty
    const collections_mod = @import("collections.zig");
    const rest_args = [1]Value{cc.more};
    return collections_mod.seqFn(allocator, &rest_args);
}

/// (chunk-rest s) — return the rest after the first chunk, or empty list.
fn chunkRestFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-rest", .{args.len});
    const cc = switch (args[0].tag()) {
        .chunked_cons => args[0].asChunkedCons(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-rest expects chunked seq, got {s}", .{@tagName(args[0].tag())}),
    };
    if (cc.more.isNil()) {
        const empty = try allocator.create(PersistentList);
        empty.* = .{ .items = &.{} };
        return Value.initList(empty);
    }
    return cc.more;
}

/// (chunked-seq? s) — true if s is a ChunkedCons.
fn chunkedSeqPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunked-seq?", .{args.len});
    return Value.initBoolean(args[0].tag() == .chunked_cons);
}

/// (chunk-cons chunk rest) — create a ChunkedCons from ArrayChunk + rest seq.
/// If chunk is empty, returns rest directly.
fn chunkConsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-cons", .{args.len});
    const ac = switch (args[0].tag()) {
        .array_chunk => args[0].asArrayChunk(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-cons expects ArrayChunk as first arg, got {s}", .{@tagName(args[0].tag())}),
    };
    // If chunk is empty, return rest directly
    if (ac.count() == 0) return args[1];
    const cc = try allocator.create(ChunkedCons);
    cc.* = .{ .chunk = ac, .more = args[1] };
    return Value.initChunkedCons(cc);
}

// ============================================================
// Builtin table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "chunk-buffer", .func = chunkBufferFn, .doc = "Creates a chunk buffer of capacity n.", .arglists = "([n])" },
    .{ .name = "chunk-append", .func = chunkAppendFn, .doc = "Appends val to chunk buffer.", .arglists = "([b x])" },
    .{ .name = "chunk", .func = chunkFn, .doc = "Finalizes a chunk buffer into a chunk.", .arglists = "([b])" },
    .{ .name = "chunk-first", .func = chunkFirstFn, .doc = "Returns the first chunk of a chunked seq.", .arglists = "([s])" },
    .{ .name = "chunk-next", .func = chunkNextFn, .doc = "Returns seq after the first chunk, or nil.", .arglists = "([s])" },
    .{ .name = "chunk-rest", .func = chunkRestFn, .doc = "Returns rest after the first chunk, or ().", .arglists = "([s])" },
    .{ .name = "chunked-seq?", .func = chunkedSeqPred, .doc = "Returns true if seq is chunked.", .arglists = "([s])" },
    .{ .name = "chunk-cons", .func = chunkConsFn, .doc = "Creates a chunked seq from chunk and rest.", .arglists = "([chunk rest])" },
};

// ============================================================
// Tests
// ============================================================

test "chunk-buffer -> chunk-append -> chunk lifecycle" {
    const allocator = std.testing.allocator;

    // Create chunk-buffer of capacity 3
    const buf_val = try chunkBufferFn(allocator, &.{Value.initInteger(3)});
    try std.testing.expect(buf_val.tag() == .chunk_buffer);

    // Append 3 values
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value.initInteger(10) });
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value.initInteger(20) });
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value.initInteger(30) });

    // Finalize
    const chunk_val = try chunkFn(allocator, &.{buf_val});
    try std.testing.expect(chunk_val.tag() == .array_chunk);
    try std.testing.expectEqual(@as(usize, 3), chunk_val.asArrayChunk().count());

    // Verify elements
    try std.testing.expectEqual(@as(i64, 10), chunk_val.asArrayChunk().nth(0).?.asInteger());
    try std.testing.expectEqual(@as(i64, 20), chunk_val.asArrayChunk().nth(1).?.asInteger());
    try std.testing.expectEqual(@as(i64, 30), chunk_val.asArrayChunk().nth(2).?.asInteger());

    // Second finalize should fail
    try std.testing.expectError(error.ValueError, chunkFn(allocator, &.{buf_val}));

    // Cleanup
    allocator.free(chunk_val.asArrayChunk().array);
    allocator.destroy(@constCast(chunk_val.asArrayChunk()));
    buf_val.asChunkBuffer().items.deinit(allocator);
    allocator.destroy(buf_val.asChunkBuffer());
}

test "chunk-first/chunk-next/chunk-rest on ChunkedCons" {
    const allocator = std.testing.allocator;

    // Create ArrayChunk with [1 2 3]
    const items = try allocator.alloc(Value, 3);
    items[0] = Value.initInteger(1);
    items[1] = Value.initInteger(2);
    items[2] = Value.initInteger(3);
    const ac = try allocator.create(ArrayChunk);
    ac.* = ArrayChunk.initFull(items);

    // Create ChunkedCons with chunk=[1 2 3], rest=nil
    const cc = try allocator.create(ChunkedCons);
    cc.* = .{ .chunk = ac, .more = Value.nil_val };
    const cc_val = Value.initChunkedCons(cc);

    // chunk-first returns the ArrayChunk
    const cf = try chunkFirstFn(allocator, &.{cc_val});
    try std.testing.expect(cf.tag() == .array_chunk);
    try std.testing.expectEqual(@as(usize, 3), cf.asArrayChunk().count());

    // chunk-next returns nil (no more)
    const cn = try chunkNextFn(allocator, &.{cc_val});
    try std.testing.expect(cn.isNil());

    // chunk-rest returns empty list
    const cr = try chunkRestFn(allocator, &.{cc_val});
    try std.testing.expect(cr.tag() == .list);
    try std.testing.expectEqual(@as(usize, 0), cr.asList().count());

    // chunked-seq? returns true
    const csp = try chunkedSeqPred(allocator, &.{cc_val});
    try std.testing.expectEqual(true, csp.asBoolean());

    // chunked-seq? returns false for non-chunked
    const nsp = try chunkedSeqPred(allocator, &.{Value.initInteger(42)});
    try std.testing.expectEqual(false, nsp.asBoolean());

    // Cleanup
    allocator.destroy(@constCast(cr.asList()));
    allocator.destroy(cc);
    allocator.free(items);
    allocator.destroy(@constCast(ac));
}
