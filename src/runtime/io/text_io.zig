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
const string_escape = @import("../string_escape.zig");
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

// ============================ Reader value (ADR-0138) ============================
// The durable cljw-native Reader VALUE backing `*in*` — fqcn "Reader" (simple),
// string-backed + a 1-slot CODEPOINT pushback (the `?u21` per ADR-0138, NOT a
// byte decrement — a byte decrement corrupts multibyte codepoints). Distinct
// from host_stream's file BufferedReader: JVM `*in*` is a PushbackReader, a file
// reader is a plain BufferedReader — different class families, so cljw keeps the
// pushback reader (here, for `*in*`/`with-in-str`) separate from the file reader.

/// `gc.infra`-owned backing for one Reader value (the GC finaliser frees it).
const ReaderState = struct {
    /// the source bytes (UTF-8).
    data: std.ArrayList(u8),
    /// read cursor (byte offset).
    pos: usize,
    /// 1-slot codepoint pushback (`.unread`); consulted first by `.read`/`.peek`.
    pushback: ?u21,
    /// stdin mode (the `*in*` root reader): `data` is a demand-filled buffer
    /// pulled from process stdin (blocking, matching clj's `System.in`) rather
    /// than a fixed string. False for `with-in-str` string readers.
    stdin: bool = false,
    /// stdin mode: a zero-byte read happened — no more fills.
    stdin_eof: bool = false,
};

/// stdin mode: pull one chunk from process stdin into `data`. Returns false
/// when EOF (or a read error, treated as EOF) ends the stream. Blocking on a
/// TTY is the correct clj-parity behaviour (read-line waits for input).
fn fillFromStdin(rt: *Runtime, st: *ReaderState) bool {
    if (st.stdin_eof) return false;
    var chunk: [4096]u8 = undefined;
    const n = std.posix.read(std.Io.File.stdin().handle, &chunk) catch {
        st.stdin_eof = true;
        return false;
    };
    if (n == 0) {
        st.stdin_eof = true;
        return false;
    }
    st.data.appendSlice(rt.gc.infra, chunk[0..n]) catch {
        st.stdin_eof = true;
        return false;
    };
    return true;
}

/// stdin mode: buffer until a full line (`\n` past `pos`) or EOF is present,
/// so the readLine slice logic sees the same world a string reader does.
fn ensureLineBuffered(rt: *Runtime, st: *ReaderState) void {
    if (!st.stdin) return;
    while (std.mem.findScalarPos(u8, st.data.items, st.pos, '\n') == null and !st.stdin_eof) {
        if (!fillFromStdin(rt, st)) break;
    }
}

/// stdin mode: buffer at least one full codepoint (≤ 4 bytes) past `pos` or
/// EOF, so `decodeAt` never mistakes a chunk-boundary split for invalid UTF-8.
fn ensureCodepointBuffered(rt: *Runtime, st: *ReaderState) void {
    if (!st.stdin) return;
    while (st.data.items.len < st.pos + 4 and !st.stdin_eof) {
        if (!fillFromStdin(rt, st)) break;
    }
}

fn readerStateOf(recv: Value) *ReaderState {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// True iff `v` is a text_io Reader value (descriptor identity).
pub fn isTextReader(v: Value) bool {
    return v.tag() == .host_instance and
        host_instance.asHostInstance(v).descriptor == &reader_descriptor;
}

/// Decode the codepoint at `st.pos` + its UTF-8 byte length, or null at EOF.
/// Invalid UTF-8 degrades to the raw byte as a 1-byte codepoint (no crash).
const Decoded = struct { cp: u21, len: usize };
fn decodeAt(st: *ReaderState) ?Decoded {
    if (st.pos >= st.data.items.len) return null;
    const rest = st.data.items[st.pos..];
    const byte_fallback: Decoded = .{ .cp = rest[0], .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return byte_fallback;
    if (n > rest.len) return byte_fallback;
    // utf8Decode is deprecated (awkward API); the fixed-width variants take a
    // by-value array and are the non-deprecated form.
    const cp: u21 = switch (n) {
        1 => rest[0],
        2 => std.unicode.utf8Decode2(rest[0..2].*) catch return byte_fallback,
        3 => std.unicode.utf8Decode3(rest[0..3].*) catch return byte_fallback,
        4 => std.unicode.utf8Decode4(rest[0..4].*) catch return byte_fallback,
        else => return byte_fallback,
    };
    return .{ .cp = cp, .len = n };
}

/// `(.read r)` — next codepoint as an int (JVM Reader.read), -1 at EOF. Honors a
/// pending `.unread` first.
fn readCharMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("read", args, 1, loc);
    const st = readerStateOf(args[0]);
    if (st.pushback) |cp| {
        st.pushback = null;
        return Value.initInteger(@intCast(cp));
    }
    ensureCodepointBuffered(rt, st);
    const d = decodeAt(st) orelse return Value.initInteger(-1);
    st.pos += d.len;
    return Value.initInteger(@intCast(d.cp));
}

/// `(.peek r)` — next codepoint as an int WITHOUT advancing; -1 at EOF.
fn peekCharMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("peek", args, 1, loc);
    const st = readerStateOf(args[0]);
    if (st.pushback) |cp| return Value.initInteger(@intCast(cp));
    ensureCodepointBuffered(rt, st);
    const d = decodeAt(st) orelse return Value.initInteger(-1);
    return Value.initInteger(@intCast(d.cp));
}

