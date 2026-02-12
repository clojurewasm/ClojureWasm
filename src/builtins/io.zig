// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! I/O builtins — print, println, pr, prn, newline, flush
//!
//! println: Print args space-separated, non-readable, with trailing newline. Returns nil.
//! prn: Print args space-separated, readable, with trailing newline. Returns nil.
//!
//! Output goes to stdout by default. Tests can redirect via setOutputCapture().

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;
const err = @import("../runtime/error.zig");
const PersistentList = value_mod.PersistentList;
const bootstrap = @import("../runtime/bootstrap.zig");

// ============================================================
// Output capture for testing
// ============================================================

threadlocal var capture_buf: ?*std.ArrayList(u8) = null;
threadlocal var capture_alloc: ?Allocator = null;

/// Set an output capture buffer. Pass null to restore stdout.
pub fn setOutputCapture(alloc: ?Allocator, buf: ?*std.ArrayList(u8)) void {
    capture_buf = buf;
    capture_alloc = alloc;
}

pub fn writeOutput(data: []const u8) void {
    if (capture_buf) |buf| {
        buf.appendSlice(capture_alloc.?, data) catch {};
    } else {
        var wbuf: [4096]u8 = undefined;
        var file_writer = std.fs.File.stdout().writer(&wbuf);
        const w = &file_writer.interface;
        w.writeAll(data) catch {};
        w.flush() catch {};
    }
}

pub fn writeOutputByte(byte: u8) void {
    writeOutput(&[_]u8{byte});
}

// ============================================================
// Builtins
// ============================================================

/// (println) => nil (prints newline)
/// (println x) => nil (prints x + newline)
/// (println x y ...) => nil (prints space-separated + newline, non-readable)
pub fn printlnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (prn) => nil (prints newline)
/// (prn x) => nil (prints readable x + newline)
/// (prn x y ...) => nil (prints space-separated readable + newline)
pub fn prnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (print) => nil (prints nothing)
/// (print x) => nil (prints x, no newline)
/// (print x y ...) => nil (prints space-separated, non-readable, no newline)
pub fn printFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return Value.nil_val;
}

/// (pr) => nil (prints nothing)
/// (pr x) => nil (prints readable x, no newline)
/// (pr x y ...) => nil (prints space-separated readable, no newline)
pub fn prFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch break;
        arg.formatPrStr(&w) catch break;
    }
    writeOutput(w.buffered());
    return Value.nil_val;
}

/// (newline) => nil (prints newline character)
pub fn newlineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to newline", .{args.len});
    writeOutputByte('\n');
    return Value.nil_val;
}

/// (flush) => nil (flushes stdout)
pub fn flushFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to flush", .{args.len});
    if (capture_buf == null) {
        var wbuf: [4096]u8 = undefined;
        var file_writer = std.fs.File.stdout().writer(&wbuf);
        file_writer.interface.flush() catch {};
    }
    return Value.nil_val;
}

// ============================================================
// Output capture stack for with-out-str nesting
// ============================================================

const MAX_CAPTURE_DEPTH = 16;
const CaptureState = struct {
    buf: ?*std.ArrayList(u8),
    alloc: ?Allocator,
};

threadlocal var capture_stack: [MAX_CAPTURE_DEPTH]CaptureState = [_]CaptureState{.{ .buf = null, .alloc = null }} ** MAX_CAPTURE_DEPTH;
threadlocal var capture_depth: usize = 0;

/// (push-output-capture) — start capturing output to a fresh buffer.
fn pushOutputCaptureFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to push-output-capture", .{args.len});
    if (capture_depth >= MAX_CAPTURE_DEPTH) return err.setErrorFmt(.eval, .value_error, .{}, "Output capture stack overflow", .{});

    // Save current state
    capture_stack[capture_depth] = .{ .buf = capture_buf, .alloc = capture_alloc };
    capture_depth += 1;

    // Create new capture buffer
    const buf = allocator.create(std.ArrayList(u8)) catch return error.OutOfMemory;
    buf.* = .empty;
    setOutputCapture(allocator, buf);

    return Value.nil_val;
}

