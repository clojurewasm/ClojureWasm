// Error types for ClojureWasm.
//
// Zig error unions carry no payload, so detailed error info is stored
// in a thread-local Info struct and retrieved after catching the error.
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

// TODO(D3a): Migrate to ErrorContext instance in Phase 2a (Task 2.1).
// Threadlocal violates D3 (no threadlocal). When Env is created,
// move last_error + msg_buf into an instance-based ErrorContext.
threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;

pub fn setError(info: Info) Error {
    last_error = info;
    return kindToError(info.kind);
}

pub fn setErrorFmt(phase: Phase, kind: Kind, location: SourceLocation, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    });
}

pub fn getLastError() ?Info {
    const info = last_error;
    last_error = null;
    return info;
}

fn kindToError(kind: Kind) Error {
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

test "setErrorFmt convenience" {
    const e = setErrorFmt(.parse, .syntax_error, .{ .line = 1 }, "EOF in {s}", .{"list"});
    try std.testing.expectEqual(error.SyntaxError, e);

    const info = getLastError().?;
    try std.testing.expectEqual(Kind.syntax_error, info.kind);
    try std.testing.expectEqualStrings("EOF in list", info.message);
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
