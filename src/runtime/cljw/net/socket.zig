// SPDX-License-Identifier: EPL-2.0
//! cljw.net — TCP and UNIX streams, both sides, bound thinly to `std.Io.net`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.net/connect, cljw.net/listen,
//!               cljw.net/connect-unix, cljw.net/listen-unix
//!
//! Surface: `(cljw.net/connect host port)` → a `.host_instance` socket, then
//!          `(.write sock byte-array n)` → bytes written,
//!          `(.read  sock byte-array)`   → bytes read, or -1 at end of stream,
//!          `(.close sock)`              → nil (idempotent).
//!
//!          `(cljw.net/listen host port)` → a `.host_instance` server, then
//!          `(.accept srv)` → a socket of the SAME kind `connect` returns,
//!          `(.port   srv)` → the BOUND port (so `(listen h 0)` is usable),
//!          `(.close  srv)` → nil (idempotent; accepted sockets stay open).
//!
//!          `(cljw.net/connect-unix path)` and `(cljw.net/listen-unix path)`
//!          answer the SAME socket and server kinds over a UNIX domain socket.
//!          A unix server's `.port` is 0 — it genuinely has none — and a
//!          leftover socket file is NOT unlinked for you.
//!
//! This is a cljw-ORIGINAL surface, not a `java.net.Socket` emulation: it
//! exposes what `std.Io.net` does and leaves Java/JS/elisp reconciliation to the
//! caller's own adapter. It is the same `.listen`/`.accept` pair
//! `src/app/nrepl.zig` already drives, lifted to a Clojure-facing surface.
//!
//! Ownership: the `Stream` plus its reader/writer buffers live in one
//! gpa-allocated `SocketBox` whose pointer is `state[0]`; the box holds its own
//! `Io` so the ADR-0106 `host_finalise` hook can close a dropped socket at
//! sweep without a Runtime. `state` carries no `Value`, so no `host_trace`.
//!
//! Every call that can block in the OS (dial, accept, read, write, flush) runs
//! under `safepoint.blocking`, so a `future` waiting on a quiet peer does not
//! stall a collection another thread requests.
//!
//! A byte array is raw `i8` storage (ADR-0204): a read lands in it with one
//! memcpy, a write copies it to a gpa scratch first so the blocking write
//! never reads storage the program can still `aset`.
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const java_array = @import("../../collection/java_array.zig");
const host_instance = @import("../../host_instance.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const safepoint = @import("../../concurrency/safepoint.zig");

/// Reader/writer buffer size, and therefore the most one `.read` can return.
/// A `SocketBox` costs 2 * IO_BUF; a caller draining a multi-megabyte response
/// pays one host call per IO_BUF bytes.
const IO_BUF = 65536;

/// Heap carrier for one connected stream. Address-stable: `reader`/`writer`
/// borrow `rbuf`/`wbuf` in place, so the box must never be copied after `init`.
const SocketBox = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    closed: bool,
    rbuf: [IO_BUF]u8,
    wbuf: [IO_BUF]u8,
};

fn boxOf(recv: Value) *SocketBox {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(recv).state[0])));
}

fn isSocket(v: Value) bool {
    return v.tag() == .host_instance and
        host_instance.asHostInstance(v).descriptor == &descriptor;
}

fn expectSocket(v: Value, loc: SourceLocation) !*SocketBox {
    if (!isSocket(v)) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net socket" });
    const box = boxOf(v);
    if (box.closed) return error_catalog.raise(.net_socket_closed, loc, .{});
    return box;
}

/// `(cljw.net/connect host port)` — resolve `host`, open a TCP stream to it.
fn connectFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net/connect", args, 2, loc);
    try ensureMethodTable(rt.gpa);
    if (!args[0].isString()) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the host must be a string" });
    const host = string_mod.asString(args[0]);
    const port_i = try error_catalog.expectI64(args[1], "port", loc);
    if (port_i < 0 or port_i > 65535) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the port must be an integer in 0..65535" });
    const port: u16 = @intCast(port_i);

    // An IP literal connects directly; a name goes through HostName.connect,
    // which races EVERY resolved address. Resolving to a single address strands
    // the common case where a name yields ::1 first and the peer is v4-only.
    const opts: std.Io.net.IpAddress.ConnectOptions = .{ .mode = .stream };
    const stream = if (std.Io.net.IpAddress.parse(host, port)) |parsed| blk: {
        const addr = parsed;
        break :blk safepoint.blocking(std.Io.net.IpAddress.connect, .{ &addr, rt.io, opts }) catch
            return error_catalog.raise(.net_connect_failed, loc, .{ .host = host, .port = port_i });
    } else |_| blk: {
        const name = std.Io.net.HostName.init(host) catch
            return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the host is not a valid IP address or host name" });
        break :blk safepoint.blocking(std.Io.net.HostName.connect, .{ name, rt.io, port, opts }) catch
            return error_catalog.raise(.net_connect_failed, loc, .{ .host = host, .port = port_i });
    };

    return wrapStream(rt, stream);
}