/// (pop-output-capture) — stop capturing, restore previous state, return captured string.
fn popOutputCaptureFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop-output-capture", .{args.len});
    if (capture_depth == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Output capture stack underflow", .{});

    // Get captured string
    const result: Value = if (capture_buf) |buf| blk: {
        const str = allocator.dupe(u8, buf.items) catch return error.OutOfMemory;
        buf.deinit(capture_alloc.?);
        break :blk Value.initString(allocator, str);
    } else Value.initString(allocator, "");

    // Restore previous state
    capture_depth -= 1;
    setOutputCapture(capture_stack[capture_depth].alloc, capture_stack[capture_depth].buf);

    return result;
}

// ============================================================
// Input source stack for with-in-str nesting
// ============================================================

const InputSource = struct {
    data: []const u8,
    pos: usize,
};

threadlocal var input_stack: [MAX_CAPTURE_DEPTH]?InputSource = [_]?InputSource{null} ** MAX_CAPTURE_DEPTH;
threadlocal var input_depth: usize = 0;
threadlocal var current_input: ?InputSource = null;

/// Returns the remaining unread data from the current input source, or null if no source.
pub fn getCurrentInputRemaining() ?[]const u8 {
    const input = current_input orelse return null;
    if (input.pos >= input.data.len) return "";
    return input.data[input.pos..];
}

/// Advance the current input source position by n bytes.
pub fn advanceCurrentInput(n: usize) void {
    if (current_input) |*input| {
        input.pos += n;
        if (input.pos > input.data.len) input.pos = input.data.len;
    }
}

/// Returns true if there is an active string input source (from with-in-str).
pub fn hasInputSource() bool {
    return current_input != null;
}

/// (push-input-source s) — redirect read-line to read from string s.
fn pushInputSourceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to push-input-source", .{args.len});
    if (input_depth >= MAX_CAPTURE_DEPTH) return err.setErrorFmt(.eval, .value_error, .{}, "Input source stack overflow", .{});

    // Save current state
    input_stack[input_depth] = current_input;
    input_depth += 1;

    // Set new input source
    current_input = .{ .data = args[0].asString(), .pos = 0 };
    return Value.nil_val;
}

/// (pop-input-source) — restore previous input source.
fn popInputSourceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop-input-source", .{args.len});
    if (input_depth == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Input source stack underflow", .{});

    input_depth -= 1;
    current_input = input_stack[input_depth];
    return Value.nil_val;
}

/// Read one line from the current input source (string). Returns null if exhausted.
fn readLineFromInput(allocator: Allocator) !?Value {
    const input = &(current_input orelse return null);
    if (input.pos >= input.data.len) return Value.nil_val; // EOF

    // Find next newline
    const remaining = input.data[input.pos..];
    const newline_idx = std.mem.indexOfScalar(u8, remaining, '\n');
    const line_end = newline_idx orelse remaining.len;

    // Strip trailing \r
    var line_len = line_end;
    if (line_len > 0 and remaining[line_len - 1] == '\r') line_len -= 1;

    const owned = try allocator.alloc(u8, line_len);
    @memcpy(owned, remaining[0..line_len]);

    // Advance position past the newline
    input.pos += line_end + (if (newline_idx != null) @as(usize, 1) else @as(usize, 0));

    return Value.initString(allocator, owned);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "print",
        .func = &printFn,
        .doc = "Prints the object(s) to the output stream. print and println produce output for human consumption.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "println",
        .func = &printlnFn,
        .doc = "Same as print followed by (newline).",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "pr",
        .func = &prFn,
        .doc = "Prints the object(s) to the output stream. Prints the object(s), separated by spaces if there is more than one. Objects are printed via the pr-str function.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "prn",
        .func = &prnFn,
        .doc = "Same as pr followed by (newline). Observes *print-readably*.",
        .arglists = "([& more])",
        .added = "1.0",
    },
    .{
        .name = "newline",
        .func = &newlineFn,
        .doc = "Writes a platform-specific newline to *out*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "flush",
        .func = &flushFn,
        .doc = "Flushes the output stream that is the current value of *out*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "push-output-capture",
        .func = &pushOutputCaptureFn,
        .doc = "Start capturing output. Used internally by with-out-str.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "pop-output-capture",
        .func = &popOutputCaptureFn,
        .doc = "Stop capturing output, return captured string. Used internally by with-out-str.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "push-input-source",
        .func = &pushInputSourceFn,
        .doc = "Redirect read-line to read from string. Used internally by with-in-str.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "pop-input-source",
        .func = &popInputSourceFn,
        .doc = "Restore previous input source. Used internally by with-in-str.",
        .arglists = "([])",
        .added = "1.0",
    },
};

