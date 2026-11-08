// SPDX-License-Identifier: EPL-2.0
//! host_stream — ONE generic, buffer-backed stream host object backing
//! clojure.java.io's reader/writer/input-stream/output-stream/copy (ADR-0126
//! Cycle 3 / Alt 2). A `.host_instance` (ADR-0106) carrying a `*StreamState`
//! (state[0]); four family descriptors (java.io.{Reader,Writer,InputStream,
//! OutputStream chain) registered in `rt.types` share the impl, distinguished
//! by a `kind` tag — NOT a JVM-style class hierarchy (no-JVM, ADR-0059). Each
//! descriptor is keyed + fqcn'd by its CONCRETE class (the buffered type clj's
//! coercion returns: BufferedReader / BufferedWriter / BufferedInputStream /
//! BufferedOutputStream), so `(class s)` is clj-faithful; its `protocol_impls`
//! is the concrete+superclass chain (the `instance?`-true set). The recognised
//! names + chains live in the `stream_classes` SSOT (shared with
//! `class_name.isKnown`); see that file for the clj-verification.
//!
//! Backend: impl-only
//! Impl deps: file_io
//! Clojure peer: clojure.java.io (reader/writer/input-stream/output-stream/copy)
//!
//! BUFFER-BACKED (not true streaming): a reader/input reads the whole source
//! into an in-memory buffer at open; a writer/output accumulates writes and
//! flushes the buffer to its destination file on `.flush`/`.close`. This is the
//! finished-form-correct shape for the current GC finaliser contract —
//! `host_finalise` has no `io` arg (host_instance.zig), so a lingering OS handle
//! could not be closed there; the buffer is `gc.infra`-owned and freed in the
//! finaliser, while the writer's flush-to-disk lives in the `.close`/`.flush`
//! method (which has `rt.io`). Edge/small-file scope (ADR-0126); a future
//! true-streaming impl can replace StreamState without changing the surface.
//! Byte transport is over Zig `[]u8` — no cljw byte-array Value is surfaced, so
//! D-051 (packed byte-array deferred to Phase 16) is untouched.

const std = @import("std");
const stdin = @import("stdin.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const Value = @import("../value/value.zig").Value;
const SourceLocation = @import("../error/info.zig").SourceLocation;
const error_catalog = @import("../error/catalog.zig");
const host_instance = @import("../host_instance.zig");
const type_descriptor = @import("../type_descriptor.zig");
const TypeDescriptor = type_descriptor.TypeDescriptor;
const file_io = @import("../file_io.zig");
const print_mod = @import("../print.zig");
const string_mod = @import("../collection/string.zig");
const env_mod = @import("../env.zig");
const stream_classes = @import("stream_classes.zig");

/// Re-exported from the stream_classes SSOT so the enum has one definition
/// shared with the chain accessors there.
pub const Kind = stream_classes.Kind;

/// The in-memory backing for one stream. `gc.infra`-owned; the `.host_instance`
/// tag finaliser (routed via the descriptor's `host_finalise`) frees it.
pub const StreamState = struct {
    /// readers/inputs: the source bytes; writers/outputs: the accumulator.
    data: std.ArrayList(u8),
    /// read cursor (readers/inputs).
    pos: usize,
    kind: Kind,
    /// flush target path (writers/outputs), `gc.infra`-duped; null for readers.
    dest: ?[]u8,
    /// Process-stdio sink (ADR-0174 D5b): 0 = none (buffer/file-backed),
    /// 1 = `System/out` (through `rt.stdout` — the ONE shared writer, D-096),
    /// 2 = `System/err` (direct stderr). Writes on an fd stream bypass the
    /// buffer entirely and flush per call (JVM stdout PrintStream autoflush).
    fd: u8 = 0,
    /// `System/in` (ADR-0174 D5b): `data` is demand-filled from process stdin
    /// (blocking chunk reads, matching JVM System.in) rather than pre-loaded —
    /// the same pattern as text_io's `*in*` root reader.
    stdin: bool = false,
    /// stdin mode: a zero-byte read happened — no more fills.
    stdin_eof: bool = false,

    fn deinit(self: *StreamState, infra: std.mem.Allocator) void {
        self.data.deinit(infra);
        if (self.dest) |d| infra.free(d);
    }
};

fn stateOf(recv: Value) *StreamState {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(recv).state[0])));
}

