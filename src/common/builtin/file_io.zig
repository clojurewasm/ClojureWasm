// File I/O builtins — slurp, spit
//
// slurp: Read entire file content as a string.
// spit: Write string content to a file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;

// ============================================================
// Builtins
// ============================================================

/// (slurp filename) => string
/// Opens the file, reads all content as UTF-8 string, closes the file.
pub fn slurpFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeError,
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.IOError;
    return Value{ .string = content };
}

/// (spit filename content) => nil
/// (spit filename content :append true) => nil
/// Writes content to the file. Creates if not exists, truncates by default.
pub fn spitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeError,
    };

    // Get content as string
    const content = switch (args[1]) {
        .string => |s| s,
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
        if (args[2] == .keyword) {
            if (std.mem.eql(u8, args[2].keyword.name, "append")) {
                if (args[3] == .boolean) {
                    append = args[3].boolean;
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
            return .nil;
        };
        defer file.close();
        file.seekFromEnd(0) catch return error.IOError;
        file.writeAll(content) catch return error.IOError;
    } else {
        const file = cwd.createFile(path, .{}) catch return error.IOError;
        defer file.close();
        file.writeAll(content) catch return error.IOError;
    }

    return .nil;
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
        .name = "spit",
        .func = &spitFn,
        .doc = "Opposite of slurp. Opens f with writer, writes content, then closes f.",
        .arglists = "([f content & options])",
        .added = "1.2",
    },
};

// === Tests ===

const testing = std.testing;

test "slurp - read existing file" {
    // Create a temp file
    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_slurp.txt";
    const file = try cwd.createFile(tmp_path, .{});
    defer file.close();
    try file.writeAll("hello world");

    const args = [_]Value{.{ .string = tmp_path }};
    const result = try slurpFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("hello world", result.string);
}

test "slurp - file not found" {
    const args = [_]Value{.{ .string = "/tmp/cljw_nonexistent_file.txt" }};
    const result = slurpFn(testing.allocator, &args);
    try testing.expectError(error.FileNotFound, result);
}

test "slurp - arity error" {
    const result = slurpFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "slurp - type error" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = slurpFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "spit - write new file" {
    const tmp_path = "/tmp/cljw_test_spit.txt";
    const args = [_]Value{
        .{ .string = tmp_path },
        .{ .string = "hello spit" },
    };
    const result = try spitFn(testing.allocator, &args);
    try testing.expect(result == .nil);

    // Verify content
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello spit", content);
}

test "spit - overwrite existing file" {
    const tmp_path = "/tmp/cljw_test_spit_overwrite.txt";
    // Write first
    const args1 = [_]Value{
        .{ .string = tmp_path },
        .{ .string = "first" },
    };
    _ = try spitFn(testing.allocator, &args1);
    // Overwrite
    const args2 = [_]Value{
        .{ .string = tmp_path },
        .{ .string = "second" },
    };
    _ = try spitFn(testing.allocator, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second", content);
}

test "spit - append mode" {
    const tmp_path = "/tmp/cljw_test_spit_append.txt";
    // Write initial content
    const args1 = [_]Value{
        .{ .string = tmp_path },
        .{ .string = "hello" },
    };
    _ = try spitFn(testing.allocator, &args1);
    // Append
    const args2 = [_]Value{
        .{ .string = tmp_path },
        .{ .string = " world" },
        .{ .keyword = .{ .name = "append", .ns = null } },
        .{ .boolean = true },
    };
    _ = try spitFn(testing.allocator, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "spit - arity error" {
    const args = [_]Value{.{ .string = "/tmp/test.txt" }};
    const result = spitFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}