// === Tests ===


// ============================================================
// File I/O builtins (slurp, spit, load-file, read-line, line-seq)
// ============================================================


// ============================================================
// Builtins
// ============================================================

/// (slurp filename) => string
/// Opens the file, reads all content as UTF-8 string, closes the file.
pub fn slurpFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to slurp", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "slurp expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.IOError;
    return Value.initString(allocator, content);
}

/// (spit filename content) => nil
/// (spit filename content :append true) => nil
/// Writes content to the file. Creates if not exists, truncates by default.
pub fn spitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to spit", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "spit expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    // Get content as string
    const content = switch (args[1].tag()) {
        .string => args[1].asString(),
        .nil => "",
        else => blk: {
            // Convert to string via formatStr
            var buf: [4096]u8 = undefined;
            var w: Writer = .fixed(&buf);
            args[1].formatStr(&w) catch break :blk @as([]const u8, "");
            const result = w.buffered();
            const owned = allocator.alloc(u8, result.len) catch break :blk @as([]const u8, "");
            @memcpy(owned, result);
            break :blk @as([]const u8, owned);
        },
    };

    // Check for :append true option
    var append = false;
    if (args.len >= 4) {
        if (args[2].tag() == .keyword) {
            if (std.mem.eql(u8, args[2].asKeyword().name, "append")) {
                if (args[3].tag() == .boolean) {
                    append = args[3].asBoolean();
                }
            }
        }
    }

    const cwd = std.fs.cwd();
    if (append) {
        const file = cwd.openFile(path, .{ .mode = .write_only }) catch {
            // File doesn't exist, create it
            const new_file = cwd.createFile(path, .{}) catch return error.IOError;
            defer new_file.close();
            new_file.writeAll(content) catch return error.IOError;
            return Value.nil_val;
        };
        defer file.close();
        file.seekFromEnd(0) catch return error.IOError;
        file.writeAll(content) catch return error.IOError;
    } else {
        const file = cwd.createFile(path, .{}) catch return error.IOError;
        defer file.close();
        file.writeAll(content) catch return error.IOError;
    }

    return Value.nil_val;
}

/// (read-line) => string or nil
/// Reads a line from the current input source (*in*) or stdin.
pub fn readLineFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read-line", .{args.len});

    // Check if we have a string input source (from with-in-str)
    if (current_input != null) {
        const maybe_val = readLineFromInput(allocator) catch return Value.nil_val;
        return maybe_val orelse Value.nil_val;
    }

    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch return Value.nil_val;
        if (n == 0) {
            // EOF
            if (pos > 0) break;
            return Value.nil_val;
        }
        if (byte[0] == '\n') break;
        buf[pos] = byte[0];
        pos += 1;
    }

    // Strip trailing \r (Windows line endings)
    if (pos > 0 and buf[pos - 1] == '\r') pos -= 1;

    const owned = try allocator.alloc(u8, pos);
    @memcpy(owned, buf[0..pos]);
    return Value.initString(allocator, owned);
}

// ============================================================
// load-file
// ============================================================

/// (load-file path) => value
/// Reads and evaluates all forms in the file at the given path.
/// Returns the value of the last form.
pub fn loadFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to load-file", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "load-file expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    // Read file content
    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "Could not open file: {s}", .{path});
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "Could not read file: {s}", .{path});

    // Evaluate all forms using bootstrap pipeline
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    return bootstrap.evalString(allocator, env, content) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "load-file: evaluation error", .{});
        return error.EvalError;
    };
}

