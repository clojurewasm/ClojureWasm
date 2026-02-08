// clojure.java.io compatibility layer — native Zig I/O behind JVM-compatible API
//
// Provides file system operations that match the clojure.java.io namespace.
// Strings are used as file paths (no Java File objects).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err_mod = @import("../error.zig");

// ============================================================
// Builtins
// ============================================================

/// (file path) or (file parent child) or (file parent child & more)
/// Joins path segments with the OS path separator. Returns a string.
pub fn fileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to file", .{args.len});

    // Collect string parts, skipping nils
    var buf: [32][]const u8 = undefined;
    var count: usize = 0;

    for (args) |arg| {
        switch (arg.tag()) {
            .string => {
                if (count >= buf.len) return err_mod.setErrorFmt(.eval, .value_error, .{}, "file: too many path segments", .{});
                buf[count] = arg.asString();
                count += 1;
            },
            .nil => {},
            else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "file expects string arguments, got {s}", .{@tagName(arg.tag())}),
        }
    }

    if (count == 0) return Value.nil_val;
    if (count == 1) return Value.initString(allocator, buf[0]);

    const joined = try std.fs.path.join(allocator, buf[0..count]);
    return Value.initString(allocator, joined);
}

/// (delete-file f) or (delete-file f silently)
/// Deletes file f. If silently is true, suppresses exceptions on failure.
pub fn deleteFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1 or args.len > 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to delete-file", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "delete-file expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    const silently = if (args.len > 1) args[1].isTruthy() else false;

    const cwd = std.fs.cwd();
    cwd.deleteFile(path) catch |e| {
        // Try as directory
        cwd.deleteDir(path) catch {
            if (!silently) {
                return err_mod.setErrorFmt(.eval, .io_error, .{}, "Could not delete file: {s} ({s})", .{ path, @errorName(e) });
            }
        };
    };

    return Value.initBoolean(true);
}

/// (make-parents f & more)
/// Creates all parent directories of the path formed by (file f & more).
pub fn makeParentsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-parents", .{args.len});

    // Build path from args (same as file)
    var buf: [32][]const u8 = undefined;
    var count: usize = 0;

    for (args) |arg| {
        switch (arg.tag()) {
            .string => {
                if (count >= buf.len) return err_mod.setErrorFmt(.eval, .value_error, .{}, "make-parents: too many path segments", .{});
                buf[count] = arg.asString();
                count += 1;
            },
            .nil => {},
            else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "make-parents expects string arguments, got {s}", .{@tagName(arg.tag())}),
        }
    }

    if (count == 0) return Value.initBoolean(false);

    const path = if (count == 1) buf[0] else try std.fs.path.join(allocator, buf[0..count]);

    // Get parent directory
    const parent = std.fs.path.dirname(path) orelse return Value.initBoolean(false);

    const cwd = std.fs.cwd();
    cwd.makePath(parent) catch |e| {
        return err_mod.setErrorFmt(.eval, .io_error, .{}, "Could not create parent directories: {s} ({s})", .{ parent, @errorName(e) });
    };

    return Value.initBoolean(true);
}

/// (as-file x)
/// Coerces x to a file path string. In CW, strings are file paths, so this is identity.
pub fn asFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-file", .{args.len});
    return switch (args[0].tag()) {
        .string => args[0],
        .nil => Value.nil_val,
        else => err_mod.setErrorFmt(.eval, .type_error, .{}, "as-file expects a string or nil, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (as-relative-path x)
/// Returns x as a relative path string. Throws if path is absolute.
pub fn asRelativePathFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-relative-path", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "as-relative-path expects a string, got {s}", .{@tagName(args[0].tag())}),
    };

    if (std.fs.path.isAbsolute(path)) {
        return err_mod.setErrorFmt(.eval, .value_error, .{}, "IllegalArgumentException: {s} is not a relative path", .{path});
    }

    return args[0];
}

/// (copy input output) or (copy input output & opts)
/// Copies file content from input path to output path.
pub fn copyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to copy", .{args.len});

    const src_path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "copy expects string paths, got {s}", .{@tagName(args[0].tag())}),
    };

    const dst_path = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "copy expects string paths, got {s}", .{@tagName(args[1].tag())}),
    };

    const cwd = std.fs.cwd();

    // Read source file
    const content = cwd.readFileAlloc(allocator, src_path, 100 * 1024 * 1024) catch |e| {
        return err_mod.setErrorFmt(.eval, .io_error, .{}, "copy: could not read {s} ({s})", .{ src_path, @errorName(e) });
    };

    // Write to destination
    const dst_file = cwd.createFile(dst_path, .{}) catch |e| {
        return err_mod.setErrorFmt(.eval, .io_error, .{}, "copy: could not create {s} ({s})", .{ dst_path, @errorName(e) });
    };
    defer dst_file.close();

    dst_file.writeAll(content) catch |e| {
        return err_mod.setErrorFmt(.eval, .io_error, .{}, "copy: could not write to {s} ({s})", .{ dst_path, @errorName(e) });
    };

    return Value.nil_val;
}

