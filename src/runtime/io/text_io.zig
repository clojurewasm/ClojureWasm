// SPDX-License-Identifier: EPL-2.0
//! text_io — the durable, cljw-native Writer VALUE backing `*out*`/`*err*`
//! (the Reader value backing `*in*` joins in build-step 3). ADR-0138 Track C.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/*out* /*err* (roots flip to these in build-step 2)
//!
//! A `.host_instance` (F-004's declared writer home, tag 29 — no new NaN-box
//! slot) carrying a `*WriterState` (state[0]) whose `mode` selects the sink:
//!   - `.stdout` — write-through to `rt.stdout` (the D-096 single offset-tracking
//!     interleave with the runner's result-print); per-call flush, NOT buffered.
//!   - `.stderr` — write-through to the process stderr.
//!   - `.string` — owns a `gc.infra` accumulator; `__writer->str` reads it. Backs
//!     `with-out-str` (build-step 2).
//! Descriptor `fqcn = "Writer"` (simple name per AD-003 / ADR-0059 no-JVM — no
//! Charset/PrintWriter/BufferedWriter hierarchy). Distinct from
//! `host_stream.zig`'s file streams (`BufferedWriter`, buffer-to-disk) and from
//! `writer_value.zig`'s BORROWED single-print-scoped print-method handle; the
//! shared "Writer" name is cosmetic — dispatch reads the descriptor from the
//! instance, and the three model genuinely different lifetimes (ADR-0138).

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const Value = @import("../value/value.zig").Value;
const SourceLocation = @import("../error/info.zig").SourceLocation;
const error_catalog = @import("../error/catalog.zig");
const host_instance = @import("../host_instance.zig");
const type_descriptor = @import("../type_descriptor.zig");
const TypeDescriptor = type_descriptor.TypeDescriptor;
const string_mod = @import("../collection/string.zig");
const env_mod = @import("../env.zig");

/// The sink a Writer value routes to. `.string` owns the accumulator; the
/// process modes write through and own no buffer.
const Mode = enum { stdout, stderr, string };

/// `gc.infra`-owned backing for one Writer value. The `.host_instance` finaliser
/// frees it. Holds no GC Value (just bytes) → no `host_trace` needed.
const WriterState = struct {
    mode: Mode,
    /// `.string`-mode accumulator; stays empty for the process modes.
    buf: std.ArrayList(u8),
};

fn stateOf(recv: Value) *WriterState {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// True iff `v` is a text_io Writer value (descriptor identity, not fqcn — the
/// "Writer" name is shared with writer_value/host_stream).
pub fn isTextWriter(v: Value) bool {
    return v.tag() == .host_instance and
        host_instance.asHostInstance(v).descriptor == &writer_descriptor;
}

/// Push `bytes` to the writer's sink per its mode.
fn emitBytes(rt: *Runtime, st: *WriterState, bytes: []const u8) anyerror!void {
    switch (st.mode) {
        .string => try st.buf.appendSlice(rt.gc.infra, bytes),
        .stdout => {
            if (rt.stdout) |w| {
                try w.writeAll(bytes);
                try w.flush();
            } else {
                var b: [4096]u8 = undefined;
                var fw = std.Io.File.stdout().writer(rt.io, &b);
                const w = &fw.interface;
                try w.writeAll(bytes);
                try w.flush();
            }
        },
        .stderr => {
            var b: [4096]u8 = undefined;
            var fw = std.Io.File.stderr().writer(rt.io, &b);
            const w = &fw.interface;
            try w.writeAll(bytes);
            try w.flush();
        },
    }
}

/// The bytes to emit for a `.write`/`.append` content arg: a String writes raw;
/// an integer writes that Unicode codepoint as UTF-8 (Java `Writer.write(int)`).
/// `scratch` backs the codepoint encoding for the integer arm. Anything else
/// raises — never a silent drop.
fn contentBytes(arg: Value, scratch: *[4]u8, fn_name: []const u8, loc: SourceLocation) anyerror![]const u8 {
    if (arg.tag() == .string) return string_mod.asString(arg);
    if (arg.tag() == .integer) {
        const cp = arg.asInteger();
        if (cp >= 0 and cp <= 0x10FFFF) {
            const n = std.unicode.utf8Encode(@intCast(cp), scratch) catch
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a valid codepoint", .actual = "out-of-range int" });
            return scratch[0..n];
        }
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a string or codepoint int", .actual = @tagName(arg.tag()) });
}

/// `(.write w s)` / `(.write w cp)` — append the content; returns nil (Java void).
fn writeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("write", args, 2, loc);
    var scratch: [4]u8 = undefined;
    try emitBytes(rt, stateOf(args[0]), try contentBytes(args[1], &scratch, "write", loc));
    return Value.nil_val;
}

/// `(.append w s)` — append the content; returns the writer (chainable).
fn appendMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("append", args, 2, loc);
    var scratch: [4]u8 = undefined;
    try emitBytes(rt, stateOf(args[0]), try contentBytes(args[1], &scratch, "append", loc));
    return args[0];
}

