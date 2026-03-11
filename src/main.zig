const std = @import("std");
const Reader = @import("eval/reader.zig").Reader;

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Parse CLI args
    var args = std.process.args();
    _ = args.skip(); // program name

    var expr: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            expr = args.next();
            if (expr == null) {
                try stderr.print("Error: -e requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("Usage: clojurewasm [options]\n  -e, --eval <expr>  Read and print expression\n  -h, --help         Show this help\n", .{});
            try stdout.flush();
            return;
        } else {
            try stderr.print("Unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        }
    }

    if (expr) |source| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var reader = Reader.init(alloc, source);
        while (true) {
            const form = reader.read() catch |err| {
                try stderr.print("Read error: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            if (form == null) break;

            // Use toString to convert Form to string, then print
            const s = form.?.toString(alloc) catch |err| {
                try stderr.print("Print error: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            try stdout.print("{s}\n", .{s});
        }
        try stdout.flush();
    } else {
        try stdout.print("ClojureWasm\n", .{});
        try stdout.flush();
    }
}

test "main compiles" {
    _ = @import("eval/reader.zig");
    _ = @import("eval/form.zig");
}