/// `(.unread r cp)` — push the codepoint `cp` back so the next `.read` returns it
/// (1-slot; a second unread before a read overwrites). Returns nil.
fn unreadCharMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("unread", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "unread", .expected = "a codepoint int", .actual = @tagName(args[1].tag()) });
    const cp = args[1].asInteger();
    if (cp < 0 or cp > 0x10FFFF)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "unread", .expected = "a valid codepoint", .actual = "out-of-range int" });
    readerStateOf(args[0]).pushback = @intCast(cp);
    return Value.nil_val;
}

/// `(.readLine r)` — the next line (terminator stripped, `\r\n`/`\n` aware) as a
/// String, or nil at EOF. A pending `.unread` codepoint prefixes the line.
fn readLineMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("readLine", args, 1, loc);
    const st = readerStateOf(args[0]);
    // stdin mode: buffer the full line first so both branches below see the
    // same world a string reader does (D-414 stdin root).
    ensureLineBuffered(rt, st);
    // Fast path: no pushback → return a slice of the source (cf. host_stream).
    if (st.pushback == null) {
        const items = st.data.items;
        if (st.pos >= items.len) return Value.nil_val;
        const nl = std.mem.findScalarPos(u8, items, st.pos, '\n');
        var end = nl orelse items.len;
        const next = if (nl) |n| n + 1 else items.len;
        if (end > st.pos and items[end - 1] == '\r') end -= 1;
        const line = items[st.pos..end];
        st.pos = next;
        return string_mod.alloc(rt, line);
    }
    // Pushback present: prepend the pushed codepoint, then the line bytes.
    const cp = st.pushback.?;
    st.pushback = null;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
    if (cp == '\n') return string_mod.alloc(rt, ""); // pushed newline = empty line
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(rt.gpa);
    try line.appendSlice(rt.gpa, buf[0..n]);
    const items = st.data.items;
    const nl = std.mem.findScalarPos(u8, items, st.pos, '\n');
    var end = nl orelse items.len;
    const next = if (nl) |x| x + 1 else items.len;
    if (end > st.pos and items[end - 1] == '\r') end -= 1;
    try line.appendSlice(rt.gpa, items[st.pos..end]);
    st.pos = next;
    return string_mod.alloc(rt, line.items);
}

/// `(.close r)` — no-op (buffer freed by the GC finaliser); returns nil.
fn readerCloseMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("close", args, 1, loc);
    return Value.nil_val;
}

/// The folded `clojure.lang.LispReader$StringReader` reader-macro (D-414). Reads a
/// string LITERAL from `args[0]` (an `*in*` Reader) — the bytes up to + consuming
/// the closing `"`, escape-aware so `\"` does not terminate — and returns the
/// decoded String. The opening `"` is assumed already consumed (clj's LispReader
/// contract). Extra args (quote-char / opts / pending) are accepted + IGNORED.
/// `(clojure.lang.LispReader$StringReader.)` returns this fn (special_forms ctor).
pub fn lispStringReader(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or !isTextReader(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "LispReader$StringReader", .expected = "a reader (*in*)", .actual = if (args.len < 1) "no args" else @tagName(args[0].tag()) });
    const st = readerStateOf(args[0]);
    const items = st.data.items;
    var i = st.pos;
    const start = i;
    while (i < items.len) {
        if (items[i] == '\\') {
            i += if (i + 1 < items.len) 2 else 1; // skip the escaped char so `\"` is literal
            continue;
        }
        if (items[i] == '"') break;
        i += 1;
    }
    const raw = items[start..i];
    const had_escape = std.mem.findScalar(u8, raw, '\\') != null;
    const decoded = try string_escape.unescape(rt.gc.infra, raw, loc);
    defer if (had_escape) rt.gc.infra.free(decoded);
    const result = try string_mod.alloc(rt, decoded);
    st.pos = if (i < items.len) i + 1 else i; // consume the closing quote
    return result;
}

