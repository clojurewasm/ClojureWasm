//! Error infrastructure for ClojureWasm runtime.
//!
//! Provides:
//!   - `SourceLocation` for file/line/column tracking,
//!   - structured `Info` payloads stored in threadlocal `last_error`
//!     because Zig's error unions carry no payload,
//!   - a 64-frame threadlocal call stack,
//!   - 1:1 mapping between `Kind` (semantic categories) and Zig error
//!     tags (`ClojureWasmError.SyntaxError`, …); a user `(throw v)`
//!     raises `error.ThrownValue` (not a `ClojureWasmError`) and is
//!     modelled as `Info.origin == .thrown` rather than a fake `Kind`,
//!     keeping this mapping honest (ADR-0055 amendment 2),
//!   - `expect*` / `checkArity*` helpers that centralise the type-check
//!     and arity-check call sites,
//!   - a `BuiltinFn` signature for Phase-1 primitive function pointers.
//!
//! Callers that catch `anyerror` should call `getLastError()` to retrieve
//! the matching `Info` payload.

const std = @import("std");
const Value = @import("../value/value.zig").Value;

// --- Source location ---

/// Origin of a value or expression in source code.
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    /// 1-based; 0 = unknown.
    line: u32 = 0,
    /// 0-based.
    column: u16 = 0,
};

// --- ClojureWasmError classification ---

/// Semantic error categories. Each maps 1:1 to a tag in `ClojureWasmError`.
pub const Kind = enum {
    // Parse phase
    syntax_error,
    number_error,
    string_error,
    // Analysis phase
    name_error,
    arity_error,
    value_error,
    /// A form is well-formed but uses a feature not yet implemented
    /// (e.g. a regex with a named group or a Unicode category
    /// `\p{L}`). Kept distinct from `internal_error` so user-facing
    /// tooling can flag "ClojureWasm vN.M doesn't support this yet"
    /// rather than "this is a bug in the runtime".
    not_implemented,
    // Eval phase
    type_error,
    arithmetic_error,
    index_error,
    // I/O (future phases)
    io_error,
    /// A missing file/directory specifically — the leaf
    /// `java.io.FileNotFoundException` (a subtype of `IOException`),
    /// kept distinct from the generic `io_error` so a
    /// `(catch java.io.FileNotFoundException …)` matches a missing-file
    /// slurp/spit while `(catch java.io.IOException …)` still catches it
    /// via the supertype (D-321).
    file_not_found,
    // System
    internal_error,
    out_of_memory,
    /// An in-process eval execution budget (ADR-0125: wall-clock deadline or
    /// step ceiling) was exhausted. Uncatchable (maps to null in
    /// `kindToHostClass`) so untrusted code cannot swallow its own timeout via
    /// `(try … (catch Throwable …))`.
    resource_exhausted,
};

/// Compilation/execution phase where the error occurred.
pub const Phase = enum {
    parse,
    analysis,
    macroexpand,
    eval,
};

/// Where an `Info` originated. `kind` is a meaningful catalog category
/// only for `.catalog`; a user `(throw v)` raises `error.ThrownValue`
/// (not a `ClojureWasmError`), so it has no honest `Kind` — modelling it
/// as a distinct origin keeps the `Kind` ⇄ `ClojureWasmError` 1:1
/// invariant intact rather than minting a `Kind` with no error tag
/// (ADR-0055 amendment 2). `kindLabel` is the single source the text +
/// EDN renderers consult so both formats stay in lockstep.
pub const Origin = enum { catalog, thrown };