/// (line-seq filename) => list of strings
/// UPSTREAM-DIFF: Takes a filename string instead of BufferedReader.
/// Reads file, splits by newlines, returns list of line strings.
pub fn lineSeqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to line-seq", .{args.len});
    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "line-seq expects a string filename, got {s}", .{@tagName(args[0].tag())}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.IOError;
    if (content.len == 0) return Value.nil_val;

    // Split by newlines
    var lines = std.ArrayList(Value).empty;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            var end = i;
            // Strip \r before \n
            if (end > start and content[end - 1] == '\r') end -= 1;
            const line = try allocator.dupe(u8, content[start..end]);
            try lines.append(allocator, Value.initString(allocator, line));
            start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (start < content.len) {
        var end = content.len;
        if (end > start and content[end - 1] == '\r') end -= 1;
        const line = try allocator.dupe(u8, content[start..end]);
        try lines.append(allocator, Value.initString(allocator, line));
    }

    if (lines.items.len == 0) return Value.nil_val;

    const items = try allocator.dupe(Value, lines.items);
    const list = try allocator.create(PersistentList);
    list.* = .{ .items = items };
    return Value.initList(list);
}

pub const file_io_builtins = [_]BuiltinDef{
    .{
        .name = "slurp",
        .func = &slurpFn,
        .doc = "Opens f with reader, reads all its contents, and returns as a string.",
        .arglists = "([f])",
        .added = "1.0",
    },
    .{
        .name = "read-line",
        .func = &readLineFn,
        .doc = "Reads the next line from stream that is the current value of *in*.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "spit",
        .func = &spitFn,
        .doc = "Opposite of slurp. Opens f with writer, writes content, then closes f.",
        .arglists = "([f content & options])",
        .added = "1.2",
    },
    .{
        .name = "load-file",
        .func = &loadFileFn,
        .doc = "Sequentially read and evaluate the set of forms contained in the file.",
        .arglists = "([name])",
        .added = "1.0",
    },
    .{
        .name = "line-seq",
        .func = &lineSeqFn,
        .doc = "Returns the lines of text from rdr as a lazy sequence of strings. rdr must implement java.io.BufferedReader.",
        .arglists = "([rdr])",
        .added = "1.0",
    },
};

// === Tests ===


// ============================================================
// clojure.java.io namespace builtins
// ============================================================


// ============================================================
// Builtins
// ============================================================

/// (file path) or (file parent child) or (file parent child & more)
/// Joins path segments with the OS path separator. Returns a string.
pub fn fileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to file", .{args.len});

    // Collect string parts, skipping nils
    var buf: [32][]const u8 = undefined;
    var count: usize = 0;

    for (args) |arg| {
        switch (arg.tag()) {
            .string => {
                if (count >= buf.len) return err.setErrorFmt(.eval, .value_error, .{}, "file: too many path segments", .{});
                buf[count] = arg.asString();
                count += 1;
            },
            .nil => {},
            else => return err.setErrorFmt(.eval, .type_error, .{}, "file expects string arguments, got {s}", .{@tagName(arg.tag())}),
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
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to delete-file", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "delete-file expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    const silently = if (args.len > 1) args[1].isTruthy() else false;

    const cwd = std.fs.cwd();
    cwd.deleteFile(path) catch |e| {
        // Try as directory
        cwd.deleteDir(path) catch {
            if (!silently) {
                return err.setErrorFmt(.eval, .io_error, .{}, "Could not delete file: {s} ({s})", .{ path, @errorName(e) });
            }
        };
    };

    return Value.initBoolean(true);
}

/// (make-parents f & more)
/// Creates all parent directories of the path formed by (file f & more).
pub fn makeParentsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-parents", .{args.len});

    // Build path from args (same as file)
    var buf: [32][]const u8 = undefined;
    var count: usize = 0;

    for (args) |arg| {
        switch (arg.tag()) {
            .string => {
                if (count >= buf.len) return err.setErrorFmt(.eval, .value_error, .{}, "make-parents: too many path segments", .{});
                buf[count] = arg.asString();
                count += 1;
            },
            .nil => {},
            else => return err.setErrorFmt(.eval, .type_error, .{}, "make-parents expects string arguments, got {s}", .{@tagName(arg.tag())}),
        }
    }

    if (count == 0) return Value.initBoolean(false);

    const path = if (count == 1) buf[0] else try std.fs.path.join(allocator, buf[0..count]);

    // Get parent directory
    const parent = std.fs.path.dirname(path) orelse return Value.initBoolean(false);

    const cwd = std.fs.cwd();
    cwd.makePath(parent) catch |e| {
        return err.setErrorFmt(.eval, .io_error, .{}, "Could not create parent directories: {s} ({s})", .{ parent, @errorName(e) });
    };

    return Value.initBoolean(true);
}

