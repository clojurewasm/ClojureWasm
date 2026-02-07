// Error types for ClojureWasm.
//
// Zig error unions carry no payload, so detailed error info is stored
// in threadlocal state and retrieved after catching the error.
//
// Kind uses Python-style categories (12 values). Each Kind maps 1:1 to
// an Error tag — no lossy collapse.

const std = @import("std");

pub const Phase = enum {
    parse,
    analysis,
    macroexpand,
    eval,
};

pub const Kind = enum {
    // Parse phase (Reader/Tokenizer)
    syntax_error, // Structural: unexpected EOF, unmatched delimiters, invalid tokens
    number_error, // Number literal parse failure (hex, radix, ratio, etc.)
    string_error, // String/char/regex literal issues (bad escape, unterminated)

    // Analysis phase (Analyzer)
    name_error, // Undefined symbol, unresolved var, invalid keyword
    arity_error, // Wrong number of arguments
    value_error, // Invalid binding form, duplicate map key, bad metadata

    // Eval phase (VM/TreeWalk)
    type_error, // Operation applied to wrong type: (+ "a" 1)
    arithmetic_error, // Division by zero, overflow
    index_error, // nth/get out of bounds

    // IO (future: slurp, spit, file operations)
    io_error,

    // System
    internal_error, // Implementation bug (unreachable reached)
    out_of_memory, // Allocator failure
};

pub const SourceLocation = struct {
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
};

pub const Info = struct {
    kind: Kind,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},
};

pub const Error = error{
    SyntaxError,
    NumberError,
    StringError,
    NameError,
    ArityError,
    ValueError,
    TypeError,
    ArithmeticError,
    IndexError,
    IoError,
    InternalError,
    OutOfMemory,
};

// --- Threadlocal error state ---

threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;
threadlocal var source_text_cache: ?[]const u8 = null;
threadlocal var source_file_cache: ?[]const u8 = null;

/// Store error info and return the corresponding Zig error tag.
pub fn setError(info: Info) Error {
    last_error = info;
    return kindToError(info.kind);
}

/// Store error info without returning an error tag (for callers with different error sets).
pub fn setInfoFmt(phase: Phase, kind: Kind, location: SourceLocation, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    last_error = .{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    };
}

/// Store error info with formatted message.
pub fn setErrorFmt(phase: Phase, kind: Kind, location: SourceLocation, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    });
}

/// Retrieve and clear the last error. Returns null if no error is stored.
pub fn getLastError() ?Info {
    const info = last_error;
    last_error = null;
    return info;
}

/// Cache source file name for Node source tracking.
pub fn setSourceFile(file: ?[]const u8) void {
    source_file_cache = file;
}

/// Retrieve cached source file name.
pub fn getSourceFile() ?[]const u8 {
    return source_file_cache;
}

/// Cache source text for error context display (REPL/-e mode).
pub fn setSourceText(text: []const u8) void {
    source_text_cache = text;
}

/// Retrieve cached source text.
pub fn getSourceText() ?[]const u8 {
    return source_text_cache;
}

/// Clear cached source text.
pub fn clearSourceText() void {
    source_text_cache = null;
}

// --- Threadlocal arg source tracking ---

threadlocal var arg_sources: [8]SourceLocation = @splat(SourceLocation{});

/// Save source location for a specific argument index.
pub fn saveArgSource(idx: u8, loc: SourceLocation) void {
    if (idx < arg_sources.len) {
        arg_sources[idx] = loc;
    }
}

/// Retrieve source location for a specific argument index.
pub fn getArgSource(idx: u8) SourceLocation {
    if (idx < arg_sources.len) return arg_sources[idx];
    return .{};
}

/// Annotate the current threadlocal error with source location.
/// Only updates if location is not already set (line == 0).
pub fn annotateLocation(loc: SourceLocation) void {
    if (last_error) |*info| {
        if (info.location.line == 0 and loc.line > 0) {
            info.location = loc;
        }
    }
}

pub fn kindToError(kind: Kind) Error {
    return switch (kind) {
        .syntax_error => error.SyntaxError,
        .number_error => error.NumberError,
        .string_error => error.StringError,
        .name_error => error.NameError,
        .arity_error => error.ArityError,
        .value_error => error.ValueError,
        .type_error => error.TypeError,
        .arithmetic_error => error.ArithmeticError,
        .index_error => error.IndexError,
        .io_error => error.IoError,
        .internal_error => error.InternalError,
        .out_of_memory => error.OutOfMemory,
    };
}

test "setError and getLastError round-trip" {
    const e = setError(.{
        .kind = .number_error,
        .phase = .parse,
        .message = "bad number",
        .location = .{ .line = 5, .column = 10 },
    });
    try std.testing.expectEqual(error.NumberError, e);

    const info = getLastError().?;
    try std.testing.expectEqual(Kind.number_error, info.kind);
    try std.testing.expectEqual(Phase.parse, info.phase);
    try std.testing.expectEqualStrings("bad number", info.message);
    try std.testing.expectEqual(@as(u32, 5), info.location.line);

    // getLastError clears the error
    try std.testing.expect(getLastError() == null);
}

test "setErrorFmt" {
    const e = setErrorFmt(.parse, .syntax_error, .{ .line = 1 }, "EOF in {s}", .{"list"});
    try std.testing.expectEqual(error.SyntaxError, e);

    const info = getLastError().?;
    try std.testing.expectEqual(Kind.syntax_error, info.kind);
    try std.testing.expectEqualStrings("EOF in list", info.message);
}