/// Structured error information stored in threadlocal state.
pub const Info = struct {
    kind: Kind,
    /// `.catalog` (default) when raised via the catalog; `.thrown` for a
    /// synthetic Info built from a user `(throw v)` at render time. When
    /// `.thrown`, `kind` is unread (use `.value_error` as the inert
    /// placeholder) and `kindLabel` returns `"exception"`.
    origin: Origin = .catalog,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},
    /// `cljw.error/*error-context*` snapshotted at raise time (ADR-0055
    /// D3) — a map Value whose entries the EDN renderer emits as
    /// top-level event fields. null when no provider is installed or the
    /// dynamic var is unbound. Snapshotted (not deref'd at render time)
    /// because the `binding` frame is popped during unwind, before the
    /// renderer runs.
    context: ?Value = null,
    /// ex-data of a thrown `ex-info` Value, emitted as the `:data` EDN
    /// field (ADR-0055 amendment 2). null for catalog errors and for
    /// non-ex-info throws. Distinct from `context` (the ambient
    /// `*error-context*`); this is the data attached to *this* exception.
    data: ?Value = null,
    /// Snapshot of the runtime call stack at raise time, innermost-LAST
    /// (push order), rendered as the `Trace:` section + EDN `:trace`
    /// (ADR-0119 Stage 2). Snapshotted into a threadlocal buffer in
    /// `setErrorFmt` because the live `call_stack` unwinds (every
    /// `defer popFrame`) before the renderer reads it. null when no frames
    /// were pushed (e.g. a parse/analysis error before any call).
    trace: ?[]const StackFrame = null,

    /// The user-visible category label: the catalog `Kind` name, or
    /// `"exception"` for a user throw. Both renderers (text header +
    /// EDN `:kind`) route through this so the two formats never drift.
    pub fn kindLabel(self: Info) []const u8 {
        return switch (self.origin) {
            .catalog => @tagName(self.kind),
            .thrown => "exception",
        };
    }
};

/// Installed by `runtime/error/context.zig` at bootstrap so `setErrorFmt`
/// can snapshot the live `*error-context*` value without `info.zig`
/// importing `env.zig` (kept dependency-free; the provider owns the Var).
var context_provider: ?*const fn () ?Value = null;

pub fn setContextProvider(p: *const fn () ?Value) void {
    context_provider = p;
}

/// Snapshot the live `cljw.error/*error-context*` value via the
/// registered provider. The catalog path snapshots inline in
/// `setErrorFmt`; the throw path calls this from `evalThrow` / `op_throw`
/// so the dynamic-var value is captured **while the `binding` frame is
/// still pushed** — by render time the frame is popped (`defer popFrame`
/// runs during unwind), so a render-time deref would miss it (ADR-0055
/// amendment 2 / D-144). null when no provider is installed or the var
/// is unbound.
pub fn snapshotContext() ?Value {
    return if (context_provider) |p| p() else null;
}

/// Zig error tags. 1:1 with `Kind`.
pub const ClojureWasmError = error{
    SyntaxError,
    NumberError,
    StringError,
    NameError,
    ArityError,
    ValueError,
    NotImplemented,
    TypeError,
    ArithmeticError,
    IndexError,
    IoError,
    FileNotFound,
    InternalError,
    OutOfMemory,
    ResourceExhausted,
};