/// Allocate a stream host_instance of `kind` over `data` (taken by value — the
/// ArrayList's storage is owned by the new StreamState) with optional flush
/// `dest`. `data` must already be `gc.infra`-backed.
fn allocStream(rt: *Runtime, kind: Kind, data: std.ArrayList(u8), dest: ?[]u8) !Value {
    const st = try rt.gc.infra.create(StreamState);
    st.* = .{ .data = data, .pos = 0, .kind = kind, .dest = dest };
    // The descriptor pointers are rt.types-owned heap copies (see register); look
    // the live one up so dispatch reads the canonical method_table, not the
    // module-static placeholder.
    const td = rt.types.get(stream_classes.concreteFor(kind)) orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromPtr(st), 0, 0, 0 });
}

// --- instance methods ---

/// `.read` (1-arg) — next byte as an int (0..255), -1 at EOF. (The 4-arg
/// byte-array arm `(.read s ba off len)` defers to Phase 16 with the cljw
/// byte-array Value, D-051.)
fn readByte(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("read", args, 1, loc);
    const st = stateOf(args[0]);
    // System/in demand-fill (ADR-0174 D5b): pull one blocking chunk from
    // process stdin when the buffer is exhausted, JVM System.in-faithful.
    if (st.pos >= st.data.items.len and st.stdin and !st.stdin_eof)
        try stdinFill(rt, st);
    if (st.pos >= st.data.items.len) return Value.initInteger(-1);
    const b = st.data.items[st.pos];
    st.pos += 1;
    return Value.initInteger(@intCast(b));
}

/// stdin mode: append one blocking chunk from process stdin to `data`.
/// A zero-byte read (or error) latches EOF. Mirrors text_io's `*in*` fill.
fn stdinFill(rt: *Runtime, st: *StreamState) !void {
    stdin.beforeFill(rt.gc.infra, &st.data, &st.pos, &rt.gc);
    var chunk: [4096]u8 = undefined;
    const n = stdin.readChunk(rt.io, &chunk) catch {
        st.stdin_eof = true;
        return;
    };
    if (n == 0) {
        st.stdin_eof = true;
        return;
    }
    try st.data.appendSlice(rt.gc.infra, chunk[0..n]);
}

/// `.readLine` — the next line (terminator stripped, `\r\n`/`\n` aware) as a
/// String, or nil at EOF.
fn readLine(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("readLine", args, 1, loc);
    const st = stateOf(args[0]);
    const items = st.data.items;
    if (st.pos >= items.len) return Value.nil_val;
    const nl = std.mem.findScalarPos(u8, items, st.pos, '\n');
    var end = nl orelse items.len;
    const next = if (nl) |n| n + 1 else items.len;
    if (end > st.pos and items[end - 1] == '\r') end -= 1; // strip CRLF's \r
    const line = items[st.pos..end];
    st.pos = next;
    return string_mod.alloc(rt, line);
}

