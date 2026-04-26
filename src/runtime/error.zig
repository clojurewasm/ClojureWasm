//! Error infrastructure for ClojureWasm runtime.
//!
//! Provides:
//!   - `SourceLocation` for file/line/column tracking,
//!   - structured `Info` payloads stored in threadlocal `last_error`
//!     because Zig's error unions carry no payload,
//!   - a 64-frame threadlocal call stack,
//!   - 1:1 mapping between `Kind` (semantic categories) and Zig error
//!     tags (`Error.SyntaxError`, …),
//!   - `expect*` / `checkArity*` helpers that centralise the type-check
//!     and arity-check call sites,
//!   - a `BuiltinFn` signature for Phase-1 primitive function pointers.
//!
//! Callers that catch `anyerror` should call `getLastError()` to retrieve
//! the matching `Info` payload.

const std = @import("std");
const Value = @import("value.zig").Value;

// --- Source location ---

/// Origin of a value or expression in source code.
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    /// 1-based; 0 = unknown.
    line: u32 = 0,
    /// 0-based.
    column: u16 = 0,
};

// --- Error classification ---

/// Semantic error categories. Each maps 1:1 to a tag in `Error`.
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
    // I/O (future phases)
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

/// Zig error tags. 1:1 with `Kind`.
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

/// Maximum recorded call-stack depth. Frames pushed beyond this are
/// silently dropped — the trace is best-effort, not load-bearing.
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

/// Set the threadlocal error payload and return the matching Zig error.
/// On message overflow the buffer is truncated with a trailing "...".
pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
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

/// Signature of a Phase-1 primitive function. Phase 2+ extends this to
/// `(rt, env, args, loc)`; the typedef will then move to `dispatch.zig`.
pub const BuiltinFn = *const fn (args: []const Value, loc: SourceLocation) Error!Value;

// --- Tag name helper ---

fn tagName(val: Value) []const u8 {
    return @tagName(val.tag());
}

// --- Type assertion helpers ---

/// Assert `val` is a number; widen to f64.
pub fn expectNumber(val: Value, name: []const u8, loc: SourceLocation) Error!f64 {
    return switch (val.tag()) {
        .integer => @floatFromInt(val.asInteger()),
        .float => val.asFloat(),
        else => setErrorFmt(.eval, .type_error, loc, "{s}: expected number, got {s}", .{ name, tagName(val) }),
    };
}

/// Assert `val` is an integer.
pub fn expectInteger(val: Value, name: []const u8, loc: SourceLocation) Error!i48 {
    if (val.tag() == .integer) return val.asInteger();
    return setErrorFmt(.eval, .type_error, loc, "{s}: expected integer, got {s}", .{ name, tagName(val) });
}

/// Assert `val` is a boolean.
pub fn expectBoolean(val: Value, name: []const u8, loc: SourceLocation) Error!bool {
    if (val.tag() == .boolean) return val.asBoolean();
    return setErrorFmt(.eval, .type_error, loc, "{s}: expected boolean, got {s}", .{ name, tagName(val) });
}

// --- Arity check helpers ---

/// Exact arity check.
pub fn checkArity(name: []const u8, args: []const Value, expected: usize, loc: SourceLocation) Error!void {
    if (args.len != expected) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}", .{ args.len, name });
    }
}

/// Minimum-arity check (variadic primitives).
pub fn checkArityMin(name: []const u8, args: []const Value, min: usize, loc: SourceLocation) Error!void {
    if (args.len < min) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}, expected at least {d}", .{ args.len, name, min });
    }
}

/// Inclusive arity-range check.
pub fn checkArityRange(name: []const u8, args: []const Value, min: usize, max: usize, loc: SourceLocation) Error!void {
    if (args.len < min or args.len > max) {
        return setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s}, expected {d} to {d}", .{ args.len, name, min, max });
    }
}

// --- Error formatting ---

/// Render an `Info` into `buf` for human display. Returns a slice of
/// `buf` containing the rendered output (truncated on overflow).
pub fn formatError(info: Info, buf: []u8) []const u8 {
    const result = std.fmt.bufPrint(buf,
        \\{s} [{s}] at {s}:{d}:{d}
        \\  {s}
    , .{
        @tagName(info.kind),
        @tagName(info.phase),
        info.location.file,
        info.location.line,
        info.location.column,
        info.message,
    }) catch buf[0..@min(buf.len, 3)];

    return result;
}

// --- tests ---

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

