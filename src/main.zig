// ClojureWasm CLI entry point.
//
// Usage:
//   cljw -e "expr"           Evaluate expression and print result
//   cljw file.clj            Evaluate file and print last result
//   cljw                     Start interactive REPL
//   cljw build file.clj -o app  Build single binary with embedded code

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("common/env.zig").Env;
const registry = @import("common/builtin/registry.zig");
const bootstrap = @import("common/bootstrap.zig");
const bootstrap_cache = @import("bootstrap_cache");
const Value = @import("common/value.zig").Value;
const collections = @import("common/collections.zig");
const nrepl = @import("repl/nrepl.zig");
const line_editor = @import("repl/line_editor.zig");
const err = @import("common/error.zig");
const gc_mod = @import("common/gc.zig");
const keyword_intern = @import("common/keyword_intern.zig");
const ns_ops = @import("common/builtin/ns_ops.zig");
const Reader = @import("common/reader/reader.zig").Reader;
const FormData = @import("common/reader/form.zig").FormData;

/// Magic trailer bytes appended to built binaries.
const embed_magic = "CLJW";
/// Trailer size: u64 payload_size (8) + magic (4) = 12 bytes.
const embed_trailer_size = 12;

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

    // Initialize load path infrastructure for require/load
    ns_ops.init(allocator);
    defer ns_ops.deinit();

    // Check for embedded payload (built binary via `cljw build`).
    // If this binary has a CLJW trailer, run the embedded payload and exit.
    // Payload may be raw .clj source or compiled bytecode (detected by CLJC magic).
    if (readEmbeddedSource(allocator)) |payload| {
        defer allocator.free(payload);
        if (isBytecodeModule(payload)) {
            runEmbeddedBytecode(alloc, allocator, &gc, payload);
        } else {
            err.setSourceFile("<embedded>");
            err.setSourceText(payload);
            evalEmbedded(alloc, allocator, &gc, payload, args[1..]);
        }
        return;
    }

    // Handle `build` subcommand: cljw build <file> [-o <output>]
    if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) {
        handleBuildCommand(allocator, args[2..]);
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

    // Load cljw.edn config if present (search CWD and entry file directory).
    // Uses arena for config parsing — freed when config is no longer needed.
    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();
    const config_alloc = config_arena.allocator();
    const file_dir = if (file) |f| std.fs.path.dirname(f) else null;
    const config = if (findConfigFile(config_alloc, file_dir)) |content|
        parseConfig(config_alloc, content)
    else
        ProjectConfig{};
    applyConfig(config, file_dir);

    if (expr) |e| {
        err.setSourceFile(null);
        err.setSourceText(e);
        evalAndPrint(alloc, allocator, &gc, e, use_vm, dump_bytecode);
    } else if (file) |f| {
        // Add entry file's directory and detect src/ for require resolution
        if (std.fs.path.dirname(f)) |dir| {
            ns_ops.addLoadPath(dir) catch {};
            ns_ops.detectAndAddSrcPath(dir) catch {};
        }

        const max_file_size = 10 * 1024 * 1024; // 10MB
        const file_bytes = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file (max 10MB)\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(file_bytes);

        err.setSourceFile(f);
        err.setSourceText(file_bytes);
        evalAndPrint(alloc, allocator, &gc, file_bytes, use_vm, dump_bytecode);
    } else if (config.main_ns) |main_ns| {
        // cljw.edn :main — load the main namespace
        runMainNs(alloc, allocator, &gc, main_ns, use_vm);
    } else {
        // No args, no file, no :main — start REPL
        var env = Env.init(allocator);
        defer env.deinit();
        bootstrapFromCache(alloc, &env);
        gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
        env.gc = @ptrCast(&gc);
        runRepl(alloc, &env, &gc);
    }
}

fn runRepl(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Use line editor if stdin is a TTY, otherwise fall back to simple reader
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        runReplSimple(allocator, env, gc);
        return;
    }

    _ = stdout.write("ClojureWasm v0.1.0\n") catch {};

    var editor = line_editor.LineEditor.init(allocator, env);
    defer editor.deinit();

    while (true) {
        const source = editor.readInput() orelse {
            _ = stdout.write("\n") catch {};
            break;
        };

        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (trimmed.len == 0) continue;

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

        // GC safe point
        gc.collectIfNeeded(.{ .env = env });
    }
}