/// Emit `bytes` on a process-stdio stream: fd 1 routes through `rt.stdout`
/// (the ONE shared writer, D-096 — two independent stdout writers clobber)
/// and flushes per call so cljw's own buffered print path and System/out
/// writes never interleave nondeterministically (the JVM stdout PrintStream
/// autoflush contract); fd 2 writes stderr directly (unbuffered).
fn emitFd(rt: *Runtime, fd: u8, bytes: []const u8) anyerror!void {
    if (fd == 1) {
        if (rt.stdout) |w| {
            try w.writeAll(bytes);
            try w.flush();
        } else {
            var buf: [4096]u8 = undefined;
            var fw = std.Io.File.stdout().writer(rt.io, &buf);
            try fw.interface.writeAll(bytes);
            try fw.interface.flush();
        }
        return;
    }
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(rt.io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

/// `.write` (String, or an int byte on a stdio PrintStream) — append the
/// bytes to the accumulator, or emit directly on `System/out` / `System/err`.
fn write(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("write", args, 2, loc);
    const st = stateOf(args[0]);
    if (st.fd != 0) {
        // JVM PrintStream.write(int) writes one byte; write(String) is the
        // print form — accept both on the stdio streams.
        if (args[1].tag() == .integer) {
            const b: u8 = @intCast(args[1].asInteger() & 0xFF);
            try emitFd(rt, st.fd, &[_]u8{b});
            return Value.nil_val;
        }
        if (args[1].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "write", .actual = @tagName(args[1].tag()) });
        try emitFd(rt, st.fd, string_mod.asString(args[1]));
        return Value.nil_val;
    }
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "write", .actual = @tagName(args[1].tag()) });
    try st.data.appendSlice(rt.gc.infra, string_mod.asString(args[1]));
    return Value.nil_val;
}

/// `.print` / `.println` on `System/out` / `System/err` (ADR-0174 D5b):
/// the argument's `str` form (JVM String.valueOf ≈ clj str), println adds
/// the newline; 0-arg println is just the newline. Per-call flush via emitFd.
fn printOnStream(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation, newline: bool, fn_name: []const u8) anyerror!Value {
    try error_catalog.checkArityRange(fn_name, args, 1, 2, loc);
    const st = stateOf(args[0]);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    if (args.len == 2) try print_mod.writeStrValue(rt, env, &aw.writer, args[1]);
    if (newline) try aw.writer.writeByte('\n');
    if (st.fd != 0) {
        try emitFd(rt, st.fd, aw.writer.buffered());
    } else {
        try st.data.appendSlice(rt.gc.infra, aw.writer.buffered());
    }
    return Value.nil_val;
}

fn printFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    // JVM print(x) is 1-arg (receiver + 1); no 0-arg print form.
    try error_catalog.checkArity("print", args, 2, loc);
    return printOnStream(rt, env, args, loc, false, "print");
}

fn printlnFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return printOnStream(rt, env, args, loc, true, "println");
}

/// `.flush` — push the accumulator to the destination file (writers/outputs);
/// on a stdio stream, flush the shared stdout writer (stderr is unbuffered).
fn flush(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("flush", args, 1, loc);
    const st = stateOf(args[0]);
    if (st.fd == 1) {
        if (rt.stdout) |w| try w.flush();
        return Value.nil_val;
    }
    if (st.fd == 2) return Value.nil_val; // stderr is written unbuffered
    if (st.dest) |dest|
        file_io.writeAll(rt.io, dest, st.data.items) catch |e|
            return error_catalog.raise(.file_io_error, loc, .{ .op = "flush", .path = dest, .detail = @errorName(e) });
    return Value.nil_val;
}

/// `.close` — flush (writers) then release. The buffer is freed by the GC
/// finaliser; close itself only flushes (readers: no-op).
fn close(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("close", args, 1, loc);
    const st = stateOf(args[0]);
    if (st.dest != null) return flush(rt, env, args, loc);
    return Value.nil_val;
}

// --- rt/ primitives (the construction + bulk paths clojure.java.io calls) ---

fn jailedOpen(rt: *Runtime, p: []const u8, fn_name: []const u8, loc: SourceLocation) anyerror!?[]u8 {
    return file_io.jailResolve(rt.gpa, rt.fs_jail_root, p) catch |e| switch (e) {
        error.OutOfMemory => e,
        error.FsJailEscape => error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = fn_name, .path = p }),
    };
}

/// Read the whole file at `path` (jail-resolved) into a fresh gc.infra buffer
/// and mint a stream of `kind` (reader or input).
fn openFileStream(rt: *Runtime, kind: Kind, path: []const u8, fn_name: []const u8, loc: SourceLocation) anyerror!Value {
    const j = try jailedOpen(rt, path, fn_name, loc);
    defer if (j) |x| rt.gpa.free(x);
    const open_path = j orelse path;
    const bytes = file_io.readAll(rt.io, rt.gpa, open_path) catch |e|
        return error_catalog.raise(.file_io_error, loc, .{ .op = fn_name, .path = path, .detail = @errorName(e) });
    defer rt.gpa.free(bytes);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(rt.gc.infra);
    try data.appendSlice(rt.gc.infra, bytes);
    return allocStream(rt, kind, data, null);
}