/// (as-file x)
/// Coerces x to a file path string. In CW, strings are file paths, so this is identity.
pub fn asFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-file", .{args.len});
    return switch (args[0].tag()) {
        .string => args[0],
        .nil => Value.nil_val,
        else => err.setErrorFmt(.eval, .type_error, .{}, "as-file expects a string or nil, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (as-relative-path x)
/// Returns x as a relative path string. Throws if path is absolute.
pub fn asRelativePathFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-relative-path", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "as-relative-path expects a string, got {s}", .{@tagName(args[0].tag())}),
    };

    if (std.fs.path.isAbsolute(path)) {
        return err.setErrorFmt(.eval, .value_error, .{}, "IllegalArgumentException: {s} is not a relative path", .{path});
    }

    return args[0];
}

/// (copy input output) or (copy input output & opts)
/// Copies file content from input path to output path.
pub fn copyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to copy", .{args.len});

    const src_path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "copy expects string paths, got {s}", .{@tagName(args[0].tag())}),
    };

    const dst_path = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "copy expects string paths, got {s}", .{@tagName(args[1].tag())}),
    };

    const cwd = std.fs.cwd();

    // Read source file
    const content = cwd.readFileAlloc(allocator, src_path, 100 * 1024 * 1024) catch |e| {
        return err.setErrorFmt(.eval, .io_error, .{}, "copy: could not read {s} ({s})", .{ src_path, @errorName(e) });
    };

    // Write to destination
    const dst_file = cwd.createFile(dst_path, .{}) catch |e| {
        return err.setErrorFmt(.eval, .io_error, .{}, "copy: could not create {s} ({s})", .{ dst_path, @errorName(e) });
    };
    defer dst_file.close();

    dst_file.writeAll(content) catch |e| {
        return err.setErrorFmt(.eval, .io_error, .{}, "copy: could not write to {s} ({s})", .{ dst_path, @errorName(e) });
    };

    return Value.nil_val;
}

/// (resource name)
/// Returns the path for a named resource. In CW, looks for the file relative to cwd.
/// Returns nil if not found.
pub fn resourceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to resource", .{args.len});

    const name = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "resource expects a string, got {s}", .{@tagName(args[0].tag())}),
    };

    // Check if file exists relative to cwd
    const cwd = std.fs.cwd();
    const stat = cwd.statFile(name) catch return Value.nil_val;
    _ = stat;

    return args[0];
}

pub const java_io_builtins = [_]BuiltinDef{
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

fn capturedOutput(alloc: Allocator, buf: *std.ArrayList(u8), comptime f: fn (Allocator, []const Value) anyerror!Value, args: []const Value) ![]const u8 {
    buf.clearRetainingCapacity();
    setOutputCapture(alloc, buf);
    defer setOutputCapture(null, null);
    _ = try f(alloc, args);
    return buf.items;
}

test "println - no args prints newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, printlnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "println - single string unquoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, printlnFn, &args);
    try testing.expectEqualStrings("hello\n", output);
}

test "println - multi-arg space separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, printlnFn, &args);
    try testing.expectEqualStrings("1 hello \n", output);
}

test "println - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = try printlnFn(testing.allocator, &args);
    try testing.expect(result.isNil());
}

test "prn - no args prints newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, prnFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "prn - string is quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, prnFn, &args);
    try testing.expectEqualStrings("\"hello\"\n", output);
}

test "prn - multi-arg space separated readable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, prnFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil\n", output);
}

test "prn - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = try prnFn(testing.allocator, &args);
    try testing.expect(result.isNil());
}

// === print tests ===

test "print - no args prints nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, printFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "print - single string unquoted no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, printFn, &args);
    try testing.expectEqualStrings("hello", output);
}

test "print - multi-arg space separated no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, printFn, &args);
    try testing.expectEqualStrings("1 hello ", output);
}

// === pr tests ===

