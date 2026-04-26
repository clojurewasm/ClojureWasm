//! `cljw` entry point.
//!
//! Phase-2 scope:
//!   - With no arguments, prints `ClojureWasm` (smoke output).
//!   - With `-e <expr>` (alias `--eval`), runs a full Read-Analyse-
//!     Eval-Print loop: each top-level form is parsed by `Reader`,
//!     analysed into a `Node` tree, evaluated by the TreeWalk
//!     backend, and printed.
//!
//! Errors print to stderr with a non-zero exit; the loop never
//! panics on malformed input.

const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("eval/reader.zig").Reader;
const analyzeForm = @import("eval/analyzer.zig").analyze;
const tree_walk = @import("eval/backend/tree_walk.zig");
const Runtime = @import("runtime/runtime.zig").Runtime;
const Env = @import("runtime/env.zig").Env;
const Value = @import("runtime/value.zig").Value;
const primitive = @import("lang/primitive.zig");
const keyword = @import("runtime/keyword.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]

    var expr: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            expr = args.next();
            if (expr == null) {
                try stderr.print("Error: -e / --eval requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\Usage: cljw [options]
                \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
                \\  -h, --help         Show this help.
                \\
            , .{});
            try stdout.flush();
            return;
        } else {
            try stderr.print("Unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        }
    }

    if (expr == null) {
        try stdout.writeAll("ClojureWasm\n");
        try stdout.flush();
        return;
    }

    // --- Runtime + Env + backend setup ---
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();

    var env = try Env.init(&rt);
    defer env.deinit();

    tree_walk.installVTable(&rt);
    try primitive.registerAll(&env);

    // --- Read - Analyse - Eval - Print loop ---
    var reader = Reader.init(arena, expr.?);
    while (true) {
        const form_opt = reader.read() catch |err| {
            try stderr.print("Read error: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const form = form_opt orelse break;

        const node = analyzeForm(arena, &rt, &env, null, form) catch |err| {
            try stderr.print("Analyse error: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };

        var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
        const result = tree_walk.eval(&rt, &env, &locals, node) catch |err| {
            try stderr.print("Eval error: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };

        try printValue(stdout, result);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

/// Print a Value to `w` in `pr-str` style. Phase-2 surface: nil /
/// boolean / integer / float / char / builtin_fn / keyword. Other
/// heap kinds render as `#<tag>` placeholders so the user sees
/// *something* instead of an undecipherable address — Phase 3+ will
/// build the proper printer alongside the heap types it needs.
pub fn printValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag()) {
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll(if (v.asBoolean()) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f)) try w.writeAll("##NaN") //
            else if (std.math.isPositiveInf(f)) try w.writeAll("##Inf") //
            else if (std.math.isNegativeInf(f)) try w.writeAll("##-Inf") //
            else try w.print("{d}", .{f});
        },
        .char => try w.print("\\u{x:0>4}", .{v.asChar()}),
        .builtin_fn => try w.writeAll("#builtin"),
        .keyword => {
            const k = keyword.asKeyword(v);
            try w.writeByte(':');
            if (k.ns) |n| {
                try w.writeAll(n);
                try w.writeByte('/');
            }
            try w.writeAll(k.name);
        },
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}

test "smoke: main module loads" {
    try std.testing.expect(true);
}

test "printValue renders Phase-2 atoms" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try printValue(&w, .nil_val);
    try printValue(&w, Value.initInteger(42));
    try printValue(&w, .true_val);
    try std.testing.expectEqualStrings("nil42true", w.buffered());
}

// Pull in tests from the source tree. As more files appear under
// src/, add them here so the unified `zig build test` discovers them.
test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/error.zig");
    _ = @import("runtime/gc/arena.zig");
    _ = @import("runtime/collection/list.zig");
    _ = @import("runtime/hash.zig");
    _ = @import("runtime/keyword.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/dispatch.zig");
    _ = @import("runtime/env.zig");
    _ = @import("eval/form.zig");
    _ = @import("eval/tokenizer.zig");
    _ = @import("eval/reader.zig");
    _ = @import("eval/node.zig");
    _ = @import("eval/analyzer.zig");
    _ = @import("eval/backend/tree_walk.zig");
    _ = @import("lang/primitive/math.zig");
    _ = @import("lang/primitive/core.zig");
    _ = @import("lang/primitive.zig");
}