/// Open a writer/output over `path` (jail-resolved at open; flush writes there).
fn openFileSink(rt: *Runtime, kind: Kind, path: []const u8, fn_name: []const u8, loc: SourceLocation) anyerror!Value {
    const j = try jailedOpen(rt, path, fn_name, loc);
    // The flush target is the resolved path (so the file written is the one the
    // jail checked). Own a gc.infra copy for the StreamState's lifetime.
    const resolved = j orelse path;
    const dest = try rt.gc.infra.dupe(u8, resolved);
    if (j) |x| rt.gpa.free(x);
    return allocStream(rt, kind, .empty, dest);
}

fn openReaderFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__open-reader", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__open-reader", .actual = @tagName(args[0].tag()) });
    return openFileStream(rt, .reader, string_mod.asString(args[0]), "reader", loc);
}

fn openInputStreamFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__open-input-stream", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__open-input-stream", .actual = @tagName(args[0].tag()) });
    return openFileStream(rt, .input, string_mod.asString(args[0]), "input-stream", loc);
}

fn openWriterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__open-writer", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__open-writer", .actual = @tagName(args[0].tag()) });
    return openFileSink(rt, .writer, string_mod.asString(args[0]), "writer", loc);
}

fn openOutputStreamFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__open-output-stream", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__open-output-stream", .actual = @tagName(args[0].tag()) });
    return openFileSink(rt, .output, string_mod.asString(args[0]), "output-stream", loc);
}

/// Construct a buffer-backed Reader from a StringReader constructor.
pub fn mintReader(rt: *Runtime, bytes: []const u8) !Value {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(rt.gc.infra);
    try data.appendSlice(rt.gc.infra, bytes);
    return allocStream(rt, .reader, data, null);
}

/// `(rt/__string-reader s)` — a reader over the bytes of String `s`.
fn stringReaderFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__string-reader", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__string-reader", .actual = @tagName(args[0].tag()) });
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(rt.gc.infra);
    try data.appendSlice(rt.gc.infra, string_mod.asString(args[0]));
    return allocStream(rt, .reader, data, null);
}

