// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// File I/O builtins — slurp, spit
//
// slurp: Read entire file content as a string.
// spit: Write string content to a file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");
const bootstrap = @import("../bootstrap.zig");

// ============================================================
// Builtins
// ============================================================

/// (slurp filename) => string
/// Opens the file, reads all content as UTF-8 string, closes the file.
pub fn slurpFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to slurp", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "slurp expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.IOError;
    return Value.initString(allocator, content);
}

/// (spit filename content) => nil
/// (spit filename content :append true) => nil
/// Writes content to the file. Creates if not exists, truncates by default.
pub fn spitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to spit", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "spit expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    // Get content as string
    const content = switch (args[1].tag()) {
        .string => args[1].asString(),
        .nil => "",
        else => blk: {
            // Convert to string via formatStr
            var buf: [4096]u8 = undefined;
            const Writer = std.Io.Writer;
            var w: Writer = .fixed(&buf);
            args[1].formatStr(&w) catch break :blk @as([]const u8, "");
            const result = w.buffered();
            const owned = allocator.alloc(u8, result.len) catch break :blk @as([]const u8, "");
            @memcpy(owned, result);
            break :blk @as([]const u8, owned);
        },
    };

    // Check for :append true option
    var append = false;
    if (args.len >= 4) {
        if (args[2].tag() == .keyword) {
            if (std.mem.eql(u8, args[2].asKeyword().name, "append")) {
                if (args[3].tag() == .boolean) {
                    append = args[3].asBoolean();
                }
            }
        }
    }

    const cwd = std.fs.cwd();
    if (append) {
        const file = cwd.openFile(path, .{ .mode = .write_only }) catch {
            // File doesn't exist, create it
            const new_file = cwd.createFile(path, .{}) catch return error.IOError;
            defer new_file.close();
            new_file.writeAll(content) catch return error.IOError;
            return Value.nil_val;
        };
        defer file.close();
        file.seekFromEnd(0) catch return error.IOError;
        file.writeAll(content) catch return error.IOError;
    } else {
        const file = cwd.createFile(path, .{}) catch return error.IOError;
        defer file.close();
        file.writeAll(content) catch return error.IOError;
    }

    return Value.nil_val;
}

/// (read-line) => string or nil
/// Reads a line from stdin. Returns nil on EOF.
pub fn readLineFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read-line", .{args.len});

    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch return Value.nil_val;
        if (n == 0) {
            // EOF
            if (pos > 0) break;
            return Value.nil_val;
        }
        if (byte[0] == '\n') break;
        buf[pos] = byte[0];
        pos += 1;
    }

    // Strip trailing \r (Windows line endings)
    if (pos > 0 and buf[pos - 1] == '\r') pos -= 1;

    const owned = try allocator.alloc(u8, pos);
    @memcpy(owned, buf[0..pos]);
    return Value.initString(allocator, owned);
}

// ============================================================
// load-file
// ============================================================

/// (load-file path) => value
/// Reads and evaluates all forms in the file at the given path.
/// Returns the value of the last form.
pub fn loadFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to load-file", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "load-file expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    // Read file content
    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "Could not open file: {s}", .{path});
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "Could not read file: {s}", .{path});

    // Evaluate all forms using bootstrap pipeline
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    return bootstrap.evalString(allocator, env, content) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "load-file: evaluation error", .{});
        return error.EvalError;
    };
}

