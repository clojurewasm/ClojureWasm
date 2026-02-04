// I/O builtins — print, println, pr, prn, newline, flush
//
// println: Print args space-separated, non-readable, with trailing newline. Returns nil.
// prn: Print args space-separated, readable, with trailing newline. Returns nil.
//
// Output goes to stdout by default. Tests can redirect via setOutputCapture().

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;

// ============================================================
// Output capture for testing
// ============================================================

var capture_buf: ?*std.ArrayListUnmanaged(u8) = null;
var capture_alloc: ?Allocator = null;

/// Set an output capture buffer. Pass null to restore stdout.
pub fn setOutputCapture(alloc: ?Allocator, buf: ?*std.ArrayListUnmanaged(u8)) void {
    capture_buf = buf;
    capture_alloc = alloc;
}

fn writeOutput(data: []const u8) void {
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

fn writeOutputByte(byte: u8) void {
    writeOutput(&[_]u8{byte});
}

// ============================================================
// Builtins
// ============================================================

/// (println) => nil (prints newline)
/// (println x) => nil (prints x + newline)
/// (println x y ...) => nil (prints space-separated + newline, non-readable)
pub fn printlnFn(_: Allocator, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return .nil;
}

/// (prn) => nil (prints newline)
/// (prn x) => nil (prints readable x + newline)
/// (prn x y ...) => nil (prints space-separated readable + newline)
pub fn prnFn(_: Allocator, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return .nil;
}

/// (print) => nil (prints nothing)
/// (print x) => nil (prints x, no newline)
/// (print x y ...) => nil (prints space-separated, non-readable, no newline)
pub fn printFn(_: Allocator, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return .nil;
}

/// (pr) => nil (prints nothing)
/// (pr x) => nil (prints readable x, no newline)
/// (pr x y ...) => nil (prints space-separated readable, no newline)
pub fn prFn(_: Allocator, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return .nil;
}

/// (newline) => nil (prints newline character)
pub fn newlineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    writeOutputByte('\n');
    return .nil;
}

/// (flush) => nil (flushes stdout)
pub fn flushFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    if (capture_buf == null) {
        var wbuf: [4096]u8 = undefined;
        var file_writer = std.fs.File.stdout().writer(&wbuf);
        file_writer.interface.flush() catch {};
    }
    return .nil;
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
};

// === Tests ===

const testing = std.testing;

fn capturedOutput(buf: *std.ArrayListUnmanaged(u8), comptime f: fn (Allocator, []const Value) anyerror!Value, args: []const Value) ![]const u8 {
    buf.clearRetainingCapacity();
    setOutputCapture(testing.allocator, buf);
    defer setOutputCapture(null, null);
    _ = try f(testing.allocator, args);
    return buf.items;
}

test "println - no args prints newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(&buf, printlnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "println - single string unquoted" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{.{ .string = "hello" }};
    const output = try capturedOutput(&buf, printlnFn, &args);
    try testing.expectEqualStrings("hello\n", output);
}

test "println - multi-arg space separated" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
        .nil,
    };
    const output = try capturedOutput(&buf, printlnFn, &args);
    try testing.expectEqualStrings("1 hello \n", output);
}

test "println - returns nil" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{.{ .integer = 1 }};
    const result = try printlnFn(testing.allocator, &args);
    try testing.expect(result == .nil);
}

test "prn - no args prints newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(&buf, prnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "prn - string is quoted" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{.{ .string = "hello" }};
    const output = try capturedOutput(&buf, prnFn, &args);
    try testing.expectEqualStrings("\"hello\"\n", output);
}

test "prn - multi-arg space separated readable" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
        .nil,
    };
    const output = try capturedOutput(&buf, prnFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil\n", output);
}

test "prn - returns nil" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{.{ .integer = 1 }};
    const result = try prnFn(testing.allocator, &args);
    try testing.expect(result == .nil);
}

// === print tests ===

test "print - no args prints nothing" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(&buf, printFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "print - single string unquoted no newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{.{ .string = "hello" }};
    const output = try capturedOutput(&buf, printFn, &args);
    try testing.expectEqualStrings("hello", output);
}

test "print - multi-arg space separated no newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
        .nil,
    };
    const output = try capturedOutput(&buf, printFn, &args);
    try testing.expectEqualStrings("1 hello ", output);
}

// === pr tests ===

test "pr - no args prints nothing" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(&buf, prFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "pr - string is quoted no newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{.{ .string = "hello" }};
    const output = try capturedOutput(&buf, prFn, &args);
    try testing.expectEqualStrings("\"hello\"", output);
}

test "pr - multi-arg space separated readable no newline" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
        .nil,
    };
    const output = try capturedOutput(&buf, prFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil", output);
}

// === newline tests ===

test "newline - prints newline character" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(&buf, newlineFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "newline - rejects args" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{.{ .integer = 1 }};
    const result = newlineFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

// === flush tests ===

test "flush - returns nil" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const result = try flushFn(testing.allocator, &.{});
    try testing.expect(result == .nil);
}

test "flush - rejects args" {
    const args = [_]Value{.{ .integer = 1 }};
    const result = flushFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}