/// Simple REPL for non-TTY stdin (piped input).
fn runReplSimple(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

    var line_buf: [65536]u8 = undefined;
    var input_buf: [65536]u8 = undefined;
    var input_len: usize = 0;
    var depth: i32 = 0;

    while (true) {
        const line_end = readLine(stdin, &line_buf) orelse {
            // EOF: evaluate remaining input if any
            if (input_len > 0) {
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
            }
            break;
        };

        const trimmed = std.mem.trim(u8, line_buf[0..line_end], " \t\r");
        if (trimmed.len == 0 and depth == 0) continue;

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

        depth = countDelimiterDepth(input_buf[0..input_len]);
        if (depth > 0) continue;

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

        gc.collectIfNeeded(.{ .env = env });
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
    bootstrapFromCache(gc_alloc, &env);

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

/// Run a main namespace from cljw.edn :main config.
/// Bootstraps, then requires the namespace (which loads and runs it).
fn runMainNs(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, main_ns: []const u8, use_vm: bool) void {
    _ = use_vm;
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env);
    gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
    env.gc = @ptrCast(gc);

    // Generate and evaluate (require 'main-ns)
    var buf: [4096]u8 = undefined;
    const require_expr = std.fmt.bufPrint(&buf, "(require '{s})", .{main_ns}) catch {
        std.debug.print("Error: namespace name too long\n", .{});
        std.process.exit(1);
    };
    _ = bootstrap.evalString(gc_alloc, &env, require_expr) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Initialize env from pre-compiled bootstrap cache (D81).
/// Registers builtins (Zig function pointers), then restores Clojure-defined
/// Vars from the serialized env snapshot embedded at build time.
fn bootstrapFromCache(gc_alloc: Allocator, env: *Env) void {
    registry.registerBuiltins(env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        std.process.exit(1);
    };
    bootstrap.restoreFromBootstrapCache(gc_alloc, env, bootstrap_cache.data) catch {
        std.debug.print("Error: failed to restore bootstrap cache\n", .{});
        std.process.exit(1);
    };
    markBootstrapLibs();
}

/// Mark built-in namespaces as loaded so require skips them.
fn markBootstrapLibs() void {
    const libs = [_][]const u8{
        "clojure.core",
        "clojure.walk",
        "clojure.template",
        "clojure.test",
        "clojure.set",
        "clojure.data",
        "clojure.string",
        "clojure.edn",
        "clojure.stacktrace",
    };
    for (libs) |name| {
        ns_ops.markLibLoaded(name) catch {};
    }
}

// === cljw.edn config parsing ===

/// Parsed cljw.edn configuration.
const ProjectConfig = struct {
    paths: []const []const u8 = &.{},
    main_ns: ?[]const u8 = null,
};

/// Search for cljw.edn starting from dir, walking up to root.
/// Returns file content if found, null otherwise.
fn findConfigFile(allocator: Allocator, start_dir: ?[]const u8) ?[]const u8 {
    // Try CWD first
    if (readConfigFromDir(allocator, ".")) |content| return content;

    // Walk up from start_dir
    var current = start_dir orelse return null;
    for (0..10) |_| {
        if (readConfigFromDir(allocator, current)) |content| return content;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

fn readConfigFromDir(allocator: Allocator, dir: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/cljw.edn", .{dir}) catch return null;
    return std.fs.cwd().readFileAlloc(allocator, path, 10_000) catch null;
}

/// Parse cljw.edn content using the Reader (no bootstrap needed).
fn parseConfig(allocator: Allocator, source: []const u8) ProjectConfig {
    var reader = Reader.init(allocator, source);
    const form = reader.read() catch return .{};
    const root = form orelse return .{};

    if (root.data != .map) return .{};
    const entries = root.data.map;

    var config = ProjectConfig{};
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const kw = entries[i].data.keyword.name;

        if (std.mem.eql(u8, kw, "paths")) {
            if (entries[i + 1].data == .vector) {
                const vec = entries[i + 1].data.vector;
                const paths = allocator.alloc([]const u8, vec.len) catch continue;
                var count: usize = 0;
                for (vec) |elem| {
                    if (elem.data == .string) {
                        paths[count] = elem.data.string;
                        count += 1;
                    }
                }
                config.paths = paths[0..count];
            }
        } else if (std.mem.eql(u8, kw, "main")) {
            if (entries[i + 1].data == .symbol) {
                const sym = entries[i + 1].data.symbol;
                if (sym.ns) |ns| {
                    // Qualified: my-app/core → my-app.core
                    config.main_ns = std.fmt.allocPrint(allocator, "{s}.{s}", .{ ns, sym.name }) catch null;
                } else {
                    config.main_ns = sym.name;
                }
            }
        }
    }
    return config;
}

/// Apply cljw.edn config: add paths to load paths.
fn applyConfig(config: ProjectConfig, config_dir: ?[]const u8) void {
    for (config.paths) |path| {
        if (config_dir) |dir| {
            // Resolve relative paths against config file directory
            var buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
            ns_ops.addLoadPath(full) catch {};
        } else {
            ns_ops.addLoadPath(path) catch {};
        }
    }
}

// === Error reporting (babashka-style) ===

// ANSI color codes (empty strings when not a TTY)
const Ansi = struct {
    red: []const u8,
    bold: []const u8,
    dim: []const u8,
    cyan: []const u8,
    reset: []const u8,

    const color = Ansi{
        .red = "\x1b[31m",
        .bold = "\x1b[1m",
        .dim = "\x1b[2m",
        .cyan = "\x1b[36m",
        .reset = "\x1b[0m",
    };
    const plain = Ansi{
        .red = "",
        .bold = "",
        .dim = "",
        .cyan = "",
        .reset = "",
    };
};

fn reportError(eval_err: anyerror) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const c = if (std.posix.isatty(std.posix.STDERR_FILENO)) Ansi.color else Ansi.plain;

    if (err.getLastError()) |info| {
        w.print("{s}----- Error -----------------------------------------------{s}\n", .{ c.red, c.reset }) catch {};
        w.print("{s}{s}{s}{s}\n", .{ c.bold, c.red, info.message, c.reset }) catch {};
        if (info.location.line > 0) {
            const file = info.location.file orelse "<expr>";
            w.print("{s}{s}:{d}:{d}{s}\n", .{ c.dim, file, info.location.line, info.location.column, c.reset }) catch {};
        }
        if (info.phase != .eval) {
            w.print("{s}Phase: {s}{s}\n", .{ c.dim, @tagName(info.phase), c.reset }) catch {};
        }
        // Call stack trace
        const stack = err.getCallStack();
        if (stack.len > 0) {
            w.print("{s}Trace:{s}\n", .{ c.dim, c.reset }) catch {};
            var i: usize = stack.len;
            while (i > 0) {
                i -= 1;
                const f = stack[i];
                const ns_name = f.ns orelse "?";
                const fn_name = f.fn_name orelse "anonymous";
                if (f.file) |file| {
                    if (f.line > 0) {
                        w.print("{s}  {s}/{s} ({s}:{d}){s}\n", .{ c.dim, ns_name, fn_name, file, f.line, c.reset }) catch {};
                    } else {
                        w.print("{s}  {s}/{s} ({s}){s}\n", .{ c.dim, ns_name, fn_name, file, c.reset }) catch {};
                    }
                } else {
                    w.print("{s}  {s}/{s}{s}\n", .{ c.dim, ns_name, fn_name, c.reset }) catch {};
                }
            }
        }
        err.clearCallStack();
        // Source context
        if (info.location.line > 0) {
            showSourceContext(w, info.location, info.message, c);
        }
    } else {
        // No detailed error info — make fallback as helpful as possible
        w.print("{s}----- Error -----------------------------------------------{s}\n", .{ c.red, c.reset }) catch {};
        w.print("{s}{s}{s}{s}\n", .{ c.bold, c.red, @errorName(eval_err), c.reset }) catch {};
        if (err.getSourceFile()) |file| {
            w.print("{s}{s}{s}\n", .{ c.dim, file, c.reset }) catch {};
        }
        // Show call stack if available
        const stack = err.getCallStack();
        if (stack.len > 0) {
            w.print("{s}Trace:{s}\n", .{ c.dim, c.reset }) catch {};
            var i: usize = stack.len;
            while (i > 0) {
                i -= 1;
                const f = stack[i];
                const ns_name = f.ns orelse "?";
                const fn_name = f.fn_name orelse "anonymous";
                w.print("{s}  {s}/{s}{s}\n", .{ c.dim, ns_name, fn_name, c.reset }) catch {};
            }
        }
        err.clearCallStack();
    }

    _ = stderr.write(stream.getWritten()) catch {};
}

fn showSourceContext(w: anytype, location: err.SourceLocation, message: []const u8, c: Ansi) void {
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
        if (line_num == error_line) {
            w.print("{s}", .{c.dim}) catch {};
            writeLineNumber(w, line_num, max_digits);
            w.print(" | {s}{s}{s}\n", .{ c.reset, line_text, c.reset }) catch {};
            writeErrorPointer(w, max_digits, location.column, message, c);
        } else {
            w.print("{s}", .{c.dim}) catch {};
            writeLineNumber(w, line_num, max_digits);
            w.print(" | {s}{s}\n", .{ line_text, c.reset }) catch {};
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

fn writeErrorPointer(w: anytype, max_digits: u32, column: u32, message: []const u8, c: Ansi) void {
    // "  " + digits + " | " = 2 + max_digits + 3
    const prefix_len = 2 + max_digits + 3;
    var i: u32 = 0;
    while (i < prefix_len + column) : (i += 1) {
        w.writeByte(' ') catch {};
    }
    w.print("{s}^--- {s}{s}\n", .{ c.red, message, c.reset }) catch {};
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
    switch (val.tag()) {
        .nil => w.print("nil", .{}) catch {},
        .boolean => w.print("{}", .{val.asBoolean()}) catch {},
        .integer => w.print("{d}", .{val.asInteger()}) catch {},
        .float => w.print("{d}", .{val.asFloat()}) catch {},
        .string => w.print("\"{s}\"", .{val.asString()}) catch {},
        .keyword => {
            const k = val.asKeyword();
            if (k.ns) |ns| {
                w.print(":{s}/{s}", .{ ns, k.name }) catch {};
            } else {
                w.print(":{s}", .{k.name}) catch {};
            }
        },
        .symbol => {
            const s = val.asSymbol();
            if (s.ns) |ns| {
                w.print("{s}/{s}", .{ ns, s.name }) catch {};
            } else {
                w.print("{s}", .{s.name}) catch {};
            }
        },
        .list => {
            const lst = val.asList();
            w.print("(", .{}) catch {};
            for (lst.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print(")", .{}) catch {};
        },
        .vector => {
            const vec = val.asVector();
            w.print("[", .{}) catch {};
            for (vec.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("]", .{}) catch {};
        },
        .map => {
            const m = val.asMap();
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
        .hash_map => {
            const hm = val.asHashMap();
            w.print("{{", .{}) catch {};
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = hm.toEntries(arena.allocator()) catch &[_]Value{};
            var i: usize = 0;
            while (i < entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .set => {
            const s = val.asSet();
            w.print("#{{", .{}) catch {};
            for (s.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("}}", .{}) catch {};
        },
        .fn_val => w.print("#<fn>", .{}) catch {},
        .builtin_fn => w.print("#<builtin>", .{}) catch {},
        .atom => {
            const a = val.asAtom();
            w.print("(atom ", .{}) catch {};
            writeValue(w, a.value);
            w.print(")", .{}) catch {};
        },
        .volatile_ref => {
            const v = val.asVolatile();
            w.print("#<volatile ", .{}) catch {};
            writeValue(w, v.value);
            w.print(">", .{}) catch {};
        },
        .regex => {
            const p = val.asRegex();
            w.print("#\"{s}\"", .{p.source}) catch {};
        },
        .char => {
            const c = val.asChar();
            var char_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &char_buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(char_buf[0..len]) catch {};
        },
        .protocol => w.print("#<protocol {s}>", .{val.asProtocol().name}) catch {},
        .protocol_fn => {
            const pf = val.asProtocolFn();
            w.print("#<protocol-fn {s}/{s}>", .{ pf.protocol.name, pf.method_name }) catch {};
        },
        .multi_fn => w.print("#<multifn {s}>", .{val.asMultiFn().name}) catch {},
        .lazy_seq => {
            const ls = val.asLazySeq();
            if (ls.realized) |r| {
                writeValue(w, r);
            } else {
                w.print("#<lazy-seq>", .{}) catch {};
            }
        },
        .cons => {
            const c = val.asCons();
            w.print("(", .{}) catch {};
            writeValue(w, c.first);
            w.print(" . ", .{}) catch {};
            writeValue(w, c.rest);
            w.print(")", .{}) catch {};
        },
        .var_ref => {
            const v = val.asVarRef();
            w.print("#'{s}/{s}", .{ v.ns_name, v.sym.name }) catch {};
        },
        .delay => {
            const d = val.asDelay();
            if (d.realized) {
                w.print("#delay[", .{}) catch {};
                if (d.cached) |v| writeValue(w, v) else w.print("nil", .{}) catch {};
                w.print("]", .{}) catch {};
            } else {
                w.print("#delay[pending]", .{}) catch {};
            }
        },
        .reduced => writeValue(w, val.asReduced().value),
        .transient_vector => w.print("#<TransientVector>", .{}) catch {},
        .transient_map => w.print("#<TransientMap>", .{}) catch {},
        .transient_set => w.print("#<TransientSet>", .{}) catch {},
        .chunked_cons => {
            const cc = val.asChunkedCons();
            w.print("(", .{}) catch {};
            var i: usize = 0;
            while (i < cc.chunk.count()) : (i += 1) {
                if (i > 0) w.print(" ", .{}) catch {};
                const elem = cc.chunk.nth(i) orelse Value.nil_val;
                writeValue(w, elem);
            }
            if (cc.more.tag() != .nil) w.print(" ...", .{}) catch {};
            w.print(")", .{}) catch {};
        },
        .chunk_buffer => w.print("#<ChunkBuffer>", .{}) catch {},
        .array_chunk => w.print("#<ArrayChunk>", .{}) catch {},
        .wasm_module => w.print("#<WasmModule>", .{}) catch {},
        .wasm_fn => w.print("#<WasmFn {s}>", .{val.asWasmFn().name}) catch {},
    }
}

// === Single Binary Builder (Phase 28) ===

/// Read embedded source from this binary's CLJW trailer.
/// Returns null if no trailer found (normal cljw binary).
fn readEmbeddedSource(allocator: Allocator) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch return null;
    const file = std.fs.openFileAbsolute(self_path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size < embed_trailer_size) return null;

    // Read trailer (last 12 bytes)
    file.seekTo(file_size - embed_trailer_size) catch return null;
    var trailer: [embed_trailer_size]u8 = undefined;
    const n = file.readAll(&trailer) catch return null;
    if (n != embed_trailer_size) return null;

    // Check magic
    if (!std.mem.eql(u8, trailer[8..12], embed_magic)) return null;

    // Extract payload size
    const payload_size = std.mem.readInt(u64, trailer[0..8], .little);
    if (payload_size == 0 or payload_size > file_size - embed_trailer_size) return null;

    // Read payload
    file.seekTo(file_size - embed_trailer_size - payload_size) catch return null;
    const source = allocator.alloc(u8, @intCast(payload_size)) catch return null;
    const bytes_read = file.readAll(source) catch {
        allocator.free(source);
        return null;
    };
    if (bytes_read != @as(usize, @intCast(payload_size))) {
        allocator.free(source);
        return null;
    }
    return source;
}

/// Evaluate embedded source and exit. Used by built binaries.
fn evalEmbedded(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, cli_args: []const [:0]const u8) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env);

    // Set *command-line-args*
    setCommandLineArgs(gc_alloc, &env, cli_args);

    // Enable GC
    gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
    env.gc = @ptrCast(gc);

    // Evaluate using VM backend
    _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Set *command-line-args* to a list of string Values.
fn setCommandLineArgs(gc_alloc: Allocator, env: *Env, cli_args: []const [:0]const u8) void {
    if (cli_args.len == 0) return; // leave as nil

    const core_ns = env.findNamespace("clojure.core") orelse return;
    const v = core_ns.resolve("*command-line-args*") orelse return;

    // Build list of string Values
    const items = gc_alloc.alloc(Value, cli_args.len) catch return;
    for (cli_args, 0..) |arg, i| {
        const duped = gc_alloc.dupe(u8, arg) catch return;
        items[i] = Value.initString(gc_alloc, duped);
    }
    const list = gc_alloc.create(collections.PersistentList) catch return;
    list.* = .{ .items = items };
    v.bindRoot(Value.initList(list));
}

/// Handle `cljw build <file> [-o <output>]` subcommand.
fn handleBuildCommand(allocator: Allocator, build_args: []const [:0]const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    var source_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < build_args.len) : (i += 1) {
        if (std.mem.eql(u8, build_args[i], "-o")) {
            i += 1;
            if (i >= build_args.len) {
                _ = stderr.write("Error: -o requires an output file argument\n") catch {};
                std.process.exit(1);
            }
            output_file = build_args[i];
        } else {
            source_file = build_args[i];
        }
    }

    if (source_file == null) {
        _ = stderr.write("Usage: cljw build <source.clj> [-o <output>]\n") catch {};
        std.process.exit(1);
    }

    // Read user source
    const max_file_size = 10 * 1024 * 1024; // 10MB
    const user_source = std.fs.cwd().readFileAlloc(allocator, source_file.?, max_file_size) catch {
        _ = stderr.write("Error: could not read source file\n") catch {};
        std.process.exit(1);
    };
    defer allocator.free(user_source);

    // Determine output filename (default: strip .clj extension)
    const out_name = output_file orelse blk: {
        const src = source_file.?;
        if (std.mem.endsWith(u8, src, ".clj")) {
            break :blk src[0 .. src.len - 4];
        }
        break :blk src;
    };

    // Read self binary
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch {
        _ = stderr.write("Error: could not determine self executable path\n") catch {};
        std.process.exit(1);
    };
    const self_bytes = std.fs.cwd().readFileAlloc(allocator, self_path, 100 * 1024 * 1024) catch {
        _ = stderr.write("Error: could not read self executable\n") catch {};
        std.process.exit(1);
    };
    defer allocator.free(self_bytes);

    // Write output: [self binary] + [user source] + [u64 source_len] + "CLJW"
    const out_file = std.fs.cwd().createFile(out_name, .{ .mode = 0o755 }) catch {
        _ = stderr.write("Error: could not create output file\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    out_file.writeAll(self_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(user_source) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    // Write payload size as u64 LE
    const size_bytes = std.mem.toBytes(std.mem.nativeTo(u64, @as(u64, @intCast(user_source.len)), .little));
    out_file.writeAll(&size_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(embed_magic) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };

    // Report success
    const total_size = self_bytes.len + user_source.len + embed_trailer_size;
    var msg_buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&msg_buf);
    const w = stream.writer();
    w.print("Built: {s} ({d} bytes, source: {d} bytes)\n", .{ out_name, total_size, user_source.len }) catch {};
    _ = stdout.write(stream.getWritten()) catch {};
}

/// Run embedded bytecode payload (built binary with compiled .cljc).
/// Like evalEmbedded but for bytecode — does NOT print the result (scripts handle output).
fn runEmbeddedBytecode(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, module_bytes: []const u8) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env);
    gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);
    env.gc = @ptrCast(gc);

    _ = bootstrap.runBytecodeModule(gc_alloc, &env, module_bytes) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Check if bytes are a compiled bytecode Module (starts with "CLJC" magic).
fn isBytecodeModule(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], "CLJC");
}

