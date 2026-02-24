// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Execution engine: REPL, eval, error reporting, build, embedded payload.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("../runtime/env.zig").Env;
const registry = @import("../lang/registry.zig");
const bootstrap = @import("../engine/bootstrap.zig");
const bootstrap_cache = @import("bootstrap_cache");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const collections = @import("../runtime/collections.zig");
const nrepl = @import("repl/nrepl.zig");
const line_editor = @import("repl/line_editor.zig");
const err = @import("../runtime/error.zig");
const gc_mod = @import("../runtime/gc.zig");
const vm_mod = @import("../engine/vm/vm.zig");
const ns_ops = @import("../lang/builtins/ns_ops.zig");
const http_server = @import("../lang/builtins/http_server.zig");
const lifecycle = @import("../runtime/lifecycle.zig");
const deps_mod = @import("deps.zig");

const build_options = @import("build_options");
pub const version_string = "ClojureWasm v" ++ build_options.version ++ "\n";

/// Magic trailer bytes appended to built binaries.
const embed_magic = "CLJW";
/// Trailer size: u64 payload_size (8) + magic (4) = 12 bytes.
const embed_trailer_size = 12;

// === Embedded payload handling ===

/// Handle embedded payload in built binaries.
/// Dispatches to bytecode or source evaluation, with optional nREPL support.
pub fn handleEmbedded(alloc: Allocator, allocator: Allocator, gc: *gc_mod.MarkSweepGc, payload: []const u8, args: []const [:0]const u8) void {
    if (isBytecodeModule(payload)) {
        runEmbeddedBytecode(alloc, allocator, gc, payload);
    } else {
        // Parse --nrepl flag for built binaries.
        // Usage: ./myapp --nrepl [port] [other args...]
        var embed_nrepl_port: ?u16 = null;
        var filtered_buf: [256][:0]const u8 = undefined;
        var filtered_count: usize = 0;
        {
            var ai: usize = 1;
            while (ai < args.len) : (ai += 1) {
                if (std.mem.eql(u8, args[ai], "--nrepl")) {
                    // Check if next arg is a port number
                    if (ai + 1 < args.len) {
                        if (std.fmt.parseInt(u16, args[ai + 1], 10)) |p| {
                            embed_nrepl_port = p;
                            ai += 1;
                            continue;
                        } else |_| {}
                    }
                    embed_nrepl_port = 0; // auto-assign
                } else if (filtered_count < filtered_buf.len) {
                    filtered_buf[filtered_count] = args[ai];
                    filtered_count += 1;
                }
            }
        }
        const filtered_args = filtered_buf[0..filtered_count];

        err.setSourceFile("<embedded>");
        err.setSourceText(payload);
        if (embed_nrepl_port) |port| {
            evalEmbeddedWithNrepl(alloc, allocator, gc, payload, filtered_args, port);
        } else {
            evalEmbedded(alloc, allocator, gc, payload, filtered_args);
        }
    }
}

// === REPL ===

pub fn runRepl(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);

    // Use line editor if stdin is a TTY, otherwise fall back to simple reader
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        runReplSimple(allocator, env, gc);
        return;
    }

    _ = stdout.write(version_string) catch {};

    var editor = line_editor.LineEditor.init(allocator, env);
    defer editor.deinit();

    while (true) {
        // Update prompt to reflect current namespace
        const ns_name = if (env.current_ns) |ns| ns.name else "user";
        editor.setNsPrompt(ns_name);

        const source = editor.readInput() orelse {
            _ = stdout.write("\n") catch {};
            break;
        };

        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (trimmed.len == 0) continue;

        // REPL special commands
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit") or
            std.mem.eql(u8, trimmed, ":q"))
        {
            break;
        }
        if (std.mem.eql(u8, trimmed, ":help") or std.mem.eql(u8, trimmed, ":h")) {
            _ = stdout.write(
                \\REPL commands:
                \\  :quit, :exit, :q   Exit REPL
                \\  :help, :h          Show this help
                \\  (doc fn-name)      Show documentation for a function
                \\  (source fn-name)   Show source for a function
                \\Keybindings (Emacs):
                \\  C-a/C-e            Beginning/end of line
                \\  C-k/C-u            Kill to end/start of line
                \\  C-w                Kill word backward
                \\  C-y                Yank (paste)
                \\  Alt-f/Alt-b        Forward/backward word
                \\  C-p/C-n            History previous/next
                \\  C-l                Clear screen
                \\  C-c                Cancel input
                \\  C-d                EOF (exit) on empty line
                \\  Tab                Complete symbol
                \\  Alt-Enter          Force newline
                \\
            ) catch {};
            continue;
        }

        err.setSourceText(source);

        // Evaluate per-form, printing each result immediately (interleaved with side-effects)
        var repl_ctx = ReplPrintCtx{ .allocator = allocator, .env = env, .is_tty = is_tty };
        const observer = bootstrap.FormObserver{
            .context = @ptrCast(&repl_ctx),
            .onResult = ReplPrintCtx.onResult,
        };
        _ = bootstrap.evalStringObserved(allocator, env, source, observer) catch |eval_err| {
            reportError(eval_err);
            gc.collectIfNeeded(.{ .env = env });
            continue;
        };

        // GC safe point
        gc.collectIfNeeded(.{ .env = env });
    }
}

