// Error types for ClojureWasm.
//
// Zig error unions carry no payload, so detailed error info is stored
// in a thread-local Info struct and retrieved after catching the error.

const std = @import("std");

pub const Phase = enum {
    parse,
    analysis,
    macroexpand,
    eval,
};

pub const Kind = enum {
    // Parse
    unexpected_eof,
    invalid_token,
    unmatched_delimiter,
    invalid_number,
    invalid_character,
    invalid_string,
    invalid_regex,
    invalid_keyword,

    // Analysis
    undefined_symbol,
    invalid_arity,
    invalid_binding,
    duplicate_key,

    // Eval
    division_by_zero,
    index_out_of_bounds,
    type_error,

    // General
    internal_error,
    out_of_memory,
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
    UnexpectedEof,
    InvalidToken,
    UnmatchedDelimiter,
    InvalidNumber,
    InvalidCharacter,
    InvalidString,
    InvalidKeyword,
    UndefinedSymbol,
    InvalidArity,
    InvalidBinding,
    DivisionByZero,
    IndexOutOfBounds,
    TypeError,
    OutOfMemory,
};

// TODO(D3a): Migrate to ErrorContext instance in Phase 2a (Task 2.1).
// Threadlocal violates D3 (no threadlocal). When Env is created,
// move last_error + msg_buf into an instance-based ErrorContext.
// TODO(D3b): Redesign Kind enum to Python-style categories (Task 2.1).
// See .dev/notes/decisions.md D3b for target enum and migration table.
threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;

pub fn setError(info: Info) Error {
    last_error = info;
    return kindToError(info.kind);
}

pub fn getLastError() ?Info {
    const info = last_error;
    last_error = null;
    return info;
}

pub fn parseError(kind: Kind, message: []const u8, location: SourceLocation) Error {
    return setError(.{
        .kind = kind,
        .phase = .parse,
        .message = message,
        .location = location,
    });
}

pub fn parseErrorFmt(kind: Kind, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = .parse,
        .message = msg,
    });
}

pub fn analysisError(kind: Kind, message: []const u8, location: SourceLocation) Error {
    return setError(.{
        .kind = kind,
        .phase = .analysis,
        .message = message,
        .location = location,
    });
}

pub fn analysisErrorFmt(kind: Kind, location: SourceLocation, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = .analysis,
        .message = msg,
        .location = location,
    });
}

/// Analysis error — union of analysis errors and OOM.
pub const AnalysisError = error{
    UndefinedSymbol,
    InvalidArity,
    InvalidBinding,
    OutOfMemory,
};

/// Reader error — union of parse errors and OOM.
pub const ReadError = error{
    UnexpectedEof,
    InvalidToken,
    UnmatchedDelimiter,
    InvalidNumber,
    InvalidCharacter,
    InvalidString,
    InvalidKeyword,
    OutOfMemory,
};

fn kindToError(kind: Kind) Error {
    return switch (kind) {
        .unexpected_eof => error.UnexpectedEof,
        .invalid_token => error.InvalidToken,
        .unmatched_delimiter => error.UnmatchedDelimiter,
        .invalid_number => error.InvalidNumber,
        .invalid_character => error.InvalidCharacter,
        .invalid_string => error.InvalidString,
        .invalid_regex => error.InvalidToken,
        .invalid_keyword => error.InvalidKeyword,
        .undefined_symbol => error.UndefinedSymbol,
        .invalid_arity => error.InvalidArity,
        .invalid_binding => error.InvalidBinding,
        .duplicate_key => error.InvalidBinding,
        .division_by_zero => error.DivisionByZero,
        .index_out_of_bounds => error.IndexOutOfBounds,
        .type_error => error.TypeError,
        .internal_error => error.TypeError,
        .out_of_memory => error.OutOfMemory,
    };
}

test "setError and getLastError round-trip" {
    const e = setError(.{
        .kind = .invalid_number,
        .phase = .parse,
        .message = "bad number",
        .location = .{ .line = 5, .column = 10 },
    });
    try std.testing.expectEqual(error.InvalidNumber, e);

    const info = getLastError().?;
    try std.testing.expectEqual(Kind.invalid_number, info.kind);
    try std.testing.expectEqual(Phase.parse, info.phase);
    try std.testing.expectEqualStrings("bad number", info.message);
    try std.testing.expectEqual(@as(u32, 5), info.location.line);

    // getLastError clears the error
    try std.testing.expect(getLastError() == null);
}

test "parseError convenience" {
    const e = parseError(.unexpected_eof, "EOF in list", .{ .line = 1 });
    try std.testing.expectEqual(error.UnexpectedEof, e);

    const info = getLastError().?;
    try std.testing.expectEqual(Kind.unexpected_eof, info.kind);
    try std.testing.expectEqualStrings("EOF in list", info.message);
}