/// `(.flush w)` — process modes flush per-call already (no-op); returns nil.
fn flushMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("flush", args, 1, loc);
    return Value.nil_val;
}

/// `(.close w)` — no-op (string buffer freed by the GC finaliser; process modes
/// own no resource); returns nil.
fn closeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("close", args, 1, loc);
    return Value.nil_val;
}

// --- GC finaliser ---

/// Free the WriterState buffer + the struct. No `io` (per the host_instance
/// finaliser contract); a `.string` writer holds only bytes.
fn finaliseWriter(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const st: *WriterState = @ptrFromInt(state[0]);
    st.buf.deinit(infra);
    infra.destroy(st);
}

// --- descriptor (module-static; cf. writer_value.zig) ---

var writer_methods: [4]TypeDescriptor.MethodEntry = undefined;
var writer_methods_inited: bool = false;

var writer_descriptor: TypeDescriptor = .{
    .fqcn = "Writer",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .host_finalise = &finaliseWriter,
};

/// Fill the Writer descriptor's static method_table (idempotent). Called at
/// bootstrap (`initBuiltinFn` is a runtime `@intFromPtr`, so not comptime).
pub fn initTextIoTypes() void {
    if (writer_methods_inited) return;
    writer_methods[0] = .{ .protocol_name = "", .method_name = "write", .method_val = Value.initBuiltinFn(&writeMethod) };
    writer_methods[1] = .{ .protocol_name = "", .method_name = "append", .method_val = Value.initBuiltinFn(&appendMethod) };
    writer_methods[2] = .{ .protocol_name = "", .method_name = "flush", .method_val = Value.initBuiltinFn(&flushMethod) };
    writer_methods[3] = .{ .protocol_name = "", .method_name = "close", .method_val = Value.initBuiltinFn(&closeMethod) };
    writer_descriptor.method_table = &writer_methods;
    writer_methods_inited = true;
}

/// Mint a Writer value of `mode`. The `.string` accumulator starts empty.
pub fn mintWriter(rt: *Runtime, mode: Mode) !Value {
    const st = try rt.gc.infra.create(WriterState);
    st.* = .{ .mode = mode, .buf = .empty };
    return host_instance.alloc(rt, &writer_descriptor, .{ @intFromPtr(st), 0, 0, 0 });
}

/// Mint a fresh `.string` writer — the capture sink for `with-out-str` / nREPL.
pub fn mintStringWriter(rt: *Runtime) !Value {
    return mintWriter(rt, .string);
}

/// The accumulated bytes of a `.string` writer (empty for process modes). Used by
/// nREPL to read a captured-eval's stdout after the `*out*` binding pops.
pub fn writerBytes(v: Value) []const u8 {
    return stateOf(v).buf.items;
}

/// Fast path for the print pipeline: if `wv` is a text_io Writer, push `bytes`
/// to its sink directly (no `.write` method-dispatch round-trip) and return
/// true; otherwise false so the caller tries other writer kinds.
pub fn writeBytesIfWriter(rt: *Runtime, wv: Value, bytes: []const u8) !bool {
    if (!isTextWriter(wv)) return false;
    try emitBytes(rt, stateOf(wv), bytes);
    return true;
}

// --- rt/ primitives ---

fn stdoutWriterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__stdout-writer", args, 0, loc);
    return mintWriter(rt, .stdout);
}

fn stderrWriterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__stderr-writer", args, 0, loc);
    return mintWriter(rt, .stderr);
}

fn stringWriterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__string-writer", args, 0, loc);
    return mintWriter(rt, .string);
}

/// `(rt/__writer->str w)` — the accumulated string of a writer (`.string`
/// mode; process modes own no buffer so return ""). Backs `with-out-str`.
fn writerToStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__writer->str", args, 1, loc);
    if (!isTextWriter(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__writer->str", .expected = "a writer", .actual = @tagName(args[0].tag()) });
    return string_mod.alloc(rt, stateOf(args[0]).buf.items);
}

const Prim = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };
const PRIMS = [_]Prim{
    .{ .name = "__stdout-writer", .f = &stdoutWriterFn },
    .{ .name = "__stderr-writer", .f = &stderrWriterFn },
    .{ .name = "__string-writer", .f = &stringWriterFn },
    .{ .name = "__writer->str", .f = &writerToStrFn },
};

/// Register the text_io `rt/__*` writer primitives. Called from
/// `primitive.registerAll`. The descriptor method_table is filled at bootstrap
/// via `initTextIoTypes` (lang/bootstrap.zig), like writer_value.zig.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    // Fill the method_table BEFORE core.clj loads — its `(def *out* (rt/__stdout-writer))`
    // (core.clj) mints a Writer at bootstrap, and any print during load dispatches
    // on this table. register() runs in primitive.registerAll, before loadCore.
    initTextIoTypes();
    for (PRIMS) |p| {
        _ = try env.intern(rt_ns, p.name, Value.initBuiltinFn(p.f), null);
    }
}