/// (line-seq filename) => list of strings
/// UPSTREAM-DIFF: Takes a filename string instead of BufferedReader.
/// Reads file, splits by newlines, returns list of line strings.
pub fn lineSeqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to line-seq", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "line-seq expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.IOError;
    if (content.len == 0) return Value.nil_val;

    // Split by newlines
    var lines = std.ArrayList(Value).empty;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            var end = i;
            // Strip \r before \n
            if (end > start and content[end - 1] == '\r') end -= 1;
            const line = try allocator.dupe(u8, content[start..end]);
            try lines.append(allocator, Value.initString(allocator, line));
            start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (start < content.len) {
        var end = content.len;
        if (end > start and content[end - 1] == '\r') end -= 1;
        const line = try allocator.dupe(u8, content[start..end]);
        try lines.append(allocator, Value.initString(allocator, line));
    }

    if (lines.items.len == 0) return Value.nil_val;

    const items = try allocator.dupe(Value, lines.items);
    const list = try allocator.create(PersistentList);
    list.* = .{ .items = items };
    return Value.initList(list);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "slurp",
        .func = &slurpFn,
        .doc = "Opens f with reader, reads all its contents, and returns as a string.",
        .arglists = "([f])",
        .added = "1.0",
    },
    .{
        .name = "read-line",
        .func = &readLineFn,
        .doc = "Reads the next line from stream that is the current value of *in*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "spit",
        .func = &spitFn,
        .doc = "Opposite of slurp. Opens f with writer, writes content, then closes f.",
        .arglists = "([f content & options])",
        .added = "1.2",
    },
    .{
        .name = "load-file",
        .func = &loadFileFn,
        .doc = "Sequentially read and evaluate the set of forms contained in the file.",
        .arglists = "([name])",
        .added = "1.0",
    },
    .{
        .name = "line-seq",
        .func = &lineSeqFn,
        .doc = "Returns the lines of text from rdr as a lazy sequence of strings. rdr must implement java.io.BufferedReader.",
        .arglists = "([rdr])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "slurp - read existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Create a temp file
    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_slurp.txt";
    const file = try cwd.createFile(tmp_path, .{});
    defer file.close();
    try file.writeAll("hello world");

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try slurpFn(alloc, &args);
    try testing.expectEqualStrings("hello world", result.asString());
}

test "slurp - file not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "/tmp/cljw_nonexistent_file.txt")};
    const result = slurpFn(alloc, &args);
    try testing.expectError(error.FileNotFound, result);
}

test "slurp - arity error" {
    const result = slurpFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "slurp - type error" {
    const args = [_]Value{Value.initInteger(42)};
    const result = slurpFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "spit - write new file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit.txt";
    const args = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "hello spit"),
    };
    const result = try spitFn(alloc, &args);
    try testing.expect(result.isNil());

    // Verify content
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello spit", content);
}

test "spit - overwrite existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit_overwrite.txt";
    // Write first
    const args1 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "first"),
    };
    _ = try spitFn(alloc, &args1);
    // Overwrite
    const args2 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "second"),
    };
    _ = try spitFn(alloc, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second", content);
}

test "spit - append mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit_append.txt";
    // Write initial content
    const args1 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "hello"),
    };
    _ = try spitFn(alloc, &args1);
    // Append
    const args2 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, " world"),
        Value.initKeyword(alloc, .{ .name = "append", .ns = null }),
        Value.true_val,
    };
    _ = try spitFn(alloc, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "spit - arity error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "/tmp/test.txt")};
    const result = spitFn(alloc, &args);
    try testing.expectError(error.ArityError, result);
}

test "read-line - arity error" {
    const args = [_]Value{Value.initInteger(1)};
    const result = readLineFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "line-seq - read file as list of lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a temp file with multiple lines
    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq.txt";
    const file = try cwd.createFile(tmp_path, .{});
    try file.writeAll("line1\nline2\nline3\n");
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    // Should return a list
    try testing.expect(result.tag() == .list);
    const list = result.asList();
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("line1", list.items[0].asString());
    try testing.expectEqualStrings("line2", list.items[1].asString());
    try testing.expectEqualStrings("line3", list.items[2].asString());
}

test "line-seq - no trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq2.txt";
    const file = try cwd.createFile(tmp_path, .{});
    try file.writeAll("line1\nline2");
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    const list = result.asList();
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("line1", list.items[0].asString());
    try testing.expectEqualStrings("line2", list.items[1].asString());
}

test "line-seq - empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq3.txt";
    const file = try cwd.createFile(tmp_path, .{});
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    // Empty file should return nil (empty seq)
    try testing.expect(result.isNil());
}

test "line-seq - arity error" {
    const result = lineSeqFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}