/// `(rt/__stream-slurp s)` — the remaining buffer of a reader/input as a String.
fn streamSlurpFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__stream-slurp", args, 1, loc);
    if (!isStream(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__stream-slurp", .expected = "a reader/input stream", .actual = @tagName(args[0].tag()) });
    const st = stateOf(args[0]);
    const rest = st.data.items[st.pos..];
    st.pos = st.data.items.len;
    return string_mod.alloc(rt, rest);
}

/// `(rt/__stream-copy in out)` — drain reader/input `in`'s remaining bytes into
/// writer/output `out`'s accumulator (over Zig `[]u8`, no byte-array Value).
fn streamCopyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__stream-copy", args, 2, loc);
    if (!isStream(args[0]) or !isStream(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__stream-copy", .expected = "two streams", .actual = @tagName(args[0].tag()) });
    const in = stateOf(args[0]);
    const out = stateOf(args[1]);
    try out.data.appendSlice(rt.gc.infra, in.data.items[in.pos..]);
    in.pos = in.data.items.len;
    return Value.nil_val;
}

fn isStream(v: Value) bool {
    if (v.tag() != .host_instance) return false;
    return isStreamFqcn(host_instance.asHostInstance(v).descriptor.fqcn);
}

/// Borrow the unread buffer for one EDN form without draining later forms.
pub fn remainingReader(rt: *Runtime, v: Value) !?[]const u8 {
    if (!isStream(v)) return null;
    const st = stateOf(v);
    if (st.kind != .reader) return null;
    while (st.stdin and !st.stdin_eof) try stdinFill(rt, st);
    return st.data.items[st.pos..];
}

pub fn advanceReader(v: Value, bytes: usize) void {
    stateOf(v).pos += bytes;
}

/// D-471 IOFactory arms for `slurp`: when `v` is an open reader/input-stream
/// host_stream, return the UNREAD remainder of its buffer and advance the
/// cursor to the end (what draining the JVM Reader does). A `System/in`-backed
/// stream blocks pulling process stdin to EOF first, so the remainder is the
/// whole input rather than whatever a prior `.read` happened to buffer
/// (symmetric with text_io's `*in*` drain). Null when `v` is not a readable
/// stream — the caller falls through to its path handling.
pub fn drainRemaining(rt: *Runtime, v: Value) !?[]const u8 {
    if (!isStream(v)) return null;
    const st = stateOf(v);
    switch (st.kind) {
        .reader, .input => {},
        else => return null,
    }
    while (st.stdin and !st.stdin_eof) try stdinFill(rt, st);
    const rest_bytes = st.data.items[st.pos..];
    st.pos = st.data.items.len;
    return rest_bytes;
}

/// D-471 IOFactory arms for `spit`: when `v` is an open writer/output-stream
/// host_stream, append `bytes` and flush-to-dest (clj's spit closes the
/// writer it opened; for a caller-owned writer this durable-writes without
/// invalidating it). Returns false when `v` is not a writable stream.
pub fn appendAndFlush(rt: *Runtime, v: Value, bytes: []const u8, loc: SourceLocation) anyerror!bool {
    if (!isStream(v)) return false;
    const st = stateOf(v);
    switch (st.kind) {
        .writer, .output => {},
        else => return false,
    }
    try st.data.appendSlice(rt.gc.infra, bytes);
    if (st.dest) |dest| {
        file_io.writeAll(rt.io, dest, st.data.items) catch |e|
            return error_catalog.raise(.file_io_error, loc, .{ .op = "spit", .path = dest, .detail = @errorName(e) });
    }
    return true;
}

fn isStreamFqcn(fqcn: ?[]const u8) bool {
    const n = fqcn orelse return false;
    // A live stream value's descriptor fqcn is its concrete class (BufferedReader …).
    return stream_classes.isConcrete(n);
}

// --- GC finaliser ---

/// `.host_instance` finaliser hook: free the StreamState's buffer + dest + the
/// struct. No `io` (per the contract) — the writer's flush-to-disk already
/// happened in `.close`/`.flush`; an unflushed writer simply loses its buffer
/// (matching "you must close to persist").
fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const st: *StreamState = @ptrFromInt(@as(usize, @intCast(state[0])));
    st.deinit(infra);
    infra.destroy(st);
}

// --- registration ---

const Method = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const READER_METHODS = [_]Method{ .{ .name = "read", .f = &readByte }, .{ .name = "readLine", .f = &readLine }, .{ .name = "close", .f = &close } };
const WRITER_METHODS = [_]Method{ .{ .name = "write", .f = &write }, .{ .name = "flush", .f = &flush }, .{ .name = "close", .f = &close } };
// System/out + System/err (ADR-0174 D5b). `.close` is deliberately absent:
// closing the process stdio is not modelled (nobody sane closes System/out;
// the D3 member diagnostic renders the honest error).
const PRINT_METHODS = [_]Method{ .{ .name = "write", .f = &write }, .{ .name = "print", .f = &printFn }, .{ .name = "println", .f = &printlnFn }, .{ .name = "flush", .f = &flush } };

// Leaf class names recognised by `instance?` live in the stream_classes SSOT
// (D-358) as fully-qualified `java.io.*` names, shared with class_name.isKnown
// so the `__instance?` precheck and the matchUserType arm cannot drift.

/// Build one family descriptor into `rt.types` (gpa-owned per the `rt.deinit`
/// contract: key, fqcn, each method_name + the method_table slice, and the
/// protocol_impls slice are all freed there).
fn registerDescriptor(rt: *Runtime, kind: Kind, methods: []const Method) !void {
    const gpa = rt.gpa;
    const fqcn = stream_classes.concreteFor(kind);
    const chain = stream_classes.chainFor(kind);
    const td = try gpa.create(TypeDescriptor);
    errdefer gpa.destroy(td);

    const entries = try gpa.alloc(TypeDescriptor.MethodEntry, methods.len);
    for (methods, 0..) |m, i| {
        entries[i] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, m.name), .method_val = Value.initBuiltinFn(m.f) };
    }
    // protocol_impls = the concrete+superclass chain (the instance?-true set);
    // the slice is gpa-freed at deinit (entries are static literals).
    const impls = try gpa.alloc([]const u8, chain.len);
    @memcpy(impls, chain);

    td.* = .{
        .fqcn = try gpa.dupe(u8, fqcn),
        .kind = .native,
        .field_layout = null,
        .protocol_impls = impls,
        .method_table = entries,
        .parent = null,
        .meta = .nil_val,
        .host_finalise = &finaliseState,
    };
    const key = try gpa.dupe(u8, fqcn);
    try rt.types.put(key, td);
}

