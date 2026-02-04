// Misc builtins — gensym, compare-and-set!, format.
//
// Small standalone utilities that don't fit neatly into other domain files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const err = @import("../error.zig");

// ============================================================
// gensym
// ============================================================

var gensym_counter: u64 = 0;

/// (gensym) => G__42
/// (gensym prefix-string) => prefix42
pub fn gensymFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len > 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to gensym", .{args.len});

    const prefix: []const u8 = if (args.len == 1) switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "gensym expects a string prefix, got {s}", .{@tagName(args[0])}),
    } else "G__";

    gensym_counter += 1;

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll(prefix);
    try w.print("{d}", .{gensym_counter});
    const name = try allocator.dupe(u8, w.buffered());
    return .{ .symbol = .{ .ns = null, .name = name } };
}

// ============================================================
// compare-and-set!
// ============================================================

/// (compare-and-set! atom oldval newval)
/// Atomically sets the value of atom to newval if and only if the
/// current value of the atom is identical to oldval. Returns true
/// if set happened, else false.
pub fn compareAndSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to compare-and-set!", .{args.len});
    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "compare-and-set! expects an atom, got {s}", .{@tagName(args[0])}),
    };
    const oldval = args[1];
    const newval = args[2];

    // Single-threaded: simple compare and swap
    if (atom_ptr.value.eql(oldval)) {
        atom_ptr.value = newval;
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

// ============================================================
// format
// ============================================================

/// (format fmt & args)
/// Formats a string using java.lang.String/format-style placeholders.
/// Supported: %s (string), %d (integer), %f (float), %% (literal %).
pub fn formatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to format", .{args.len});
    const fmt_str = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "format expects a string as first argument, got {s}", .{@tagName(args[0])}),
    };
    const fmt_args = args[1..];

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var w = &aw.writer;

    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '%') {
            i += 1;
            if (i >= fmt_str.len) return error.FormatError;

            switch (fmt_str[i]) {
                '%' => {
                    try w.writeByte('%');
                },
                's' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    try fmt_args[arg_idx].formatStr(w);
                    arg_idx += 1;
                },
                'd' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    switch (fmt_args[arg_idx]) {
                        .integer => |n| try w.print("{d}", .{n}),
                        .float => |f| try w.print("{d}", .{@as(i64, @intFromFloat(f))}),
                        else => return error.FormatError,
                    }
                    arg_idx += 1;
                },
                'f' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    switch (fmt_args[arg_idx]) {
                        .float => |f| try w.print("{d:.6}", .{f}),
                        .integer => |n| try w.print("{d:.6}", .{@as(f64, @floatFromInt(n))},),
                        else => return error.FormatError,
                    }
                    arg_idx += 1;
                },
                else => {
                    // Unsupported format specifier — pass through
                    try w.writeByte('%');
                    try w.writeByte(fmt_str[i]);
                },
            }
        } else {
            try w.writeByte(fmt_str[i]);
        }
        i += 1;
    }

    const result = try allocator.dupe(u8, aw.writer.buffered());
    return .{ .string = result };
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "gensym",
        .func = gensymFn,
        .doc = "Returns a new symbol with a unique name. If a prefix string is supplied, the name is prefix# where # is some unique number. If no prefix is supplied, the prefix is 'G__'.",
        .arglists = "([] [prefix-string])",
        .added = "1.0",
    },
    .{
        .name = "compare-and-set!",
        .func = compareAndSetFn,
        .doc = "Atomically sets the value of atom to newval if and only if the current value of the atom is identical to oldval. Returns true if set happened, else false.",
        .arglists = "([atom oldval newval])",
        .added = "1.0",
    },
    .{
        .name = "format",
        .func = formatFn,
        .doc = "Formats a string using java.lang.String/format-style placeholders. Supports %s, %d, %f, %%.",
        .arglists = "([fmt & args])",
        .added = "1.0",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "gensym - no prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r1 = try gensymFn(alloc, &[_]Value{});
    try testing.expect(r1 == .symbol);
    // Should start with G__
    try testing.expect(std.mem.startsWith(u8, r1.symbol.name, "G__"));

    const r2 = try gensymFn(alloc, &[_]Value{});
    // Should be different from r1
    try testing.expect(!std.mem.eql(u8, r1.symbol.name, r2.symbol.name));
}

test "gensym - with prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try gensymFn(alloc, &[_]Value{.{ .string = "foo" }});
    try testing.expect(result == .symbol);
    try testing.expect(std.mem.startsWith(u8, result.symbol.name, "foo"));
}

test "compare-and-set! - successful swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = .{ .integer = 1 } };
    const result = try compareAndSetFn(alloc, &[_]Value{
        .{ .atom = &atom },
        .{ .integer = 1 },
        .{ .integer = 2 },
    });
    try testing.expectEqual(Value{ .boolean = true }, result);
    try testing.expectEqual(Value{ .integer = 2 }, atom.value);
}

test "compare-and-set! - failed swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = .{ .integer = 1 } };
    const result = try compareAndSetFn(alloc, &[_]Value{
        .{ .atom = &atom },
        .{ .integer = 99 }, // doesn't match current value
        .{ .integer = 2 },
    });
    try testing.expectEqual(Value{ .boolean = false }, result);
    try testing.expectEqual(Value{ .integer = 1 }, atom.value); // unchanged
}

test "format - %s" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "hello %s" },
        .{ .string = "world" },
    });
    try testing.expectEqualStrings("hello world", result.string);
}

test "format - %d" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "count: %d" },
        .{ .integer = 42 },
    });
    try testing.expectEqualStrings("count: 42", result.string);
}

test "format - %%" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "100%%" },
    });
    try testing.expectEqualStrings("100%", result.string);
}

test "format - mixed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "%s is %d" },
        .{ .string = "x" },
        .{ .integer = 10 },
    });
    try testing.expectEqualStrings("x is 10", result.string);
}