test "setErrorFmt stores info and returns matching tag" {
    clearLastError();
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

fn retSyntaxError() Error!void {
    return setErrorFmt(.parse, .syntax_error, .{}, "bad token", .{});
}

fn retNameError() Error!void {
    return setErrorFmt(.eval, .name_error, .{}, "x not found", .{});
}

test "getLastError clears after read" {
    clearLastError();
    try testing.expectError(Error.SyntaxError, retSyntaxError());
    const info = getLastError();
    try testing.expect(info != null);
    try testing.expectEqual(Kind.syntax_error, info.?.kind);
    try testing.expect(getLastError() == null);
}

test "clearLastError" {
    try testing.expectError(Error.NameError, retNameError());
    clearLastError();
    try testing.expect(peekLastError() == null);
}

test "checkArity exact pass" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArity("+", &args, 2, .{});
}

test "checkArity exact fail" {
    clearLastError();
    const args = [_]Value{Value.initInteger(1)};
    try testing.expectError(Error.ArityError, checkArity("+", &args, 2, .{}));
    const info = getLastError().?;
    try testing.expectEqualStrings("Wrong number of args (1) passed to +", info.message);
}

test "checkArityMin pass and fail" {
    const args2 = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityMin("str", &args2, 1, .{});

    const args0 = [_]Value{};
    try testing.expectError(Error.ArityError, checkArityMin("str", &args0, 1, .{}));
}

test "checkArityRange pass and fail (low/high)" {
    const args2 = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    try checkArityRange("subs", &args2, 2, 3, .{});

    const args1 = [_]Value{Value.initInteger(1)};
    try testing.expectError(Error.ArityError, checkArityRange("subs", &args1, 2, 3, .{}));

    const args4 = [_]Value{ .nil_val, .nil_val, .nil_val, .nil_val };
    try testing.expectError(Error.ArityError, checkArityRange("subs", &args4, 2, 3, .{}));
}

test "expectNumber accepts int and float, rejects nil" {
    clearLastError();
    try testing.expectEqual(@as(f64, 42.0), try expectNumber(Value.initInteger(42), "f", .{}));
    try testing.expectApproxEqRel(@as(f64, 3.14), try expectNumber(Value.initFloat(3.14), "f", .{}), 1e-10);

    try testing.expectError(Error.TypeError, expectNumber(.nil_val, "f", .{}));
    const info = getLastError().?;
    try testing.expectEqualStrings("f: expected number, got nil", info.message);
}

test "expectInteger pass; float fails" {
    try testing.expectEqual(@as(i48, -7), try expectInteger(Value.initInteger(-7), "nth", .{}));
    try testing.expectError(Error.TypeError, expectInteger(Value.initFloat(1.5), "nth", .{}));
}

test "expectBoolean pass; nil fails" {
    try testing.expect(try expectBoolean(.true_val, "t", .{}));
    try testing.expectError(Error.TypeError, expectBoolean(.nil_val, "t", .{}));
}

test "call stack push/pop and overflow are silent" {
    clearCallStack();
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    pushFrame(.{ .fn_name = "foo", .ns = "user" });
    pushFrame(.{ .fn_name = "bar" });
    try testing.expectEqual(@as(usize, 2), getCallStack().len);
    try testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    popFrame();
    try testing.expectEqual(@as(usize, 1), getCallStack().len);
    popFrame();
    popFrame(); // pop on empty is safe
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    for (0..max_call_depth + 10) |i| pushFrame(.{ .line = @truncate(i) });
    try testing.expectEqual(@as(usize, max_call_depth), getCallStack().len);
    clearCallStack();
}

test "kindToError maps every Kind" {
    try testing.expectEqual(Error.SyntaxError, kindToError(.syntax_error));
    try testing.expectEqual(Error.TypeError, kindToError(.type_error));
    try testing.expectEqual(Error.ArityError, kindToError(.arity_error));
    try testing.expectEqual(Error.OutOfMemory, kindToError(.out_of_memory));
}

test "formatError contains location and message" {
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

test "BuiltinFn signature compiles and is invocable" {
    const Fns = struct {
        fn echoFirst(args: []const Value, _: SourceLocation) Error!Value {
            if (args.len == 0) return Error.ArityError;
            return args[0];
        }
    };
    const fp: BuiltinFn = &Fns.echoFirst;
    const result = try fp(&[_]Value{Value.initInteger(7)}, .{});
    try testing.expectEqual(@as(i48, 7), result.asInteger());
}
