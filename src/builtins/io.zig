// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// I/O builtins — print, println, pr, prn, newline, flush
//
// println: Print args space-separated, non-readable, with trailing newline. Returns nil.
// prn: Print args space-separated, readable, with trailing newline. Returns nil.
//
// Output goes to stdout by default. Tests can redirect via setOutputCapture().

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;
const collections = @import("collections.zig");
const err = @import("../runtime/error.zig");

// ============================================================
// Output capture for testing
// ============================================================

var capture_buf: ?*std.ArrayList(u8) = null;
var capture_alloc: ?Allocator = null;

/// Set an output capture buffer. Pass null to restore stdout.
pub fn setOutputCapture(alloc: ?Allocator, buf: ?*std.ArrayList(u8)) void {
    capture_buf = buf;
    capture_alloc = alloc;
}

pub fn writeOutput(data: []const u8) void {
    if (capture_buf) |buf| {
        buf.appendSlice(capture_alloc.?, data) catch {};
    } else {
        var wbuf: [4096]u8 = undefined;
        var file_writer = std.fs.File.stdout().writer(&wbuf);
        const w = &file_writer.interface;
        w.writeAll(data) catch {};
        w.flush() catch {};
    }
}

pub fn writeOutputByte(byte: u8) void {
    writeOutput(&[_]u8{byte});
}

// ============================================================
// Builtins
// ============================================================

/// (println) => nil (prints newline)
/// (println x) => nil (prints x + newline)
/// (println x y ...) => nil (prints space-separated + newline, non-readable)
pub fn printlnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        const v = collections.realizeValue(allocator, arg) catch arg;
        v.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (prn) => nil (prints newline)
/// (prn x) => nil (prints readable x + newline)
/// (prn x y ...) => nil (prints space-separated readable + newline)
pub fn prnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        const v = collections.realizeValue(allocator, arg) catch arg;
        v.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (print) => nil (prints nothing)
/// (print x) => nil (prints x, no newline)
/// (print x y ...) => nil (prints space-separated, non-readable, no newline)
pub fn printFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        const v = collections.realizeValue(allocator, arg) catch arg;
        v.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return Value.nil_val;
}

/// (pr) => nil (prints nothing)
/// (pr x) => nil (prints readable x, no newline)
/// (pr x y ...) => nil (prints space-separated readable, no newline)
pub fn prFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        const v = collections.realizeValue(allocator, arg) catch arg;
        v.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return Value.nil_val;
}

/// (newline) => nil (prints newline character)
pub fn newlineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to newline", .{args.len});
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (flush) => nil (flushes stdout)
pub fn flushFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to flush", .{args.len});
    if (capture_buf == null) {
        var wbuf: [4096]u8 = undefined;
        var file_writer = std.fs.File.stdout().writer(&wbuf);
        file_writer.interface.flush() catch {};
    }
    return Value.nil_val;
}

// ============================================================
// Output capture stack for with-out-str nesting
// ============================================================

const MAX_CAPTURE_DEPTH = 16;
const CaptureState = struct {
    buf: ?*std.ArrayList(u8),
    alloc: ?Allocator,
};

var capture_stack: [MAX_CAPTURE_DEPTH]CaptureState = [_]CaptureState{.{ .buf = null, .alloc = null }} ** MAX_CAPTURE_DEPTH;
var capture_depth: usize = 0;

/// (push-output-capture) — start capturing output to a fresh buffer.
fn pushOutputCaptureFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to push-output-capture", .{args.len});
    if (capture_depth >= MAX_CAPTURE_DEPTH) return err.setErrorFmt(.eval, .value_error, .{}, "Output capture stack overflow", .{});

    // Save current state
    capture_stack[capture_depth] = .{ .buf = capture_buf, .alloc = capture_alloc };
    capture_depth += 1;

    // Create new capture buffer
    const buf = allocator.create(std.ArrayList(u8)) catch return error.OutOfMemory;
    buf.* = .empty;
    setOutputCapture(allocator, buf);

    return Value.nil_val;
}

/// (pop-output-capture) — stop capturing, restore previous state, return captured string.
fn popOutputCaptureFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop-output-capture", .{args.len});
    if (capture_depth == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Output capture stack underflow", .{});

    // Get captured string
    const result: Value = if (capture_buf) |buf| blk: {
        const str = allocator.dupe(u8, buf.items) catch return error.OutOfMemory;
        buf.deinit(capture_alloc.?);
        break :blk Value.initString(allocator, str);
    } else Value.initString(allocator, "");

    // Restore previous state
    capture_depth -= 1;
    setOutputCapture(capture_stack[capture_depth].alloc, capture_stack[capture_depth].buf);

    return result;
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "print",
        .func = &printFn,
        .doc = "Prints the object(s) to the output stream. print and println produce output for human consumption.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "println",
        .func = &printlnFn,
        .doc = "Same as print followed by (newline).",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "pr",
        .func = &prFn,
        .doc = "Prints the object(s) to the output stream. Prints the object(s), separated by spaces if there is more than one. Objects are printed via the pr-str function.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "prn",
        .func = &prnFn,
        .doc = "Same as pr followed by (newline). Observes *print-readably*.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "newline",
        .func = &newlineFn,
        .doc = "Writes a platform-specific newline to *out*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "flush",
        .func = &flushFn,
        .doc = "Flushes the output stream that is the current value of *out*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "push-output-capture",
        .func = &pushOutputCaptureFn,
        .doc = "Start capturing output. Used internally by with-out-str.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "pop-output-capture",
        .func = &popOutputCaptureFn,
        .doc = "Stop capturing output, return captured string. Used internally by with-out-str.",
        .arglists = "([])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

fn capturedOutput(alloc: Allocator, buf: *std.ArrayList(u8), comptime f: fn (Allocator, []const Value) anyerror!Value, args: []const Value) ![]const u8 {
    buf.clearRetainingCapacity();
    setOutputCapture(alloc, buf);
    defer setOutputCapture(null, null);
    _ = try f(alloc, args);
    return buf.items;
}

test "println - no args prints newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, printlnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "println - single string unquoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, printlnFn, &args);
    try testing.expectEqualStrings("hello\n", output);
}

test "println - multi-arg space separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, printlnFn, &args);
    try testing.expectEqualStrings("1 hello \n", output);
}

test "println - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = try printlnFn(testing.allocator, &args);
    try testing.expect(result.isNil());
}

test "prn - no args prints newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, prnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "prn - string is quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, prnFn, &args);
    try testing.expectEqualStrings("\"hello\"\n", output);
}

test "prn - multi-arg space separated readable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, prnFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil\n", output);
}

test "prn - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = try prnFn(testing.allocator, &args);
    try testing.expect(result.isNil());
}

// === print tests ===

test "print - no args prints nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, printFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "print - single string unquoted no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, printFn, &args);
    try testing.expectEqualStrings("hello", output);
}

test "print - multi-arg space separated no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, printFn, &args);
    try testing.expectEqualStrings("1 hello ", output);
}

// === pr tests ===

test "pr - no args prints nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, prFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "pr - string is quoted no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, prFn, &args);
    try testing.expectEqualStrings("\"hello\"", output);
}

test "pr - multi-arg space separated readable no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, prFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil", output);
}

// === newline tests ===

test "newline - prints newline character" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, newlineFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "newline - rejects args" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = newlineFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

// === flush tests ===

test "flush - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const result = try flushFn(testing.allocator, &.{});
    try testing.expect(result.isNil());
}

test "flush - rejects args" {
    const args = [_]Value{Value.initInteger(1)};
    const result = flushFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}