test "pr - no args prints nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, prFn, &.{});
    try testing.expectEqualStrings("", output);
}

test "pr - string is quoted no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{Value.initString(alloc, "hello")};
    const output = try capturedOutput(alloc, &buf, prFn, &args);
    try testing.expectEqualStrings("\"hello\"", output);
}

test "pr - multi-arg space separated readable no newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const output = try capturedOutput(alloc, &buf, prFn, &args);
    try testing.expectEqualStrings("1 \"hello\" nil", output);
}

// === newline tests ===

test "newline - prints newline character" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const output = try capturedOutput(testing.allocator, &buf, newlineFn, &.{});
    try testing.expectEqualStrings("\n", output);
}

test "newline - rejects args" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const args = [_]Value{Value.initInteger(1)};
    const result = newlineFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

// === flush tests ===

test "flush - returns nil" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    setOutputCapture(testing.allocator, &buf);
    defer setOutputCapture(null, null);
    const result = try flushFn(testing.allocator, &.{});
    try testing.expect(result.isNil());
}

test "flush - rejects args" {
    const args = [_]Value{Value.initInteger(1)};
    const result = flushFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}


// --- file I/O tests ---

test "slurp - read existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Create a temp file
    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_slurp.txt";
    const file = try cwd.createFile(tmp_path, .{});
    defer file.close();
    try file.writeAll("hello world");

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try slurpFn(alloc, &args);
    try testing.expectEqualStrings("hello world", result.asString());
}

test "slurp - file not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "/tmp/cljw_nonexistent_file.txt")};
    const result = slurpFn(alloc, &args);
    try testing.expectError(error.FileNotFound, result);
}

test "slurp - arity error" {
    const result = slurpFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "slurp - type error" {
    const args = [_]Value{Value.initInteger(42)};
    const result = slurpFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "spit - write new file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit.txt";
    const args = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "hello spit"),
    };
    const result = try spitFn(alloc, &args);
    try testing.expect(result.isNil());

    // Verify content
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello spit", content);
}

test "spit - overwrite existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit_overwrite.txt";
    // Write first
    const args1 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "first"),
    };
    _ = try spitFn(alloc, &args1);
    // Overwrite
    const args2 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "second"),
    };
    _ = try spitFn(alloc, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second", content);
}

test "spit - append mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = "/tmp/cljw_test_spit_append.txt";
    // Write initial content
    const args1 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, "hello"),
    };
    _ = try spitFn(alloc, &args1);
    // Append
    const args2 = [_]Value{
        Value.initString(alloc, tmp_path),
        Value.initString(alloc, " world"),
        Value.initKeyword(alloc, .{ .name = "append", .ns = null }),
        Value.true_val,
    };
    _ = try spitFn(alloc, &args2);

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "spit - arity error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "/tmp/test.txt")};
    const result = spitFn(alloc, &args);
    try testing.expectError(error.ArityError, result);
}

test "read-line - arity error" {
    const args = [_]Value{Value.initInteger(1)};
    const result = readLineFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "line-seq - read file as list of lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a temp file with multiple lines
    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq.txt";
    const file = try cwd.createFile(tmp_path, .{});
    try file.writeAll("line1\nline2\nline3\n");
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    // Should return a list
    try testing.expect(result.tag() == .list);
    const list = result.asList();
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("line1", list.items[0].asString());
    try testing.expectEqualStrings("line2", list.items[1].asString());
    try testing.expectEqualStrings("line3", list.items[2].asString());
}

test "line-seq - no trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq2.txt";
    const file = try cwd.createFile(tmp_path, .{});
    try file.writeAll("line1\nline2");
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    const list = result.asList();
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("line1", list.items[0].asString());
    try testing.expectEqualStrings("line2", list.items[1].asString());
}

test "line-seq - empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const tmp_path = "/tmp/cljw_test_line_seq3.txt";
    const file = try cwd.createFile(tmp_path, .{});
    file.close();

    const args = [_]Value{Value.initString(alloc, tmp_path)};
    const result = try lineSeqFn(alloc, &args);

    // Empty file should return nil (empty seq)
    try testing.expect(result.isNil());
}

test "line-seq - arity error" {
    const result = lineSeqFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}


// --- java.io tests ---

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