/// A socket Value over the connected `stream`, in a fresh `SocketBox`. The
/// box's buffers are charged to the collect trigger, since the only cell
/// standing for them is a few words. Closes `stream` if the box cannot be made.
fn wrapStream(rt: *Runtime, stream: std.Io.net.Stream) !Value {
    const box = rt.gpa.create(SocketBox) catch |e| {
        stream.close(rt.io);
        return e;
    };
    box.* = .{
        .io = rt.io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .closed = false,
        .rbuf = undefined,
        .wbuf = undefined,
    };
    box.reader = box.stream.reader(box.io, &box.rbuf);
    box.writer = box.stream.writer(box.io, &box.wbuf);
    rt.gc.noteOwnedAlloc(@sizeOf(SocketBox));

    return host_instance.alloc(rt, &descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// `(.write sock ba n)` — write the first `n` bytes of `ba`. => bytes written.
fn writeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("cljw.net write", args, 2, 3, loc);
    const box = try expectSocket(args[0], loc);
    if (!java_array.isKind(args[1], .byte)) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the buffer must be a byte array" });

    const avail = java_array.alength(args[1]);
    const n: u32 = if (args.len == 3) blk: {
        const want = try error_catalog.expectI64(args[2], "n", loc);
        if (want < 0 or want > avail) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "n must be between 0 and the buffer length" });
        break :blk @intCast(want);
    } else avail;

    // A copy: the array stays mutable while the blocking write runs.
    const scratch = try rt.gpa.dupe(u8, java_array.asArray(args[1]).bytes()[0..n]);
    defer rt.gpa.free(scratch);

    safepoint.blocking(std.Io.Writer.writeAll, .{ &box.writer.interface, scratch }) catch
        return error_catalog.raise(.net_io_failed, loc, .{ .op = "write" });
    safepoint.blocking(std.Io.Writer.flush, .{&box.writer.interface}) catch
        return error_catalog.raise(.net_io_failed, loc, .{ .op = "flush" });

    return Value.initInteger(@intCast(n));
}

/// `(.read sock ba)` — read available bytes into `ba`. => count, or -1 at EOF.
fn readMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net read", args, 2, loc);
    const box = try expectSocket(args[0], loc);
    if (!java_array.isKind(args[1], .byte)) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the buffer must be a byte array" });

    const cap = java_array.alength(args[1]);
    if (cap == 0) return Value.initInteger(0);

    const r = &box.reader.interface;
    if (r.buffered().len == 0) {
        safepoint.blocking(std.Io.Reader.fillMore, .{r}) catch |e| switch (e) {
            error.EndOfStream => return Value.initInteger(-1),
            else => return error_catalog.raise(.net_io_failed, loc, .{ .op = "read" }),
        };
    }
    const bytes = r.buffered();
    if (bytes.len == 0) return Value.initInteger(-1);

    const n: u32 = @intCast(@min(bytes.len, cap));
    @memcpy(java_array.asArray(args[1]).bytes()[0..n], bytes[0..n]);
    r.toss(n);
    return Value.initInteger(@intCast(n));
}

/// `(.close sock)` — close the stream. Idempotent; a closed socket stays closed.
fn closeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net close", args, 1, loc);
    if (!isSocket(args[0])) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net socket" });
    const box = boxOf(args[0]);
    if (!box.closed) {
        box.stream.close(box.io);
        box.closed = true;
    }
    return Value.nil_val;
}