fn kindToError(kind: Kind) ClojureWasmError {
    return switch (kind) {
        .syntax_error => ClojureWasmError.SyntaxError,
        .number_error => ClojureWasmError.NumberError,
        .string_error => ClojureWasmError.StringError,
        .name_error => ClojureWasmError.NameError,
        .arity_error => ClojureWasmError.ArityError,
        .value_error => ClojureWasmError.ValueError,
        .not_implemented => ClojureWasmError.NotImplemented,
        .type_error => ClojureWasmError.TypeError,
        .arithmetic_error => ClojureWasmError.ArithmeticError,
        .index_error => ClojureWasmError.IndexError,
        .io_error => ClojureWasmError.IoError,
        .file_not_found => ClojureWasmError.FileNotFound,
        .internal_error => ClojureWasmError.InternalError,
        .out_of_memory => ClojureWasmError.OutOfMemory,
        .resource_exhausted => ClojureWasmError.ResourceExhausted,
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

/// Frozen copy of `call_stack` taken at raise time (ADR-0119 Stage 2). The
/// live stack unwinds via `defer popFrame` before the renderer runs, so the
/// `Info.trace` slice points here, not at the (by-then-empty) live stack.
threadlocal var trace_snapshot: [max_call_depth]StackFrame = [_]StackFrame{.{}} ** max_call_depth;

// --- Arg-precise caret side channel (ADR-0118 cycle 2.5) ---
//
// Each call boundary (TreeWalk `evalCall`, VM `op_call`) publishes the
// per-argument source locations just before invoking the callee, so a
// primitive that fails on argument `i` can resolve a caret that lands on
// the culprit operand (`(/ 2 0)` → the `0`) instead of the enclosing call
// form (`(`). The primitive's only new job is to NAME the index via
// `argLoc(i, fallback)` — it never carries or computes a location, keeping
// the mechanism uniform across primitives rather than per-primitive ad hoc.
//
// The slice points at the caller's stack-resident loc array, which is alive
// for the synchronous duration of the call; the boundary swaps the previous
// value back on return (stack-disciplined for nested calls). A culprit that
// does not map to a positional arg slot (variadic fold, lazy-seq element,
// between-subcall raise) falls back through `orelse` to the call-form loc.
threadlocal var arg_sources: []const SourceLocation = &.{};

/// Publish `locs` as the current call's per-argument source locations and
/// return the previous value, so the caller can restore it on return
/// (`const prev = swapArgSources(locs); defer _ = swapArgSources(prev);`).
pub fn swapArgSources(locs: []const SourceLocation) []const SourceLocation {
    const prev = arg_sources;
    arg_sources = locs;
    return prev;
}

/// The source location of argument `i` for the in-flight call, or `null`
/// when `i` is out of range (no positional slot → caller falls back).
pub fn getArgSource(i: usize) ?SourceLocation {
    return if (i < arg_sources.len) arg_sources[i] else null;
}

/// Resolve the caret location for a failure on argument `i`: the arg's own
/// source position when known, else the call-form `fallback`. The single
/// idiom every arg-positional `raise` uses to name its culprit.
pub fn argLoc(i: usize, fallback: SourceLocation) SourceLocation {
    return getArgSource(i) orelse fallback;
}

// --- Core error API ---

/// Set the threadlocal error payload and return the matching Zig error.
/// On message overflow the buffer is truncated with a trailing "...".
pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) ClojureWasmError {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        @memcpy(msg_buf[509..512], "...");
        break :blk msg_buf[0..512];
    };
    // D-334: advance the innermost frame to the error site, so the deepest
    // trace frame shows WHERE in that fn the error is (its own file/line),
    // not the call site it was pushed at. Must precede the snapshot below.
    updateTopFrame(location);
    // Freeze the call stack now (ADR-0119 Stage 2) — `defer popFrame` unwinds
    // the live stack before the renderer reads `.trace`. Same rationale as the
    // `.context` snapshot below.
    const trace_n = stack_depth;
    @memcpy(trace_snapshot[0..trace_n], call_stack[0..trace_n]);
    last_error = .{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
        // Snapshot the live dynamic error-context now — the `binding`
        // frame is popped during unwind, before the renderer reads this.
        .context = if (context_provider) |p| p() else null,
        .trace = if (trace_n > 0) trace_snapshot[0..trace_n] else null,
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

/// Push a frame; returns `true` if it was recorded, `false` if the 64-frame
/// cap was hit (the frame is dropped — best-effort trace). The caller pops
/// only when this returned `true`, keeping push/pop balanced past the cap
/// (ADR-0119 Stage 2: an unconditional `defer popFrame` would underflow).
pub fn pushFrame(frame: StackFrame) bool {
    if (stack_depth < max_call_depth) {
        call_stack[stack_depth] = frame;
        stack_depth += 1;
        return true;
    }
    return false;
}

pub fn popFrame() void {
    if (stack_depth > 0) {
        stack_depth -= 1;
    }
}

/// Move the innermost (top) frame's position to `loc` (ADR-0119 / D-334:
/// execution-point lines). A frame is pushed at its CALL site, then advanced
/// as the fn acts: to each call it makes (the caller is now there), and at
/// raise time to the error site. So a rendered frame shows WHERE in that fn
/// execution currently is — matching its `ns` (the defining module's file),
/// not the caller's call-site file. No-op on an empty stack.
pub fn updateTopFrame(loc: SourceLocation) void {
    if (stack_depth > 0) {
        const fr = &call_stack[stack_depth - 1];
        fr.file = loc.file;
        fr.line = loc.line;
        fr.column = loc.column;
    }
}

pub fn getCallStack() []const StackFrame {
    return call_stack[0..stack_depth];
}

pub fn clearCallStack() void {
    stack_depth = 0;
}

// --- BuiltinFn signature ---

/// Signature of a primitive function: takes the evaluated argument
/// slice plus the call-site location, returns a Value or raises.
pub const BuiltinFn = *const fn (args: []const Value, loc: SourceLocation) ClojureWasmError!Value;

// --- ClojureWasmError formatting ---

/// Render an `Info` into `buf` for human display. Returns a slice of
/// `buf` containing the rendered output (truncated on overflow).
pub fn formatError(info: Info, buf: []u8) []const u8 {
    const result = std.fmt.bufPrint(buf,
        \\{s} [{s}] at {s}:{d}:{d}
        \\  {s}
    , .{
        info.kindLabel(),
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
    try testing.expectEqual(ClojureWasmError.TypeError, err);

    const info = peekLastError().?;
    try testing.expectEqual(Kind.type_error, info.kind);
    try testing.expectEqual(Phase.eval, info.phase);
    try testing.expectEqualStrings("expected number, got nil", info.message);
    try testing.expectEqualStrings("test.clj", info.location.file);
    try testing.expectEqual(@as(u32, 1), info.location.line);
}

fn retSyntaxError() ClojureWasmError!void {
    return setErrorFmt(.parse, .syntax_error, .{}, "bad token", .{});
}

fn retNameError() ClojureWasmError!void {
    return setErrorFmt(.eval, .name_error, .{}, "x not found", .{});
}

test "getLastError clears after read" {
    clearLastError();
    try testing.expectError(ClojureWasmError.SyntaxError, retSyntaxError());
    const info = getLastError();
    try testing.expect(info != null);
    try testing.expectEqual(Kind.syntax_error, info.?.kind);
    try testing.expect(getLastError() == null);
}

test "clearLastError" {
    try testing.expectError(ClojureWasmError.NameError, retNameError());
    clearLastError();
    try testing.expect(peekLastError() == null);
}

test "call stack push/pop and overflow are silent" {
    clearCallStack();
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    try testing.expect(pushFrame(.{ .fn_name = "foo", .ns = "user" }));
    try testing.expect(pushFrame(.{ .fn_name = "bar" }));
    try testing.expectEqual(@as(usize, 2), getCallStack().len);
    try testing.expectEqualStrings("foo", getCallStack()[0].fn_name.?);

    popFrame();
    try testing.expectEqual(@as(usize, 1), getCallStack().len);
    popFrame();
    popFrame(); // pop on empty is safe
    try testing.expectEqual(@as(usize, 0), getCallStack().len);

    for (0..max_call_depth + 10) |i| _ = pushFrame(.{ .line = @truncate(i) });
    try testing.expectEqual(@as(usize, max_call_depth), getCallStack().len);
    clearCallStack();
}

test "kindToError maps every Kind" {
    try testing.expectEqual(ClojureWasmError.SyntaxError, kindToError(.syntax_error));
    try testing.expectEqual(ClojureWasmError.TypeError, kindToError(.type_error));
    try testing.expectEqual(ClojureWasmError.ArityError, kindToError(.arity_error));
    try testing.expectEqual(ClojureWasmError.OutOfMemory, kindToError(.out_of_memory));
}

test "kindLabel: catalog origin yields the Kind tag, thrown yields exception" {
    const cat = Info{ .kind = .type_error, .phase = .eval, .message = "x" };
    try testing.expectEqualStrings("type_error", cat.kindLabel());

    // A thrown Info's `kind` is the inert placeholder and must NOT leak
    // into the label — `origin == .thrown` always renders "exception".
    const thrown = Info{ .kind = .value_error, .origin = .thrown, .phase = .eval, .message = "boom" };
    try testing.expectEqualStrings("exception", thrown.kindLabel());
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
    try testing.expect(std.mem.find(u8, result, "type_error") != null);
    try testing.expect(std.mem.find(u8, result, "core.clj") != null);
    try testing.expect(std.mem.find(u8, result, "expected number, got nil") != null);
}

test "BuiltinFn signature compiles and is invocable" {
    const Fns = struct {
        fn echoFirst(args: []const Value, _: SourceLocation) ClojureWasmError!Value {
            if (args.len == 0) return ClojureWasmError.ArityError;
            return args[0];
        }
    };
    const fp: BuiltinFn = &Fns.echoFirst;
    const result = try fp(&[_]Value{Value.initInteger(7)}, .{});
    try testing.expectEqual(@as(i48, 7), result.asInteger());
}
