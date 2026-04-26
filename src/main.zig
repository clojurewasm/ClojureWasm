//! `cljw` entry point.
//!
//! Phase 1 scope:
//!   - With no arguments, prints `ClojureWasm` (smoke output).
//!   - With `-e <expr>` (alias `--eval`), reads each top-level form
//!     from `<expr>` via `eval/reader.zig` and prints it back through
//!     `Form.formatPrStr`. **No evaluation yet** — Phase 2 wires the
//!     analyzer + tree-walk backend; until then the round-trip itself
//!     is the deliverable so Phase 1 can sign off on the read/print
//!     pipeline end-to-end.
//!
//! Errors print to stderr with a non-zero exit; the read loop never
//! `panic`s on malformed input.

const std = @import("std");
const Reader = @import("eval/reader.zig").Reader;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
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
                \\  -e, --eval <expr>  Read <expr> and print each form (Phase 1: no eval yet)
                \\  -h, --help         Show this help
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

    var reader = Reader.init(arena, expr.?);
    while (true) {
        const form_opt = reader.read() catch |err| {
            try stderr.print("Read error: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        const form = form_opt orelse break;

        try form.formatPrStr(stdout);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

test "smoke: main module loads" {
    try std.testing.expect(true);
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
}
