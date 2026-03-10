//! Error infrastructure for ClojureWasm runtime.
//!
//! Provides structured error reporting with source locations, threadlocal
//! error state, type assertion helpers, and arity checking. Designed to
//! eliminate the 1,252 hand-written setErrorFmt calls from the CW codebase
//! by providing centralized helpers.
//!
//! Error details are stored in threadlocal state because Zig error unions
//! carry no payload. Call `getLastError()` after catching `anyerror`.

const std = @import("std");
const Value = @import("value.zig").Value;

// --- Source location ---

/// Tracks origin of a value or expression in source code.
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    line: u32 = 0, // 1-based, 0 = unknown
    column: u16 = 0, // 0-based
};

// --- Error classification ---

/// Python-style error kinds with 1:1 mapping to Zig error tags.
pub const Kind = enum {
    // Parse phase
    syntax_error,
    number_error,
    string_error,
    // Analysis phase
    name_error,
    arity_error,
    value_error,
    // Eval phase
    type_error,
    arithmetic_error,
    index_error,
    // IO (future)
    io_error,
    // System
    internal_error,
    out_of_memory,
};

/// Compilation/execution phase where the error occurred.
pub const Phase = enum {
    parse,
    analysis,
    macroexpand,
    eval,
};

/// Structured error information stored in threadlocal state.
pub const Info = struct {
    kind: Kind,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},
};

// --- Zig error tags (1:1 with Kind) ---

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

fn kindToError(kind: Kind) Error {
    return switch (kind) {
        .syntax_error => Error.SyntaxError,
        .number_error => Error.NumberError,
        .string_error => Error.StringError,
        .name_error => Error.NameError,
        .arity_error => Error.ArityError,
        .value_error => Error.ValueError,
        .type_error => Error.TypeError,
        .arithmetic_error => Error.ArithmeticError,
        .index_error => Error.IndexError,
        .io_error => Error.IoError,
        .internal_error => Error.InternalError,
        .out_of_memory => Error.OutOfMemory,
    };
}

// --- Threadlocal state ---

threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;

// Call stack (fixed 64 frames, silent drop on overflow)
pub const max_call_depth: u8 = 64;

pub const StackFrame = struct {
    fn_name: ?[]const u8 = null,
    ns: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u16 = 0,
};

threadlocal var call_stack: [max_call_depth]StackFrame = [_]StackFrame{.{}} ** max_call_depth;
threadlocal var stack_depth: u8 = 0;

// --- Core error API ---

/// Set error with formatted message and return the corresponding Zig error tag.
pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        // Truncate if message exceeds buffer
        @memcpy(msg_buf[509..512], "...");
        break :blk msg_buf[0..512];
    };
    last_error = .{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    };
    return kindToError(kind);
}

/// Retrieve and clear the last error.
pub fn getLastError() ?Info {
    const err = last_error;
    last_error = null;
    return err;
}

/// Peek at the last error without clearing it.
pub fn peekLastError() ?Info {
    return last_error;
}

/// Clear the last error.
pub fn clearLastError() void {
    last_error = null;
}

// --- Call stack API ---

pub fn pushFrame(frame: StackFrame) void {
    if (stack_depth < max_call_depth) {
        call_stack[stack_depth] = frame;
        stack_depth += 1;
    }
}

pub fn popFrame() void {
    if (stack_depth > 0) {
        stack_depth -= 1;
    }
}

pub fn getCallStack() []const StackFrame {
    return call_stack[0..stack_depth];
}

pub fn clearCallStack() void {
    stack_depth = 0;
}

// --- BuiltinFn signature ---

/// Signature for all built-in (kernel) functions.
/// Takes argument slice and source location of the call site.
pub const BuiltinFn = *const fn (args: []const Value, loc: SourceLocation) anyerror!Value;

// --- Tag name helper ---

fn tagName(val: Value) []const u8 {
    return @tagName(val.tag());
}

// --- Type assertion helpers ---

/// Assert value is a number (integer or float). Returns the value as f64.
pub fn expectNumber(val: Value, name: []const u8, loc: SourceLocation) Error!f64 {
    return switch (val.tag()) {
        .integer => @floatFromInt(val.asInteger()),
        .float => val.asFloat(),
        else => setErrorFmt(.eval, .type_error, loc, "{s}: expected number, got {s}", .{ name, tagName(val) }),
    };
}

