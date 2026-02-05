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
const err = @import("common/error.zig");
const gc_mod = @import("common/gc.zig");
const keyword_intern = @import("common/keyword_intern.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two allocators:
    //   allocator (GPA)   — for infrastructure (Env, Namespace, Var, HashMaps)
    //   alloc (GC)        — for Values (Fn, collections, strings, reader/analyzer)
    var gc = gc_mod.MarkSweepGc.init(allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Initialize keyword intern table (uses GPA for permanent keyword strings)
    keyword_intern.init(allocator);
    defer keyword_intern.deinit();

    if (args.len < 2) {
        // No args — start REPL
        // Env uses GPA for infrastructure (Namespace/Var/HashMap internals)
        var env = Env.init(allocator);
        defer env.deinit();
        registry.registerBuiltins(&env) catch {
            std.debug.print("Error: failed to register builtins\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadCore(alloc, &env) catch {
            std.debug.print("Error: failed to load core.clj\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadWalk(alloc, &env) catch {
            std.debug.print("Error: failed to load clojure.walk\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadTemplate(alloc, &env) catch {
            std.debug.print("Error: failed to load clojure.template\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadTest(alloc, &env) catch {
            std.debug.print("Error: failed to load clojure.test\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadSet(alloc, &env) catch {
            std.debug.print("Error: failed to load clojure.set\n", .{});
            std.process.exit(1);
        };
        bootstrap.loadData(alloc, &env) catch {
            std.debug.print("Error: failed to load clojure.data\n", .{});
            std.process.exit(1);
        };
        // Enable GC for REPL evaluation (bootstrap runs without GC).
        // Reset threshold to avoid immediate sweep on first safe point.
        gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
        env.gc = @ptrCast(&gc);
        runRepl(alloc, &env, &gc);
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
        err.setSourceFile(null);
        err.setSourceText(e);
        evalAndPrint(alloc, allocator, &gc, e, use_vm, dump_bytecode);
    } else if (file) |f| {
        const max_file_size = 10 * 1024 * 1024; // 10MB
        const source = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file (max 10MB)\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(source);
        err.setSourceFile(f);
        err.setSourceText(source);
        evalAndPrint(alloc, allocator, &gc, source, use_vm, dump_bytecode);
    }
}

fn runRepl(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
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
        err.setSourceText(source);
        const result = bootstrap.evalString(allocator, env, source);

        if (result) |val| {
            var buf: [65536]u8 = undefined;
            const output = formatValue(&buf, val);
            _ = stdout.write(output) catch {};
            _ = stdout.write("\n") catch {};
        } else |eval_err| {
            reportError(eval_err);
        }

        // GC safe point: between REPL forms, no AST nodes in use.
        // Root set: env namespaces contain all live Values.
        gc.collectIfNeeded(.{ .env = env });

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

fn evalAndPrint(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, use_vm: bool, dump_bytecode: bool) void {
    // Env uses infra_alloc (GPA) for Namespace/Var/HashMap internals.
    // bootstrap and evaluation use gc_alloc (MarkSweepGc) for Values.
    var env = Env.init(infra_alloc);
    defer env.deinit();
    registry.registerBuiltins(&env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadCore(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load core.clj\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadWalk(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.walk\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadTemplate(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.template\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadTest(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.test\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadSet(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.set\n", .{});
        std.process.exit(1);
    };
    bootstrap.loadData(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.data\n", .{});
        std.process.exit(1);
    };
    // Enable GC for user evaluation (bootstrap runs without GC).
    // Reset threshold to avoid immediate sweep on first safe point.
    gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
    env.gc = @ptrCast(gc);

    // Dump bytecode if requested (VM only, dump to stderr then exit)
    if (dump_bytecode) {
        if (!use_vm) {
            std.debug.print("Error: --dump-bytecode requires VM backend (not --tree-walk)\n", .{});
            std.process.exit(1);
        }
        bootstrap.dumpBytecodeVM(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        };
        return;
    }

    // Evaluate using selected backend
    const result = if (use_vm)
        bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        }
    else
        bootstrap.evalString(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        };

    // Print result to stdout
    var buf: [65536]u8 = undefined;
    const output = formatValue(&buf, result);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(output) catch {};
    _ = stdout.write("\n") catch {};
}

// === Error reporting (babashka-style) ===

fn reportError(eval_err: anyerror) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    if (err.getLastError()) |info| {
        w.writeAll("----- Error -----------------------------------------------\n") catch {};
        w.print("Type:     {s}\n", .{@tagName(info.kind)}) catch {};
        w.print("Message:  {s}\n", .{info.message}) catch {};
        if (info.phase != .eval) {
            w.print("Phase:    {s}\n", .{@tagName(info.phase)}) catch {};
        }
        if (info.location.line > 0) {
            const file = info.location.file orelse "<expr>";
            w.print("Location: {s}:{d}:{d}\n", .{ file, info.location.line, info.location.column }) catch {};
        }
        // Source context
        if (info.location.line > 0) {
            showSourceContext(w, info.location, info.message);
        }
    } else {
        // No detailed error info — fallback to Zig error name
        w.print("Error: {s}\n", .{@errorName(eval_err)}) catch {};
    }

    _ = stderr.write(stream.getWritten()) catch {};
}

fn showSourceContext(w: anytype, location: err.SourceLocation, message: []const u8) void {
    const source = getSourceForLocation(location) orelse return;
    const error_line = location.line; // 1-based

    // Split source into lines (max 512 lines for display)
    var lines: [512][]const u8 = undefined;
    var line_count: u32 = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        if (line_count >= lines.len) break;
        lines[line_count] = line;
        line_count += 1;
    }

    if (error_line == 0 or error_line > line_count) return;

    // Display range: ±2 lines around error
    const context: u32 = 2;
    const start = if (error_line > context) error_line - context else 1;
    const end = @min(error_line + context, line_count);
    const max_digits = countDigits(end);

    w.writeByte('\n') catch {};
    var line_num: u32 = start;
    while (line_num <= end) : (line_num += 1) {
        const line_text = lines[line_num - 1];
        writeLineNumber(w, line_num, max_digits);
        w.print(" | {s}\n", .{line_text}) catch {};
        if (line_num == error_line) {
            writeErrorPointer(w, max_digits, location.column, message);
        }
    }
    w.writeByte('\n') catch {};
}

fn writeLineNumber(w: anytype, line_num: u32, width: u32) void {
    const digits = countDigits(line_num);
    w.writeAll("  ") catch {};
    var pad: u32 = 0;
    while (pad + digits < width) : (pad += 1) {
        w.writeByte(' ') catch {};
    }
    w.print("{d}", .{line_num}) catch {};
}

fn writeErrorPointer(w: anytype, max_digits: u32, column: u32, message: []const u8) void {
    // "  " + digits + " | " = 2 + max_digits + 3
    const prefix_len = 2 + max_digits + 3;
    var i: u32 = 0;
    while (i < prefix_len + column) : (i += 1) {
        w.writeByte(' ') catch {};
    }
    w.print("^--- {s}\n", .{message}) catch {};
}

fn countDigits(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

fn getSourceForLocation(location: err.SourceLocation) ?[]const u8 {
    // Try file path first
    if (location.file) |file_path| {
        if (readFileForError(file_path)) |content| {
            return content;
        }
    }
    // Fallback: cached source text (REPL / -e)
    return err.getSourceText();
}

var file_read_buf: [64 * 1024]u8 = undefined;
fn readFileForError(path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const bytes_read = file.readAll(&file_read_buf) catch return null;
    return file_read_buf[0..bytes_read];
}

// === Value formatting ===

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
        .regex => |p| {
            w.print("#\"{s}\"", .{p.source}) catch {};
        },
        .char => |c| {
            var char_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &char_buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(char_buf[0..len]) catch {};
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
        .delay => |d| {
            if (d.realized) {
                w.print("#delay[", .{}) catch {};
                if (d.cached) |v| writeValue(w, v) else w.print("nil", .{}) catch {};
                w.print("]", .{}) catch {};
            } else {
                w.print("#delay[pending]", .{}) catch {};
            }
        },
        .reduced => |r| writeValue(w, r.value),
        .transient_vector => w.print("#<TransientVector>", .{}) catch {},
        .transient_map => w.print("#<TransientMap>", .{}) catch {},
        .transient_set => w.print("#<TransientSet>", .{}) catch {},
        .chunked_cons => |cc| {
            w.print("(", .{}) catch {};
            var i: usize = 0;
            while (i < cc.chunk.count()) : (i += 1) {
                if (i > 0) w.print(" ", .{}) catch {};
                const elem = cc.chunk.nth(i) orelse Value.nil;
                writeValue(w, elem);
            }
            if (cc.more != .nil) w.print(" ...", .{}) catch {};
            w.print(")", .{}) catch {};
        },
        .chunk_buffer => w.print("#<ChunkBuffer>", .{}) catch {},
        .array_chunk => w.print("#<ArrayChunk>", .{}) catch {},
    }
}