test "source text cache" {
    setSourceText("(+ 1 2)");
    try std.testing.expectEqualStrings("(+ 1 2)", getSourceText().?);
    clearSourceText();
    try std.testing.expect(getSourceText() == null);
}

test "arg source save and retrieve" {
    saveArgSource(0, .{ .line = 5, .column = 3 });
    saveArgSource(1, .{ .line = 5, .column = 10 });

    const s0 = getArgSource(0);
    try std.testing.expectEqual(@as(u32, 5), s0.line);
    try std.testing.expectEqual(@as(u32, 3), s0.column);

    const s1 = getArgSource(1);
    try std.testing.expectEqual(@as(u32, 5), s1.line);
    try std.testing.expectEqual(@as(u32, 10), s1.column);

    // Out of range returns empty
    const s9 = getArgSource(9);
    try std.testing.expectEqual(@as(u32, 0), s9.line);
}

// --- Call stack tracking ---

pub const StackFrame = struct {
    fn_name: ?[]const u8 = null,
    ns: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
};

const MAX_CALL_STACK: u8 = 64;

threadlocal var call_stack: [MAX_CALL_STACK]StackFrame = @splat(StackFrame{});
threadlocal var stack_depth: u8 = 0;

/// Push a call frame onto the error call stack.
pub fn pushFrame(frame: StackFrame) void {
    if (stack_depth < MAX_CALL_STACK) {
        call_stack[stack_depth] = frame;
        stack_depth += 1;
    }
}

/// Pop the topmost call frame.
pub fn popFrame() void {
    if (stack_depth > 0) {
        stack_depth -= 1;
    }
}

/// Get the current call stack (slice of active frames).
pub fn getCallStack() []const StackFrame {
    return call_stack[0..stack_depth];
}

/// Save the current call stack snapshot (for catch handlers).
/// The saved trace persists across clearCallStack() so Throwable->map can read it.
threadlocal var saved_stack: [MAX_CALL_STACK]StackFrame = @splat(StackFrame{});
threadlocal var saved_depth: u8 = 0;

pub fn saveCallStack() void {
    saved_depth = stack_depth;
    if (stack_depth > 0) {
        @memcpy(saved_stack[0..stack_depth], call_stack[0..stack_depth]);
    }
}

/// Get the saved call stack snapshot.
pub fn getSavedCallStack() []const StackFrame {
    return saved_stack[0..saved_depth];
}

/// Clear the call stack (e.g., after error handling).
pub fn clearCallStack() void {
    stack_depth = 0;
}

test "call stack push/pop" {
    clearCallStack();
    try std.testing.expectEqual(@as(usize, 0), getCallStack().len);

    pushFrame(.{ .fn_name = "foo", .ns = "user", .line = 10 });
    try std.testing.expectEqual(@as(usize, 1), getCallStack().len);
    try std.testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    pushFrame(.{ .fn_name = "bar", .ns = "user", .line = 20 });
    try std.testing.expectEqual(@as(usize, 2), getCallStack().len);
    try std.testing.expectEqualStrings("bar", getCallStack()[1].fn_name.?);

    popFrame();
    try std.testing.expectEqual(@as(usize, 1), getCallStack().len);
    try std.testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    popFrame();
    try std.testing.expectEqual(@as(usize, 0), getCallStack().len);
}

test "call stack overflow protection" {
    clearCallStack();
    // Push MAX_CALL_STACK frames
    for (0..MAX_CALL_STACK) |_| {
        pushFrame(.{ .fn_name = "overflow" });
    }
    try std.testing.expectEqual(@as(usize, MAX_CALL_STACK), getCallStack().len);

    // Extra push is silently dropped (no crash)
    pushFrame(.{ .fn_name = "extra" });
    try std.testing.expectEqual(@as(usize, MAX_CALL_STACK), getCallStack().len);

    clearCallStack();
    try std.testing.expectEqual(@as(usize, 0), getCallStack().len);
}

test "popFrame on empty stack is safe" {
    clearCallStack();
    popFrame(); // should not crash
    try std.testing.expectEqual(@as(usize, 0), getCallStack().len);
}

test "kindToError 1:1 mapping" {
    // Verify all 12 kinds map to distinct error tags
    try std.testing.expectEqual(error.SyntaxError, kindToError(.syntax_error));
    try std.testing.expectEqual(error.NumberError, kindToError(.number_error));
    try std.testing.expectEqual(error.StringError, kindToError(.string_error));
    try std.testing.expectEqual(error.NameError, kindToError(.name_error));
    try std.testing.expectEqual(error.ArityError, kindToError(.arity_error));
    try std.testing.expectEqual(error.ValueError, kindToError(.value_error));
    try std.testing.expectEqual(error.TypeError, kindToError(.type_error));
    try std.testing.expectEqual(error.ArithmeticError, kindToError(.arithmetic_error));
    try std.testing.expectEqual(error.IndexError, kindToError(.index_error));
    try std.testing.expectEqual(error.IoError, kindToError(.io_error));
    try std.testing.expectEqual(error.InternalError, kindToError(.internal_error));
    try std.testing.expectEqual(error.OutOfMemory, kindToError(.out_of_memory));
}