/// (resource name)
/// Returns the path for a named resource. In CW, looks for the file relative to cwd.
/// Returns nil if not found.
pub fn resourceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1 or args.len > 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to resource", .{args.len});

    const name = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err_mod.setErrorFmt(.eval, .type_error, .{}, "resource expects a string, got {s}", .{@tagName(args[0].tag())}),
    };

    // Check if file exists relative to cwd
    const cwd = std.fs.cwd();
    const stat = cwd.statFile(name) catch return Value.nil_val;
    _ = stat;

    return args[0];
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "file",
        .func = &fileFn,
        .doc = "Returns a java.io.File, passing each arg to as-file. Multiple-arg versions treat the first argument as parent and subsequent args as children relative to the parent.",
        .arglists = "([arg] [parent child] [parent child & more])",
        .added = "1.2",
    },
    .{
        .name = "delete-file",
        .func = &deleteFileFn,
        .doc = "Delete file f. If silently is nil or false, raise an exception on failure, else return the value of silently.",
        .arglists = "([f] [f silently])",
        .added = "1.2",
    },
    .{
        .name = "make-parents",
        .func = &makeParentsFn,
        .doc = "Given the same arg(s) as for file, creates all parent directories of the file. Returns true if any directories were created.",
        .arglists = "([f & more])",
        .added = "1.2",
    },
    .{
        .name = "as-file",
        .func = &asFileFn,
        .doc = "Coerce argument to a file path.",
        .arglists = "([x])",
        .added = "1.2",
    },
    .{
        .name = "as-relative-path",
        .func = &asRelativePathFn,
        .doc = "Take an as-file-able thing and return a string if it is a relative path, else IllegalArgumentException.",
        .arglists = "([x])",
        .added = "1.2",
    },
    .{
        .name = "copy",
        .func = &copyFn,
        .doc = "Copies input to output. Returns nil or throws IOException on failure.",
        .arglists = "([input output] [input output & opts])",
        .added = "1.2",
    },
    .{
        .name = "resource",
        .func = &resourceFn,
        .doc = "Returns the URL for a named resource. In CW, checks for the file relative to the current directory.",
        .arglists = "([n] [n loader])",
        .added = "1.2",
    },
};

// === Tests ===

const testing = std.testing;

test "file - single arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello.txt")};
    const result = try fileFn(alloc, &args);
    try testing.expectEqualStrings("hello.txt", result.asString());
}

test "file - multiple args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{ Value.initString(alloc, "dir"), Value.initString(alloc, "sub"), Value.initString(alloc, "file.txt") };
    const result = try fileFn(alloc, &args);
    try testing.expectEqualStrings("dir/sub/file.txt", result.asString());
}

test "as-relative-path - relative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "foo/bar.txt")};
    const result = try asRelativePathFn(alloc, &args);
    try testing.expectEqualStrings("foo/bar.txt", result.asString());
}

test "as-relative-path - absolute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "/foo/bar.txt")};
    const result = asRelativePathFn(alloc, &args);
    try testing.expect(result == error.ValueError);
}

test "delete-file - nonexistent silently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{ Value.initString(alloc, "/tmp/cljw_nonexistent_delete_test.txt"), Value.initBoolean(true) };
    const result = try deleteFileFn(alloc, &args);
    try testing.expect(result.isTruthy());
}

test "make-parents and delete-file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/cljw_test_mkp/sub/file.txt";
    const mk_args = [_]Value{Value.initString(alloc, path)};
    const mk_result = try makeParentsFn(alloc, &mk_args);
    try testing.expect(mk_result.isTruthy());

    // Verify parent dir exists
    const cwd = std.fs.cwd();
    const stat = try cwd.statFile("/tmp/cljw_test_mkp/sub");
    try testing.expect(stat.kind == .directory);

    // Clean up
    try cwd.deleteDir("/tmp/cljw_test_mkp/sub");
    try cwd.deleteDir("/tmp/cljw_test_mkp");
}