/// ADR-0106 finaliser: close a socket the program dropped, then free the box.
fn finaliseSocket(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    if (state[0] == 0) return;
    const box: *SocketBox = @ptrFromInt(@as(usize, @intCast(state[0])));
    if (!box.closed) {
        box.stream.close(box.io);
        box.closed = true;
    }
    infra.destroy(box);
    state[0] = 0;
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "write", .f = &writeMethod },
    .{ .name = "read", .f = &readMethod },
    .{ .name = "close", .f = &closeMethod },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.net.Socket",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

/// Populate the socket method table. Idempotent, and called from `connectFn`
/// rather than `register` because `installAll` carries no allocator and a
/// socket can only reach a method through `connect`.
fn ensureMethodTable(gpa: std.mem.Allocator) !void {
    if (descriptor.method_table.len != 0) return;
    descriptor.host_finalise = &finaliseSocket;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    descriptor.method_table = entries;
}

// ── the listening side ───────────────────────────────────────────────────────
//
// `.accept` answers a socket built on the SAME `descriptor` `connect` produces,
// so `.read` / `.write` / `.close` need no new arm: this is a new PRODUCER of an
// existing representation, not a second one.

/// Heap carrier for one listening socket. Address-stable for the same reason
/// `SocketBox` is — the finaliser reaches it back through `state[0]`.
const ServerBox = struct {
    io: std.Io,
    server: std.Io.net.Server,
    closed: bool,
};

fn serverBoxOf(recv: Value) *ServerBox {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(recv).state[0])));
}

fn isServer(v: Value) bool {
    return v.tag() == .host_instance and
        host_instance.asHostInstance(v).descriptor == &server_descriptor;
}

fn expectServer(v: Value, loc: SourceLocation) !*ServerBox {
    if (!isServer(v)) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net server" });
    const box = serverBoxOf(v);
    if (box.closed) return error_catalog.raise(.net_socket_closed, loc, .{});
    return box;
}

/// `(cljw.net/listen host port)` — bind and listen. Port 0 asks the OS for an
/// ephemeral port, which `(.port srv)` then reports.
fn listenFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net/listen", args, 2, loc);
    try ensureMethodTable(rt.gpa);
    try ensureServerMethodTable(rt.gpa);
    if (!args[0].isString()) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the host must be a string" });
    const host = string_mod.asString(args[0]);
    const port_i = try error_catalog.expectI64(args[1], "port", loc);
    if (port_i < 0 or port_i > 65535) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the port must be an integer in 0..65535" });
    const port: u16 = @intCast(port_i);

    // A listen address is an interface this host already owns, so unlike
    // `connect` there is nothing to resolve and racing several addresses would
    // mean nothing. An IP literal is the whole contract.
    const parsed = std.Io.net.IpAddress.parse(host, port) catch
        return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the listen host must be an IP address literal" });
    var addr = parsed;
    const server = std.Io.net.IpAddress.listen(&addr, rt.io, .{}) catch
        return error_catalog.raise(.net_listen_failed, loc, .{ .host = host, .port = port_i });

    const box = rt.gpa.create(ServerBox) catch |e| {
        var s = server;
        s.deinit(rt.io);
        return e;
    };
    box.* = .{ .io = rt.io, .server = server, .closed = false };

    return host_instance.alloc(rt, &server_descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// `(.accept srv)` — block until a peer connects. => a cljw.net socket.
fn acceptMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net accept", args, 1, loc);
    const box = try expectServer(args[0], loc);

    const stream = safepoint.blocking(std.Io.net.Server.accept, .{ &box.server, box.io }) catch
        return error_catalog.raise(.net_io_failed, loc, .{ .op = "accept" });

    return wrapStream(rt, stream);
}

/// `(.port srv)` — the BOUND port. `listen` with 0 resolves an ephemeral port
/// into the socket address, and a caller that asked for 0 has no other way to
/// learn where to send a client.
fn portMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net port", args, 1, loc);
    const box = try expectServer(args[0], loc);
    return Value.initInteger(@intCast(box.server.socket.address.getPort()));
}

/// `(.close srv)` — stop listening. Idempotent. Sockets already accepted stay
/// open: closing the door does not evict the guests (JVM ServerSocket parity).
fn closeServerMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net close", args, 1, loc);
    if (!isServer(args[0])) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net server" });
    const box = serverBoxOf(args[0]);
    if (!box.closed) {
        box.server.deinit(box.io);
        box.closed = true;
    }
    return Value.nil_val;
}

