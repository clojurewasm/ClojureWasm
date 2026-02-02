// ClojureWasm CLI entry point.
//
// Usage:
//   cljw -e "expr"    Evaluate expression and print result
//   cljw file.clj     Evaluate file and print last result
//   cljw              Start interactive REPL

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("common/env.zig").Env;
const registry = @import("common/builtin/registry.zig");
const bootstrap = @import("common/bootstrap.zig");
const Value = @import("common/value.zig").Value;
const nrepl = @import("repl/nrepl.zig");

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
        // No args — start REPL
        var env = Env.init(alloc);
        defer env.deinit();
        registry.registerBuiltins(&env) catch {
            std.debug.print("Error: failed to register builtins\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadCore(alloc, &env) catch {
            std.debug.print("Error: failed to load core.clj\n", .{});
            std.process.exit(1);
        };
        runRepl(alloc, &env);
        return;
    }

    // Parse flags
    var use_vm = true;
    var dump_bytecode = false;
    var expr: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var nrepl_mode = false;
    var nrepl_port: u16 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tree-walk")) {
            use_vm = false;
        } else if (std.mem.eql(u8, args[i], "--dump-bytecode")) {
            dump_bytecode = true;
        } else if (std.mem.eql(u8, args[i], "--nrepl-server")) {
            nrepl_mode = true;
        } else if (std.mem.startsWith(u8, args[i], "--port=")) {
            nrepl_port = std.fmt.parseInt(u16, args[i]["--port=".len..], 10) catch 0;
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

    if (nrepl_mode) {
        nrepl.startServer(allocator, nrepl_port) catch |e| {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: nREPL server failed: ") catch {};
            _ = stderr.write(@errorName(e)) catch {};
            _ = stderr.write("\n") catch {};
            std.process.exit(1);
        };
        return;
    }

    if (expr) |e| {
        evalAndPrint(alloc, e, use_vm, dump_bytecode);
    } else if (file) |f| {
        const max_file_size = 10 * 1024 * 1024; // 10MB
        const source = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file (max 10MB)\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(source);
        evalAndPrint(alloc, source, use_vm, dump_bytecode);
    }
}

fn runRepl(allocator: Allocator, env: *Env) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

    _ = stdout.write("ClojureWasm v0.1.0\n") catch {};

    var line_buf: [65536]u8 = undefined;
    var input_buf: [65536]u8 = undefined;
    var input_len: usize = 0;
    var depth: i32 = 0;

    while (true) {
        // Prompt
        const prompt: []const u8 = if (depth > 0) "     " else "user=> ";
        _ = stdout.write(prompt) catch {};

        // Read a line into separate buffer to avoid memcpy alias
        const line_end = readLine(stdin, &line_buf) orelse {
            // EOF (Ctrl-D)
            _ = stdout.write("\n") catch {};
            break;
        };

        const trimmed = std.mem.trim(u8, line_buf[0..line_end], " \t\r");

        // Skip empty lines at top level
        if (trimmed.len == 0 and depth == 0) continue;

        // Append to input buffer
        if (input_len > 0) {
            input_buf[input_len] = '\n';
            input_len += 1;
        }
        if (input_len + trimmed.len > input_buf.len) {
            _ = stdout.write("Error: input too long\n") catch {};
            input_len = 0;
            depth = 0;
            continue;
        }
        @memcpy(input_buf[input_len .. input_len + trimmed.len], trimmed);
        input_len += trimmed.len;

        // Update delimiter depth
        depth = countDelimiterDepth(input_buf[0..input_len]);

        // If unbalanced, continue reading
        if (depth > 0) continue;

        // Evaluate
        const source = input_buf[0..input_len];
        const result = bootstrap.evalString(allocator, env, source);

        if (result) |val| {
            var buf: [65536]u8 = undefined;
            const output = formatValue(&buf, val);
            _ = stdout.write(output) catch {};
            _ = stdout.write("\n") catch {};
        } else |_| {
            _ = stdout.write("Error: evaluation failed\n") catch {};
        }

        // Reset for next input
        input_len = 0;
        depth = 0;
    }
}

/// Read a line from file into buf. Returns line length, or null on EOF with no data.
fn readLine(file: std.fs.File, buf: []u8) ?usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = file.read(&byte) catch return null;
        if (n == 0) {
            // EOF
            if (pos > 0) return pos;
            return null;
        }
        if (byte[0] == '\n') {
            return pos;
        }
        buf[pos] = byte[0];
        pos += 1;
    }
    // Buffer full
    return pos;
}

/// Count nesting depth of delimiters in source.
/// Returns > 0 if more openers than closers, 0 if balanced, < 0 if over-closed.
fn countDelimiterDepth(source: []const u8) i32 {
    var d: i32 = 0;
    var in_string = false;
    var in_comment = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ';' => in_comment = true,
            '"' => in_string = true,
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            else => {},
        }
    }
    return d;
}

fn evalAndPrint(allocator: Allocator, source: []const u8, use_vm: bool, dump_bytecode: bool) void {
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

    // Dump bytecode if requested (VM only, dump to stderr then exit)
    if (dump_bytecode) {
        if (!use_vm) {
            std.debug.print("Error: --dump-bytecode requires VM backend (not --tree-walk)\n", .{});
            std.process.exit(1);
        }
        bootstrap.dumpBytecodeVM(allocator, &env, source) catch {
            std.debug.print("Error: bytecode dump failed\n", .{});
            std.process.exit(1);
        };
        return;
    }

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
        .volatile_ref => |v| {
            w.print("#<volatile ", .{}) catch {};
            writeValue(w, v.value);
            w.print(">", .{}) catch {};
        },
        .char => |c| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(buf[0..len]) catch {};
        },
        .protocol => |p| w.print("#<protocol {s}>", .{p.name}) catch {},
        .protocol_fn => |pf| w.print("#<protocol-fn {s}/{s}>", .{ pf.protocol.name, pf.method_name }) catch {},
        .multi_fn => |mf| w.print("#<multifn {s}>", .{mf.name}) catch {},
        .lazy_seq => |ls| {
            if (ls.realized) |r| {
                writeValue(w, r);
            } else {
                w.print("#<lazy-seq>", .{}) catch {};
            }
        },
        .cons => |c| {
            w.print("(", .{}) catch {};
            writeValue(w, c.first);
            w.print(" . ", .{}) catch {};
            writeValue(w, c.rest);
            w.print(")", .{}) catch {};
        },
        .var_ref => |v| {
            w.print("#'{s}/{s}", .{ v.ns_name, v.sym.name }) catch {};
        },
    }
}