/// Simple REPL for non-TTY stdin (piped input).
fn runReplSimple(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    var line_buf: [65536]u8 = undefined;
    var input_buf: [65536]u8 = undefined;
    var input_len: usize = 0;
    var depth: i32 = 0;

    var repl_ctx = ReplPrintCtx{ .allocator = allocator, .env = env, .is_tty = false };
    const observer = bootstrap.FormObserver{
        .context = @ptrCast(&repl_ctx),
        .onResult = ReplPrintCtx.onResult,
    };

    while (true) {
        const line_end = readLine(stdin, &line_buf) orelse {
            // EOF: evaluate remaining input if any
            if (input_len > 0) {
                const source = input_buf[0..input_len];
                err.setSourceText(source);
                _ = bootstrap.evalStringObserved(allocator, env, source, observer) catch |eval_err| {
                    reportError(eval_err);
                    break;
                };
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

        _ = bootstrap.evalStringObserved(allocator, env, source, observer) catch |eval_err| {
            reportError(eval_err);
            gc.collectIfNeeded(.{ .env = env });
            input_len = 0;
            depth = 0;
            continue;
        };

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

// === Eval ===

pub const EvalMode = enum { expr, file };

/// Observer context for printing each form's result immediately after evaluation.
/// This ensures correct interleaving with side-effects (e.g. println output appears
/// between result values, matching standard Clojure behavior).
const ExprPrintCtx = struct {
    allocator: Allocator,
    env: *Env,

    fn onResult(ctx_ptr: *anyopaque, val: Value) void {
        const self: *ExprPrintCtx = @ptrCast(@alignCast(ctx_ptr));
        if (val.isNil()) return;
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        var buf: [65536]u8 = undefined;
        const output = formatValue(&buf, val, self.allocator, self.env);
        _ = stdout.write(output) catch {};
        _ = stdout.write("\n") catch {};
    }
};

/// Observer for REPL: prints all results including nil.
const ReplPrintCtx = struct {
    allocator: Allocator,
    env: *Env,
    is_tty: bool,

    fn onResult(ctx_ptr: *anyopaque, val: Value) void {
        const self: *ReplPrintCtx = @ptrCast(@alignCast(ctx_ptr));
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        var buf: [65536]u8 = undefined;
        const output = formatValue(&buf, val, self.allocator, self.env);
        if (self.is_tty) {
            var color_buf: [65536 + 32]u8 = undefined;
            const colored = colorizeValue(&color_buf, output, val);
            _ = stdout.write(colored) catch {};
        } else {
            _ = stdout.write(output) catch {};
        }
        _ = stdout.write("\n") catch {};
    }
};

pub fn evalAndPrint(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, use_vm: bool, dump_bytecode: bool, mode: EvalMode) void {
    // Env uses infra_alloc (GPA) for Namespace/Var/HashMap internals.
    // bootstrap and evaluation use gc_alloc (MarkSweepGc) for Values.
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

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

    if (mode == .file) {
        // File mode: evaluate all forms, no result printing (like clj script.clj)
        if (use_vm) {
            _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
                reportError(e);
                std.process.exit(1);
            };
        } else {
            _ = bootstrap.evalString(gc_alloc, &env, source) catch |e| {
                reportError(e);
                std.process.exit(1);
            };
        }
    } else {
        // Expr mode (-e): evaluate per-form, print each non-nil result (like clj -e)
        var ctx = ExprPrintCtx{ .allocator = gc_alloc, .env = &env };
        const observer = bootstrap.FormObserver{
            .context = @ptrCast(&ctx),
            .onResult = ExprPrintCtx.onResult,
        };
        if (use_vm) {
            _ = bootstrap.evalStringVMObserved(gc_alloc, &env, source, observer) catch |e| {
                reportError(e);
                std.process.exit(1);
            };
        } else {
            _ = bootstrap.evalStringObserved(gc_alloc, &env, source, observer) catch |e| {
                reportError(e);
                std.process.exit(1);
            };
        }
    }

    // Run shutdown hooks if shutdown was requested (e.g. SIGINT during run-server)
    if (lifecycle.isShutdownRequested()) {
        lifecycle.runShutdownHooks(gc_alloc, &env);
    }
}

/// Run a main namespace: require ns then invoke -main.
pub fn runMainNs(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, main_ns: []const u8, use_vm: bool) void {
    _ = use_vm;
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Require the namespace, then call -main
    var buf: [4096]u8 = undefined;
    const run_expr = std.fmt.bufPrint(&buf, "(do (require '{s}) ({s}/-main))", .{ main_ns, main_ns }) catch {
        std.debug.print("Error: namespace name too long\n", .{});
        std.process.exit(1);
    };
    _ = bootstrap.evalString(gc_alloc, &env, run_expr) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Run -X exec mode: require namespace, invoke function with args.
pub fn runExecFn(
    gc_alloc: Allocator,
    infra_alloc: Allocator,
    gc: *gc_mod.MarkSweepGc,
    fn_name: []const u8,
    cli_args: []const []const u8,
    alias_args: []const deps_mod.ExecArg,
    use_vm: bool,
) void {
    _ = use_vm;
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Parse fn_name: "ns/fn" → require ns, call ns/fn
    const slash_idx = std.mem.indexOf(u8, fn_name, "/");
    if (slash_idx) |idx| {
        const ns_part = fn_name[0..idx];
        // Require the namespace
        var req_buf: [4096]u8 = undefined;
        const require_expr = std.fmt.bufPrint(&req_buf, "(require '{s})", .{ns_part}) catch {
            _ = stderr.write("Error: namespace name too long\n") catch {};
            std.process.exit(1);
        };
        _ = bootstrap.evalString(gc_alloc, &env, require_expr) catch |e| {
            reportError(e);
            std.process.exit(1);
        };
    }

    // Build the invocation expression: (fn-name {:key "val" ...})
    var call_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&call_buf);
    const w = stream.writer();
    w.print("({s}", .{fn_name}) catch {};

    // Build args map from alias exec-args + CLI override args.
    // CLI args override alias args with the same key.
    const has_args = alias_args.len > 0 or cli_args.len > 0;
    if (has_args) {
        w.writeAll(" {") catch {};
        // Collect CLI keys for override checking
        var cli_keys: [16][]const u8 = undefined;
        var cli_key_count: usize = 0;
        {
            var ci: usize = 0;
            while (ci < cli_args.len) : (ci += 1) {
                const carg = cli_args[ci];
                if (carg.len > 1 and carg[0] == ':' and ci + 1 < cli_args.len) {
                    if (cli_key_count < cli_keys.len) {
                        cli_keys[cli_key_count] = carg[1..]; // strip leading ':'
                        cli_key_count += 1;
                    }
                    ci += 1; // skip value
                }
            }
        }
        // Alias args (skip if overridden by CLI)
        for (alias_args) |ea| {
            var overridden = false;
            for (cli_keys[0..cli_key_count]) |ck| {
                if (std.mem.eql(u8, ea.key, ck)) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                w.print(" :{s} \"{s}\"", .{ ea.key, ea.value }) catch {};
            }
        }
        // CLI args: :key val pairs
        var ci: usize = 0;
        while (ci < cli_args.len) : (ci += 1) {
            const carg = cli_args[ci];
            if (carg.len > 0 and carg[0] == ':' and ci + 1 < cli_args.len) {
                w.print(" {s} \"{s}\"", .{ carg, cli_args[ci + 1] }) catch {};
                ci += 1;
            }
        }
        w.writeAll("}") catch {};
    }
    w.writeAll(")") catch {};

    const call_expr = stream.getWritten();
    _ = bootstrap.evalString(gc_alloc, &env, call_expr) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

// === Bootstrap ===

/// Initialize env from pre-compiled bootstrap cache (D81).
/// Registers builtins (Zig function pointers), then restores Clojure-defined
/// Vars from the serialized env snapshot embedded at build time.
/// Protocols are created as Zig builtins in registerBuiltins() (Phase B.3).
/// Reducers still loaded from .clj via bootstrap cache.
pub fn bootstrapFromCache(gc_alloc: Allocator, env: *Env, gc: ?*gc_mod.MarkSweepGc) void {
    registry.registerBuiltins(env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        std.process.exit(1);
    };
    bootstrap.restoreFromBootstrapCache(gc_alloc, env, bootstrap_cache.data) catch {
        if (err.getLastError()) |e| {
            std.debug.print("Error: failed to restore bootstrap cache: {s}\n", .{e.message});
        } else {
            std.debug.print("Error: failed to restore bootstrap cache\n", .{});
        }
        std.process.exit(1);
    };
    markBootstrapLibs();

    // Enable GC after cache restore for subsequent evaluation.
    if (gc) |g| {
        g.threshold = @max(g.bytes_allocated * 2, g.threshold);
        env.gc = @ptrCast(g);
    }
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
        "clojure.repl",
        "clojure.java.shell",
        "clojure.java.browse",
        "clojure.pprint",
        "clojure.stacktrace",
        "clojure.zip",
        "clojure.core.protocols",
        "clojure.core.reducers",
        "clojure.datafy",
        "clojure.repl.deps",
        "clojure.xml",
        // spec.alpha loaded lazily on first require
    };
    for (libs) |name| {
        ns_ops.markLibLoaded(name) catch {};
    }
}

// === Error reporting ===

const Ansi = struct {
    bold: []const u8,
    red: []const u8,
    dim: []const u8,
    cyan: []const u8,
    reset: []const u8,

    const color: Ansi = .{
        .bold = "\x1b[1m",
        .red = "\x1b[31m",
        .dim = "\x1b[2m",
        .cyan = "\x1b[36m",
        .reset = "\x1b[0m",
    };

    const plain: Ansi = .{
        .bold = "",
        .red = "",
        .dim = "",
        .cyan = "",
        .reset = "",
    };
};

pub fn reportError(eval_err: anyerror) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const c = if (std.posix.isatty(std.posix.STDERR_FILENO)) Ansi.color else Ansi.plain;

    if (err.getLastError()) |info| {
        // Header: "Type error at REPL:1:5" or "Type error"
        const kind_label = kindToLabel(info.kind);
        if (info.location.line > 0) {
            const file = info.location.file orelse "REPL";
            w.print("{s}{s}{s}{s} at {s}:{d}:{d}{s}\n", .{
                c.bold, c.red, kind_label, c.reset,
                file,   info.location.line, info.location.column, c.reset,
            }) catch {};
        } else {
            w.print("{s}{s}{s}{s}\n", .{ c.bold, c.red, kind_label, c.reset }) catch {};
        }
        // Message
        w.print("  {s}\n", .{info.message}) catch {};
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
        // No detailed error info — map raw Zig error to user-friendly label
        const fallback_label = errorToLabel(eval_err);
        w.print("{s}{s}{s}{s}\n", .{ c.bold, c.red, fallback_label, c.reset }) catch {};
        w.print("  An error occurred during evaluation\n", .{}) catch {};
        if (err.getSourceFile()) |file| {
            w.print("{s}  in {s}{s}\n", .{ c.dim, file, c.reset }) catch {};
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

fn kindToLabel(kind: err.Kind) []const u8 {
    return switch (kind) {
        .syntax_error => "Syntax error",
        .number_error => "Number format error",
        .string_error => "String format error",
        .name_error => "Name error",
        .arity_error => "Arity error",
        .value_error => "Value error",
        .type_error => "Type error",
        .arithmetic_error => "Arithmetic error",
        .index_error => "Index error",
        .io_error => "IO error",
        .internal_error => "Internal error",
        .out_of_memory => "Out of memory",
    };
}

fn errorToLabel(e: anyerror) []const u8 {
    return switch (e) {
        error.SyntaxError => "Syntax error",
        error.NumberError => "Number format error",
        error.StringError => "String format error",
        error.NameError => "Name error",
        error.ArityError => "Arity error",
        error.ValueError => "Value error",
        error.TypeError => "Type error",
        error.ArithmeticError => "Arithmetic error",
        error.IndexError => "Index error",
        error.IoError => "IO error",
        error.InternalError => "Internal error",
        error.OutOfMemory => "Out of memory",
        error.StackOverflow => "Stack overflow",
        error.UserException => "Exception",
        error.EvalError => "Evaluation error",
        else => "Error",
    };
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

threadlocal var file_read_buf: [64 * 1024]u8 = undefined;
fn readFileForError(path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const bytes_read = file.readAll(&file_read_buf) catch return null;
    return file_read_buf[0..bytes_read];
}

// === Value formatting ===

fn formatValue(buf: []u8, val: Value, allocator: Allocator, env: *Env) []const u8 {
    // Set up eval context so lazy-seq realization works (needs macro_eval_env)
    const prev = bootstrap.setupMacroEnv(env);
    defer bootstrap.restoreMacroEnv(prev);
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var w: std.Io.Writer = .fixed(buf);
    val.formatPrStr(&w) catch {};
    return w.buffered();
}

/// Wrap pre-formatted value text with ANSI color based on value type.
fn colorizeValue(buf: []u8, text: []const u8, val: Value) []const u8 {
    const color: []const u8 = switch (val.tag()) {
        .nil, .boolean => "\x1b[35m", // magenta
        .integer, .float => "\x1b[34m", // blue
        .string, .char, .regex => "\x1b[32m", // green
        .keyword => "\x1b[36m", // cyan
        .symbol => "\x1b[33m", // yellow
        else => "", // no color for collections, fns, etc.
    };
    if (color.len == 0) {
        // No coloring — return original text directly
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const reset = "\x1b[0m";
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    w.writeAll(color) catch {};
    w.writeAll(text) catch {};
    w.writeAll(reset) catch {};
    return stream.getWritten();
}

// === Single Binary Builder (Phase 28) ===

/// Read embedded source from this binary's CLJW trailer.
/// Returns null if no trailer found (normal cljw binary).
pub fn readEmbeddedSource(allocator: Allocator) ?[]const u8 {
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
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set *command-line-args*
    setCommandLineArgs(gc_alloc, &env, cli_args);

    // Evaluate using VM backend
    _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Run shutdown hooks (relevant when run-server returns via SIGINT)
    if (lifecycle.isShutdownRequested()) {
        lifecycle.runShutdownHooks(gc_alloc, &env);
    }
}

/// Start nREPL server with a file pre-evaluated.
/// Used by: cljw --nrepl-server --port=N file.clj
pub fn startNreplWithFile(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, filepath: []const u8, nrepl_port: u16) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set up load paths for require resolution
    const dir = std.fs.path.dirname(filepath) orelse ".";
    ns_ops.addLoadPath(dir) catch {};
    ns_ops.detectAndAddSrcPath(dir) catch {};

    const max_file_size = 10 * 1024 * 1024;
    const file_bytes = std.fs.cwd().readFileAlloc(infra_alloc, filepath, max_file_size) catch {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: could not read file\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(file_bytes);

    err.setSourceFile(filepath);
    err.setSourceText(file_bytes);

    // HTTP servers should run in background so nREPL can start after eval.
    http_server.background_mode = true;

    // Evaluate file (defines user namespaces/defs)
    _ = bootstrap.evalString(gc_alloc, &env, file_bytes) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Start nREPL server with user's Env (blocking accept loop).
    nrepl.startServerWithEnv(infra_alloc, &env, gc, nrepl_port) catch |e| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: nREPL server failed: ") catch {};
        _ = stderr.write(@errorName(e)) catch {};
        _ = stderr.write("\n") catch {};
        std.process.exit(1);
    };

    lifecycle.runShutdownHooks(gc_alloc, &env);
}

/// Evaluate embedded source, then start nREPL server on the same Env.
/// Used by built binaries with --nrepl flag.
fn evalEmbeddedWithNrepl(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, cli_args: []const [:0]const u8, nrepl_port: u16) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    setCommandLineArgs(gc_alloc, &env, cli_args);

    // HTTP servers should run in background so nREPL can start after eval.
    http_server.background_mode = true;

    // Evaluate embedded source (defines user namespaces/defs)
    _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Start nREPL server with user's Env (blocking accept loop).
    // Returns when shutdown signal is received.
    nrepl.startServerWithEnv(infra_alloc, &env, gc, nrepl_port) catch |e| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: nREPL server failed: ") catch {};
        _ = stderr.write(@errorName(e)) catch {};
        _ = stderr.write("\n") catch {};
        std.process.exit(1);
    };

    // Run user-registered shutdown hooks before exit
    lifecycle.runShutdownHooks(gc_alloc, &env);
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
/// Evaluates the entry file to resolve all requires, then bundles dependency
/// sources (in load order) + entry source into a single binary.
pub fn handleBuildCommand(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, build_args: []const [:0]const u8) void {
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

    // Read entry file source
    const max_file_size = 10 * 1024 * 1024; // 10MB
    const user_source = std.fs.cwd().readFileAlloc(infra_alloc, source_file.?, max_file_size) catch {
        _ = stderr.write("Error: could not read source file\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(user_source);

    // Bootstrap runtime from cache
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set up load paths from entry file directory
    const dir = std.fs.path.dirname(source_file.?) orelse ".";
    ns_ops.addLoadPath(dir) catch {};
    ns_ops.detectAndAddSrcPath(dir) catch {};

    // Enable file tracking, then evaluate entry file to resolve all requires.
    // Each file loaded by require is recorded in load order.
    ns_ops.enableFileTracking();
    http_server.build_mode = true;
    _ = bootstrap.evalStringVM(gc_alloc, &env, user_source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Collect dependency sources (in load order) and bundle with entry source
    const loaded_files = ns_ops.getLoadedFiles();
    var bundled_size: usize = user_source.len;
    for (loaded_files) |rec| {
        bundled_size += rec.content.len + 1; // +1 for newline separator
    }
    const bundled = infra_alloc.alloc(u8, bundled_size) catch {
        _ = stderr.write("Error: out of memory\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(bundled);

    var offset: usize = 0;
    for (loaded_files) |rec| {
        @memcpy(bundled[offset..][0..rec.content.len], rec.content);
        offset += rec.content.len;
        bundled[offset] = '\n';
        offset += 1;
    }
    @memcpy(bundled[offset..][0..user_source.len], user_source);

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
    const self_bytes = std.fs.cwd().readFileAlloc(infra_alloc, self_path, 100 * 1024 * 1024) catch {
        _ = stderr.write("Error: could not read self executable\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(self_bytes);

    // Write output: [self binary] + [bundled source] + [u64 size] + "CLJW"
    const out_file = std.fs.cwd().createFile(out_name, .{ .mode = 0o755 }) catch {
        _ = stderr.write("Error: could not create output file\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    out_file.writeAll(self_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(bundled) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    const size_bytes = std.mem.toBytes(std.mem.nativeTo(u64, @as(u64, @intCast(bundled.len)), .little));
    out_file.writeAll(&size_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(embed_magic) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };

    // Report success
    const dep_count = loaded_files.len;
    const total_size = self_bytes.len + bundled.len + embed_trailer_size;
    var msg_buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&msg_buf);
    const w = stream.writer();
    if (dep_count > 0) {
        w.print("Built: {s} ({d} bytes, {d} deps, source: {d} bytes)\n", .{ out_name, total_size, dep_count, bundled.len }) catch {};
    } else {
        w.print("Built: {s} ({d} bytes, source: {d} bytes)\n", .{ out_name, total_size, bundled.len }) catch {};
    }
    _ = stdout.write(stream.getWritten()) catch {};
}

/// Run embedded bytecode payload (built binary with compiled .cljc).
/// Like evalEmbedded but for bytecode — does NOT print the result (scripts handle output).
fn runEmbeddedBytecode(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, module_bytes: []const u8) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

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