/// ADR-0106 finaliser: stop a listener the program dropped, then free the box.
fn finaliseServer(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    if (state[0] == 0) return;
    const box: *ServerBox = @ptrFromInt(@as(usize, @intCast(state[0])));
    if (!box.closed) {
        box.server.deinit(box.io);
        box.closed = true;
    }
    infra.destroy(box);
    state[0] = 0;
}

const SERVER_METHODS = [_]MethodSpec{
    .{ .name = "accept", .f = &acceptMethod },
    .{ .name = "port", .f = &portMethod },
    .{ .name = "close", .f = &closeServerMethod },
};

var server_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.net.Server",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

/// Populate the server method table. Idempotent, and called from `listenFn` for
/// the same reason `ensureMethodTable` is called from `connectFn`: `installAll`
/// carries no allocator, and a server can only be reached through `listen`.
fn ensureServerMethodTable(gpa: std.mem.Allocator) !void {
    if (server_descriptor.method_table.len != 0) return;
    server_descriptor.host_finalise = &finaliseServer;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, SERVER_METHODS.len);
    for (SERVER_METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    server_descriptor.method_table = entries;
}

// ── UNIX domain sockets ──────────────────────────────────────────────────────
//
// `UnixAddress.listen` / `.connect` answer the SAME `Server` / `Stream` types
// the IP pair does, so both carriers, both descriptors, both method tables and
// both finalisers above serve these unchanged. A unix socket is a different
// ADDRESS, not a different representation.

/// The path from a `cljw.net` unix arg, bounds-checked. The 108-byte cap is the
/// OS's, not the filesystem's, so a perfectly ordinary temp path can exceed it.
fn expectUnixPath(v: Value, loc: SourceLocation) ![]const u8 {
    if (!v.isString()) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the socket path must be a string" });
    const path = string_mod.asString(v);
    if (path.len > std.Io.net.UnixAddress.max_len) {
        return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the socket path is longer than the 108 bytes the OS allows" });
    }
    return path;
}

/// `(cljw.net/connect-unix path)` — connect to a UNIX domain socket.
fn connectUnixFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net/connect-unix", args, 1, loc);
    try ensureMethodTable(rt.gpa);
    const path = try expectUnixPath(args[0], loc);

    const ua = std.Io.net.UnixAddress.init(path) catch
        return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the socket path is longer than the 108 bytes the OS allows" });
    const stream = safepoint.blocking(std.Io.net.UnixAddress.connect, .{ &ua, rt.io }) catch
        return error_catalog.raise(.net_unix_connect_failed, loc, .{ .path = path });

    return wrapStream(rt, stream);
}

/// `(cljw.net/listen-unix path)` — bind and listen on a UNIX domain socket.
///
/// A leftover socket file from a dead process makes this fail, and cljw does
/// NOT unlink it: the path may still belong to a live server, and deleting
/// another process's socket is a decision the caller owns, not the runtime.
/// `(.port srv)` answers 0 here — a unix socket genuinely has no port.
fn listenUnixFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net/listen-unix", args, 1, loc);
    try ensureMethodTable(rt.gpa);
    try ensureServerMethodTable(rt.gpa);
    const path = try expectUnixPath(args[0], loc);

    const ua = std.Io.net.UnixAddress.init(path) catch
        return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the socket path is longer than the 108 bytes the OS allows" });
    const server = ua.listen(rt.io, .{}) catch
        return error_catalog.raise(.net_unix_listen_failed, loc, .{ .path = path });

    const box = rt.gpa.create(ServerBox) catch |e| {
        var s = server;
        s.deinit(rt.io);
        return e;
    };
    box.* = .{ .io = rt.io, .server = server, .closed = false };

    return host_instance.alloc(rt, &server_descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// Create the `cljw.net` host namespace.
/// Called by `runtime/cljw/_host_api.zig::installAll`.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("cljw.net");
    _ = try env.intern(ns, "connect", Value.initBuiltinFn(&connectFn), null);
    _ = try env.intern(ns, "listen", Value.initBuiltinFn(&listenFn), null);
    _ = try env.intern(ns, "connect-unix", Value.initBuiltinFn(&connectUnixFn), null);
    _ = try env.intern(ns, "listen-unix", Value.initBuiltinFn(&listenUnixFn), null);
}