/// Assert value is an integer. Returns the i48 value.
pub fn expectInteger(val: Value, name: []const u8, loc: SourceLocation) Error!i48 {
    if (val.tag() == .integer) return val.asInteger();
    return setErrorFmt(.eval, .type_error, loc, "{s}: expected integer, got {s}", .{ name, tagName(val) });
}

/// Assert value is a boolean.
pub fn expectBoolean(val: Value, name: []const u8, loc: SourceLocation) Error!bool {
    if (val.tag() == .boolean) return val.asBoolean();
    return setErrorFmt(.eval, .type_error, loc, "{s}: expected boolean, got {s}", .{ name, tagName(val) });
}

// --- Arity check helpers ---

/// Check exact arity.
pub fn checkArity(name: []const u8, args: []const Value, expected: usize, loc: SourceLocation) Error!void {
    if (args.len != expected) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}", .{ args.len, name });
    }
}

/// Check minimum arity.
pub fn checkArityMin(name: []const u8, args: []const Value, min: usize, loc: SourceLocation) Error!void {
    if (args.len < min) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}, expected at least {d}", .{ args.len, name, min });
    }
}

/// Check arity range [min, max].
pub fn checkArityRange(name: []const u8, args: []const Value, min: usize, max: usize, loc: SourceLocation) Error!void {
    if (args.len < min or args.len > max) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}, expected {d} to {d}", .{ args.len, name, min, max });
    }
}

// --- Error formatting (ANSI) ---

/// Format an error for display with ANSI colors. Returns a slice into the provided buffer.
pub fn formatError(info: Info, buf: []u8) []const u8 {
    const kind_str = @tagName(info.kind);
    const phase_str = @tagName(info.phase);

    const result = std.fmt.bufPrint(buf,
        \\{s} [{s}] at {s}:{d}:{d}
        \\  {s}
    , .{
        kind_str,
        phase_str,
        info.location.file,
        info.location.line,
        info.location.column,
        info.message,
    }) catch buf[0..@min(buf.len, 3)];

    return result;
}

// --- Tests ---

const testing = std.testing;

test "SourceLocation defaults" {
    const loc = SourceLocation{};
    try testing.expectEqualStrings("unknown", loc.file);
    try testing.expectEqual(@as(u32, 0), loc.line);
    try testing.expectEqual(@as(u16, 0), loc.column);
}

test "SourceLocation with values" {
    const loc = SourceLocation{ .file = "core.clj", .line = 42, .column = 10 };
    try testing.expectEqualStrings("core.clj", loc.file);
    try testing.expectEqual(@as(u32, 42), loc.line);
    try testing.expectEqual(@as(u16, 10), loc.column);
}

test "setErrorFmt stores error and returns correct tag" {
    const loc = SourceLocation{ .file = "test.clj", .line = 1 };
    const err = setErrorFmt(.eval, .type_error, loc, "expected number, got {s}", .{"nil"});
    try testing.expectEqual(Error.TypeError, err);

    const info = peekLastError().?;
    try testing.expectEqual(Kind.type_error, info.kind);
    try testing.expectEqual(Phase.eval, info.phase);
    try testing.expectEqualStrings("expected number, got nil", info.message);
    try testing.expectEqualStrings("test.clj", info.location.file);
    try testing.expectEqual(@as(u32, 1), info.location.line);
}

test "getLastError clears after read" {
    clearLastError();
    try testing.expectError(Error.SyntaxError, retSyntaxError());
    const info = getLastError();
    try testing.expect(info != null);
    try testing.expectEqual(Kind.syntax_error, info.?.kind);

    // Second call returns null
    try testing.expect(getLastError() == null);
}

// Helper functions to trigger errors without discarding error sets
fn retSyntaxError() Error!void {
    return setErrorFmt(.parse, .syntax_error, .{}, "bad token", .{});
}

fn retNameError() Error!void {
    return setErrorFmt(.eval, .name_error, .{}, "x not found", .{});
}

test "clearLastError" {
    try testing.expectError(Error.NameError, retNameError());
    clearLastError();
    try testing.expect(peekLastError() == null);
}

test "checkArity exact - pass" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArity("+", &args, 2, .{});
}

test "checkArity exact - fail" {
    const args = [_]Value{Value.initInteger(1)};
    const result = checkArity("+", &args, 2, .{});
    try testing.expectError(Error.ArityError, result);
    const info = getLastError().?;
    try testing.expectEqualStrings("Wrong number of args (1) passed to +", info.message);
}