/// Mint a Reader value over the bytes of `bytes` (UTF-8). `bytes` is copied into a
/// fresh gc.infra buffer.
pub fn mintReader(rt: *Runtime, bytes: []const u8) !Value {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(rt.gc.infra);
    try data.appendSlice(rt.gc.infra, bytes);
    const st = try rt.gc.infra.create(ReaderState);
    st.* = .{ .data = data, .pos = 0, .pushback = null };
    return host_instance.alloc(rt, &reader_descriptor, .{ @intFromPtr(st), 0, 0, 0 });
}

/// Free the ReaderState buffer + the struct (GC finaliser hook).
fn finaliseReader(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const st: *ReaderState = @ptrFromInt(state[0]);
    st.data.deinit(infra);
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

var reader_methods: [5]TypeDescriptor.MethodEntry = undefined;

var reader_descriptor: TypeDescriptor = .{
    .fqcn = "Reader",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .host_finalise = &finaliseReader,
};

/// Fill the Writer + Reader descriptors' static method_tables (idempotent).
/// Called at bootstrap (`initBuiltinFn` is a runtime `@intFromPtr`, not comptime).
pub fn initTextIoTypes() void {
    if (writer_methods_inited) return;
    writer_methods[0] = .{ .protocol_name = "", .method_name = "write", .method_val = Value.initBuiltinFn(&writeMethod) };
    writer_methods[1] = .{ .protocol_name = "", .method_name = "append", .method_val = Value.initBuiltinFn(&appendMethod) };
    writer_methods[2] = .{ .protocol_name = "", .method_name = "flush", .method_val = Value.initBuiltinFn(&flushMethod) };
    writer_methods[3] = .{ .protocol_name = "", .method_name = "close", .method_val = Value.initBuiltinFn(&closeMethod) };
    writer_descriptor.method_table = &writer_methods;
    reader_methods[0] = .{ .protocol_name = "", .method_name = "read", .method_val = Value.initBuiltinFn(&readCharMethod) };
    reader_methods[1] = .{ .protocol_name = "", .method_name = "peek", .method_val = Value.initBuiltinFn(&peekCharMethod) };
    reader_methods[2] = .{ .protocol_name = "", .method_name = "unread", .method_val = Value.initBuiltinFn(&unreadCharMethod) };
    reader_methods[3] = .{ .protocol_name = "", .method_name = "readLine", .method_val = Value.initBuiltinFn(&readLineMethod) };
    reader_methods[4] = .{ .protocol_name = "", .method_name = "close", .method_val = Value.initBuiltinFn(&readerCloseMethod) };
    reader_descriptor.method_table = &reader_methods;
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

/// `(rt/__in-reader s)` — a text_io Reader (pushback) over String `s`. Backs
/// `with-in-str` (the `*in*` reader); distinct from host_stream's `__string-reader`
/// (a file BufferedReader, no pushback — used by clojure.java.io).
fn inReaderFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__in-reader", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__in-reader", .actual = @tagName(args[0].tag()) });
    return mintReader(rt, string_mod.asString(args[0]));
}

/// `(rt/__stdin-reader)` — a text_io Reader over PROCESS stdin (demand-filled,
/// blocking; clj `System.in` parity). The `*in*` ROOT (core.clj) — so
/// `(read-line)` works on piped/redirected/interactive stdin, not just under
/// `with-in-str` (the non-TTY read-line-nil bug class).
fn stdinReaderFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__stdin-reader", args, 0, loc);
    const st = try rt.gc.infra.create(ReaderState);
    st.* = .{ .data = .empty, .pos = 0, .pushback = null, .stdin = true };
    return host_instance.alloc(rt, &reader_descriptor, .{ @intFromPtr(st), 0, 0, 0 });
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
    .{ .name = "__in-reader", .f = &inReaderFn },
    .{ .name = "__stdin-reader", .f = &stdinReaderFn },
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
