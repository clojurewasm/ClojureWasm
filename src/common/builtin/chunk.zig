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
    const n = switch (args[0]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-buffer expects integer capacity, got {s}", .{@tagName(args[0])}),
    };
    if (n < 0) return err.setErrorFmt(.eval, .value_error, .{}, "chunk-buffer capacity must be non-negative", .{});
    const cb = try ChunkBuffer.initWithCapacity(allocator, @intCast(n));
    return Value{ .chunk_buffer = cb };
}

/// (chunk-append buf val) — append val to ChunkBuffer. Returns nil.
fn chunkAppendFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-append", .{args.len});
    const cb = switch (args[0]) {
        .chunk_buffer => |b| b,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-append expects ChunkBuffer, got {s}", .{@tagName(args[0])}),
    };
    cb.add(allocator, args[1]) catch |e| {
        return switch (e) {
            error.ChunkBufferConsumed => err.setErrorFmt(.eval, .value_error, .{}, "ChunkBuffer already consumed", .{}),
            else => e,
        };
    };
    return .nil;
}

/// (chunk buf) — finalize ChunkBuffer into an ArrayChunk.
fn chunkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk", .{args.len});
    const cb = switch (args[0]) {
        .chunk_buffer => |b| b,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk expects ChunkBuffer, got {s}", .{@tagName(args[0])}),
    };
    const ac = cb.toChunk(allocator) catch |e| {
        return switch (e) {
            error.ChunkBufferConsumed => err.setErrorFmt(.eval, .value_error, .{}, "ChunkBuffer already consumed", .{}),
            else => e,
        };
    };
    return Value{ .array_chunk = ac };
}

/// (chunk-first s) — return the first ArrayChunk from a chunked seq.
fn chunkFirstFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-first", .{args.len});
    return switch (args[0]) {
        .chunked_cons => |cc| Value{ .array_chunk = cc.chunk },
        else => err.setErrorFmt(.eval, .type_error, .{}, "chunk-first expects chunked seq, got {s}", .{@tagName(args[0])}),
    };
}

/// (chunk-next s) — return the seq after the first chunk, or nil.
fn chunkNextFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-next", .{args.len});
    const cc = switch (args[0]) {
        .chunked_cons => |c| c,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-next expects chunked seq, got {s}", .{@tagName(args[0])}),
    };
    // Call seq on the rest to return nil for empty
    const collections_mod = @import("collections.zig");
    const rest_args = [1]Value{cc.more};
    return collections_mod.seqFn(allocator, &rest_args);
}

/// (chunk-rest s) — return the rest after the first chunk, or empty list.
fn chunkRestFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-rest", .{args.len});
    const cc = switch (args[0]) {
        .chunked_cons => |c| c,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-rest expects chunked seq, got {s}", .{@tagName(args[0])}),
    };
    if (cc.more == .nil) {
        const empty = try allocator.create(PersistentList);
        empty.* = .{ .items = &.{} };
        return Value{ .list = empty };
    }
    return cc.more;
}

/// (chunked-seq? s) — true if s is a ChunkedCons.
fn chunkedSeqPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunked-seq?", .{args.len});
    return Value{ .boolean = args[0] == .chunked_cons };
}

/// (chunk-cons chunk rest) — create a ChunkedCons from ArrayChunk + rest seq.
/// If chunk is empty, returns rest directly.
fn chunkConsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to chunk-cons", .{args.len});
    const ac = switch (args[0]) {
        .array_chunk => |c| c,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "chunk-cons expects ArrayChunk as first arg, got {s}", .{@tagName(args[0])}),
    };
    // If chunk is empty, return rest directly
    if (ac.count() == 0) return args[1];
    const cc = try allocator.create(ChunkedCons);
    cc.* = .{ .chunk = ac, .more = args[1] };
    return Value{ .chunked_cons = cc };
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
    const buf_val = try chunkBufferFn(allocator, &.{Value{ .integer = 3 }});
    try std.testing.expect(buf_val == .chunk_buffer);

    // Append 3 values
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value{ .integer = 10 } });
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value{ .integer = 20 } });
    _ = try chunkAppendFn(allocator, &.{ buf_val, Value{ .integer = 30 } });

    // Finalize
    const chunk_val = try chunkFn(allocator, &.{buf_val});
    try std.testing.expect(chunk_val == .array_chunk);
    try std.testing.expectEqual(@as(usize, 3), chunk_val.array_chunk.count());

    // Verify elements
    try std.testing.expectEqual(@as(i64, 10), chunk_val.array_chunk.nth(0).?.integer);
    try std.testing.expectEqual(@as(i64, 20), chunk_val.array_chunk.nth(1).?.integer);
    try std.testing.expectEqual(@as(i64, 30), chunk_val.array_chunk.nth(2).?.integer);

    // Second finalize should fail
    try std.testing.expectError(error.ValueError, chunkFn(allocator, &.{buf_val}));

    // Cleanup
    allocator.free(chunk_val.array_chunk.array);
    allocator.destroy(@constCast(chunk_val.array_chunk));
    buf_val.chunk_buffer.items.deinit(allocator);
    allocator.destroy(buf_val.chunk_buffer);
}

test "chunk-first/chunk-next/chunk-rest on ChunkedCons" {
    const allocator = std.testing.allocator;

    // Create ArrayChunk with [1 2 3]
    const items = try allocator.alloc(Value, 3);
    items[0] = Value{ .integer = 1 };
    items[1] = Value{ .integer = 2 };
    items[2] = Value{ .integer = 3 };
    const ac = try allocator.create(ArrayChunk);
    ac.* = ArrayChunk.initFull(items);

    // Create ChunkedCons with chunk=[1 2 3], rest=nil
    const cc = try allocator.create(ChunkedCons);
    cc.* = .{ .chunk = ac, .more = .nil };
    const cc_val = Value{ .chunked_cons = cc };

    // chunk-first returns the ArrayChunk
    const cf = try chunkFirstFn(allocator, &.{cc_val});
    try std.testing.expect(cf == .array_chunk);
    try std.testing.expectEqual(@as(usize, 3), cf.array_chunk.count());

    // chunk-next returns nil (no more)
    const cn = try chunkNextFn(allocator, &.{cc_val});
    try std.testing.expect(cn == .nil);

    // chunk-rest returns empty list
    const cr = try chunkRestFn(allocator, &.{cc_val});
    try std.testing.expect(cr == .list);
    try std.testing.expectEqual(@as(usize, 0), cr.list.count());

    // chunked-seq? returns true
    const csp = try chunkedSeqPred(allocator, &.{cc_val});
    try std.testing.expectEqual(true, csp.boolean);

    // chunked-seq? returns false for non-chunked
    const nsp = try chunkedSeqPred(allocator, &.{Value{ .integer = 42 }});
    try std.testing.expectEqual(false, nsp.boolean);

    // Cleanup
    allocator.destroy(@constCast(cr.list));
    allocator.destroy(cc);
    allocator.free(items);
    allocator.destroy(@constCast(ac));
}
