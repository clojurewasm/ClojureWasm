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

/// Store error info and return the corresponding Zig error tag.
pub fn setError(info: Info) Error {
    last_error = info;
    return kindToError(info.kind);
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
