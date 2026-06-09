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
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const Value = @import("../value/value.zig").Value;
const SourceLocation = @import("../error/info.zig").SourceLocation;
const error_catalog = @import("../error/catalog.zig");
const host_instance = @import("../host_instance.zig");
const type_descriptor = @import("../type_descriptor.zig");
const TypeDescriptor = type_descriptor.TypeDescriptor;
const file_io = @import("../file_io.zig");
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

    fn deinit(self: *StreamState, infra: std.mem.Allocator) void {
        self.data.deinit(infra);
        if (self.dest) |d| infra.free(d);
    }
};

fn stateOf(recv: Value) *StreamState {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
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
    _ = rt;
    _ = env;
    try error_catalog.checkArity("read", args, 1, loc);
    const st = stateOf(args[0]);
    if (st.pos >= st.data.items.len) return Value.initInteger(-1);
    const b = st.data.items[st.pos];
    st.pos += 1;
    return Value.initInteger(@intCast(b));
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

/// `.write` (String) — append the string's bytes to the accumulator.
fn write(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("write", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "write", .actual = @tagName(args[1].tag()) });
    const st = stateOf(args[0]);
    try st.data.appendSlice(rt.gc.infra, string_mod.asString(args[1]));
    return Value.nil_val;
}

/// `.flush` — push the accumulator to the destination file (writers/outputs).
fn flush(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("flush", args, 1, loc);
    const st = stateOf(args[0]);
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
    const st: *StreamState = @ptrFromInt(state[0]);
    st.deinit(infra);
    infra.destroy(st);
}

// --- registration ---

const Method = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const READER_METHODS = [_]Method{ .{ .name = "read", .f = &readByte }, .{ .name = "readLine", .f = &readLine }, .{ .name = "close", .f = &close } };
const WRITER_METHODS = [_]Method{ .{ .name = "write", .f = &write }, .{ .name = "flush", .f = &flush }, .{ .name = "close", .f = &close } };

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

/// Register the four stream family descriptors in `rt.types` + the `rt/__*`
/// stream primitives. Called from `primitive.registerAll`.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    const rt = env.rt;
    // Each descriptor is keyed + fqcn'd by its CONCRETE class (BufferedReader …)
    // so `(class s)` is clj-faithful; protocol_impls is the concrete+superclass
    // chain (the instance?-true set). reader/input share read methods; writer/
    // output share write methods.
    if (!rt.types.contains(stream_classes.concreteFor(.reader))) {
        try registerDescriptor(rt, .reader, &READER_METHODS);
        try registerDescriptor(rt, .writer, &WRITER_METHODS);
        try registerDescriptor(rt, .input, &READER_METHODS);
        try registerDescriptor(rt, .output, &WRITER_METHODS);
    }
    for (PRIMS) |p| {
        _ = try env.intern(rt_ns, p.name, Value.initBuiltinFn(p.f), null);
    }
}