const Prim = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };
const PRIMS = [_]Prim{
    .{ .name = "__open-reader", .f = &openReaderFn },
    .{ .name = "__open-input-stream", .f = &openInputStreamFn },
    .{ .name = "__open-writer", .f = &openWriterFn },
    .{ .name = "__open-output-stream", .f = &openOutputStreamFn },
    .{ .name = "__string-reader", .f = &stringReaderFn },
    .{ .name = "__stream-slurp", .f = &streamSlurpFn },
    .{ .name = "__stream-copy", .f = &streamCopyFn },
};

/// Register the five stream family descriptors in `rt.types` + the `rt/__*`
/// stream primitives. Called from `primitive.registerAll`.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    const rt = env.rt;
    // Each descriptor is keyed + fqcn'd by its CONCRETE class (BufferedReader …)
    // so `(class s)` is clj-faithful; protocol_impls is the concrete+superclass
    // chain (the instance?-true set). reader/input share read methods; writer/
    // output share write methods; print (System/out + err) adds print/println.
    if (!rt.types.contains(stream_classes.concreteFor(.reader))) {
        try registerDescriptor(rt, .reader, &READER_METHODS);
        try registerDescriptor(rt, .writer, &WRITER_METHODS);
        try registerDescriptor(rt, .input, &READER_METHODS);
        try registerDescriptor(rt, .output, &WRITER_METHODS);
        try registerDescriptor(rt, .print, &PRINT_METHODS);
    }
    for (PRIMS) |p| {
        _ = try env.intern(rt_ns, p.name, Value.initBuiltinFn(p.f), null);
    }
}

// --- System/in, System/out, System/err singletons (ADR-0174 D5b) ---

/// Mint one process-stdio stream singleton: `which` 0 = in (input kind,
/// stdin demand-fill), 1 = out, 2 = err (print kind, fd emit). Cached on
/// the Runtime + `gc.pin`ned (process-lifetime, the compiler_specials
/// pattern) — `(identical? System/out System/out)` holds.
pub fn systemStream(rt: *Runtime, which: u8) !Value {
    const slot: *Value = switch (which) {
        0 => &rt.system_in_val,
        1 => &rt.system_out_val,
        else => &rt.system_err_val,
    };
    if (!slot.isNil()) return slot.*;
    const st = try rt.gc.infra.create(StreamState);
    st.* = .{
        .data = .empty,
        .pos = 0,
        .kind = if (which == 0) .input else .print,
        .dest = null,
        .fd = if (which == 0) 0 else which,
        .stdin = which == 0,
    };
    // Registration precedes any resolvable `System/out` read (register() runs
    // in primitive.registerAll); a miss is a startup-order bug, not a user error.
    const td = rt.types.get(stream_classes.concreteFor(st.kind)) orelse return error.InternalError;
    const v = try host_instance.alloc(rt, td, .{ @intFromPtr(st), 0, 0, 0 });
    try rt.gc.pin(v);
    slot.* = v;
    return v;
}