test "checkArityMin - pass" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityMin("str", &args, 1, .{});
}

test "checkArityMin - fail" {
    const args = [_]Value{};
    const result = checkArityMin("str", &args, 1, .{});
    try testing.expectError(Error.ArityError, result);
}

test "checkArityRange - pass" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityRange("subs", &args, 2, 3, .{});
}

test "checkArityRange - fail low" {
    const args = [_]Value{Value.initInteger(1)};
    const result = checkArityRange("subs", &args, 2, 3, .{});
    try testing.expectError(Error.ArityError, result);
}

test "checkArityRange - fail high" {
    const args = [_]Value{ .nil_val, .nil_val, .nil_val, .nil_val };
    const result = checkArityRange("subs", &args, 2, 3, .{});
    try testing.expectError(Error.ArityError, result);
}

test "expectNumber - integer" {
    const val = Value.initInteger(42);
    const result = try expectNumber(val, "test-fn", .{});
    try testing.expectEqual(@as(f64, 42.0), result);
}

test "expectNumber - float" {
    const val = Value.initFloat(3.14);
    const result = try expectNumber(val, "test-fn", .{});
    try testing.expectApproxEqRel(@as(f64, 3.14), result, 1e-10);
}

test "expectNumber - nil fails" {
    const result = expectNumber(.nil_val, "test-fn", .{});
    try testing.expectError(Error.TypeError, result);
    const info = getLastError().?;
    try testing.expectEqualStrings("test-fn: expected number, got nil", info.message);
}

test "expectInteger - pass" {
    const val = Value.initInteger(-7);
    const result = try expectInteger(val, "nth", .{});
    try testing.expectEqual(@as(i48, -7), result);
}

test "expectInteger - float fails" {
    const result = expectInteger(Value.initFloat(1.5), "nth", .{});
    try testing.expectError(Error.TypeError, result);
}

test "expectBoolean - pass" {
    const result = try expectBoolean(.true_val, "test", .{});
    try testing.expect(result);
}

test "expectBoolean - nil fails" {
    const result = expectBoolean(.nil_val, "test", .{});
    try testing.expectError(Error.TypeError, result);
}

test "call stack push/pop" {
    clearCallStack();
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    pushFrame(.{ .fn_name = "foo", .ns = "user" });
    try testing.expectEqual(@as(usize, 1), getCallStack().len);
    try testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    pushFrame(.{ .fn_name = "bar" });
    try testing.expectEqual(@as(usize, 2), getCallStack().len);

    popFrame();
    try testing.expectEqual(@as(usize, 1), getCallStack().len);
    try testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    popFrame();
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    // Pop on empty is safe
    popFrame();
    try testing.expectEqual(@as(usize, 0), getCallStack().len);
}

test "call stack overflow is silent" {
    clearCallStack();
    for (0..max_call_depth + 10) |i| {
        pushFrame(.{ .line = @truncate(i) });
    }
    // Capped at max
    try testing.expectEqual(@as(usize, max_call_depth), getCallStack().len);
    clearCallStack();
}

test "kindToError mapping" {
    try testing.expectEqual(Error.SyntaxError, kindToError(.syntax_error));
    try testing.expectEqual(Error.TypeError, kindToError(.type_error));
    try testing.expectEqual(Error.ArityError, kindToError(.arity_error));
    try testing.expectEqual(Error.OutOfMemory, kindToError(.out_of_memory));
}

test "formatError produces readable output" {
    const info = Info{
        .kind = .type_error,
        .phase = .eval,
        .message = "expected number, got nil",
        .location = .{ .file = "core.clj", .line = 42, .column = 5 },
    };
    var buf: [256]u8 = undefined;
    const result = formatError(info, &buf);
    try testing.expect(std.mem.indexOf(u8, result, "type_error") != null);
    try testing.expect(std.mem.indexOf(u8, result, "core.clj") != null);
    try testing.expect(std.mem.indexOf(u8, result, "expected number, got nil") != null);
}

test "BuiltinFn type matches signature" {
    // Verify BuiltinFn can be used as a function pointer type
    const dummy: BuiltinFn = &struct {
        fn f(_: []const Value, _: SourceLocation) anyerror!Value {
            return .nil_val;
        }
    }.f;
    const result = try dummy(&.{}, .{});
    try testing.expect(result.isNil());
}
