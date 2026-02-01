// ClojureWasm CLI entry point.
//
// Usage:
//   clj-wasm -e "expr"    Evaluate expression and print result
//   clj-wasm file.clj     Evaluate file and print last result
//   clj-wasm              Print version info (REPL stub)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("common/env.zig").Env;
const registry = @import("common/builtin/registry.zig");
const bootstrap = @import("common/bootstrap.zig");
const Value = @import("common/value.zig").Value;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use arena for Clojure evaluation (bulk free at exit)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        _ = stdout.write("ClojureWasm v0.1.0\n") catch {};
        return;
    }

    // Parse flags
    var use_vm = true;
    var expr: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tree-walk")) {
            use_vm = false;
        } else if (std.mem.eql(u8, args[i], "-e")) {
            i += 1;
            if (i >= args.len) {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: -e requires an expression argument\n") catch {};
                std.process.exit(1);
            }
            expr = args[i];
        } else {
            file = args[i];
        }
    }

    if (expr) |e| {
        evalAndPrint(alloc, e, use_vm);
    } else if (file) |f| {
        const source = std.fs.cwd().readFileAlloc(allocator, f, 1024 * 1024) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(source);
        evalAndPrint(alloc, source, use_vm);
    }
}

fn evalAndPrint(allocator: Allocator, source: []const u8, use_vm: bool) void {
    // Initialize environment
    var env = Env.init(allocator);
    defer env.deinit();
    registry.registerBuiltins(&env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadCore(allocator, &env) catch {
        std.debug.print("Error: failed to load core.clj\n", .{});
        std.process.exit(1);
    };

    // Evaluate using selected backend
    const result = if (use_vm)
        bootstrap.evalStringVM(allocator, &env, source) catch {
            std.debug.print("Error: VM evaluation failed\n", .{});
            std.process.exit(1);
        }
    else
        bootstrap.evalString(allocator, &env, source) catch {
            std.debug.print("Error: evaluation failed\n", .{});
            std.process.exit(1);
        };

    // Print result to stdout
    var buf: [65536]u8 = undefined;
    const output = formatValue(&buf, result);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(output) catch {};
    _ = stdout.write("\n") catch {};
}

fn formatValue(buf: []u8, val: Value) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    writeValue(w, val);
    return stream.getWritten();
}

fn writeValue(w: anytype, val: Value) void {
    switch (val) {
        .nil => w.print("nil", .{}) catch {},
        .boolean => |b| w.print("{}", .{b}) catch {},
        .integer => |i| w.print("{d}", .{i}) catch {},
        .float => |f| w.print("{d}", .{f}) catch {},
        .string => |s| w.print("\"{s}\"", .{s}) catch {},
        .keyword => |k| {
            if (k.ns) |ns| {
                w.print(":{s}/{s}", .{ ns, k.name }) catch {};
            } else {
                w.print(":{s}", .{k.name}) catch {};
            }
        },
        .symbol => |s| {
            if (s.ns) |ns| {
                w.print("{s}/{s}", .{ ns, s.name }) catch {};
            } else {
                w.print("{s}", .{s.name}) catch {};
            }
        },
        .list => |lst| {
            w.print("(", .{}) catch {};
            for (lst.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print(")", .{}) catch {};
        },
        .vector => |vec| {
            w.print("[", .{}) catch {};
            for (vec.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("]", .{}) catch {};
        },
        .map => |m| {
            w.print("{{", .{}) catch {};
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, m.entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, m.entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .set => |s| {
            w.print("#{{", .{}) catch {};
            for (s.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("}}", .{}) catch {};
        },
        .fn_val => w.print("#<fn>", .{}) catch {},
        .builtin_fn => w.print("#<builtin>", .{}) catch {},
        .atom => |a| {
            w.print("(atom ", .{}) catch {};
            writeValue(w, a.value);
            w.print(")", .{}) catch {};
        },
        .char => |c| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(buf[0..len]) catch {};
        },
        .protocol => |p| w.print("#<protocol {s}>", .{p.name}) catch {},
        .protocol_fn => |pf| w.print("#<protocol-fn {s}/{s}>", .{ pf.protocol.name, pf.method_name }) catch {},
    }
}
