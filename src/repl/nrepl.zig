// nREPL server — TCP-based nREPL protocol implementation.
//
// CIDER/Calva/Conjure compatible minimum ops:
// clone, close, describe, eval, load-file,
// completions, info, lookup, eldoc, ls-sessions, ns-list

const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");
const BencodeValue = bencode.BencodeValue;
const clj = @import("../root.zig");
const Env = clj.env.Env;
const Namespace = clj.namespace.Namespace;
const Value = clj.value.Value;
const Var = clj.var_mod.Var;
const bootstrap = clj.bootstrap;
const io_mod = clj.builtin_io;
const registry = clj.builtin_registry;
const err_mod = clj.err;
const lifecycle = @import("../common/lifecycle.zig");
const gc_mod = @import("../common/gc.zig");

// ====================================================================
// Types
// ====================================================================

/// Session — tracks per-client state.
const Session = struct {
    id: []const u8,
    ns_name: []const u8,
};

/// Server state shared across all client threads.
pub const ServerState = struct {
    env: *Env,
    sessions: std.StringHashMapUnmanaged(Session),
    mutex: std.Thread.Mutex,
    running: bool,
    gpa: Allocator,
    gc: ?*gc_mod.MarkSweepGc,
    port_file_written: bool,
    /// Last error info saved from eval (for stacktrace op).
    last_error_info: ?err_mod.Info = null,
    /// Saved call stack frames from last eval error.
    last_error_stack: [64]err_mod.StackFrame = @splat(err_mod.StackFrame{}),
    last_error_stack_depth: u8 = 0,
    /// Persistent copy of error message (msg_buf is threadlocal and gets overwritten).
    last_error_msg_buf: [512]u8 = undefined,
};

// ====================================================================
// Server entry point
// ====================================================================

/// Start the nREPL server on the given port (0 = OS auto-assign).
/// Bootstraps its own Env from scratch with GC for Value collection.
pub fn startServer(gpa_allocator: Allocator, port: u16) !void {
    // Two allocators: GPA for infrastructure, GC for Values.
    // GC collects transient Values after each eval (F113).
    var gc = gc_mod.MarkSweepGc.init(gpa_allocator);
    defer gc.deinit();
    const gc_alloc = gc.allocator();

    var env = Env.init(gpa_allocator);
    defer env.deinit();
    env.gc = @ptrCast(&gc);

    registry.registerBuiltins(&env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        return;
    };
    bootstrap.loadCore(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load core.clj\n", .{});
        return;
    };
    bootstrap.loadTest(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.test\n", .{});
        return;
    };
    bootstrap.loadSet(gc_alloc, &env) catch {
        std.debug.print("Error: failed to load clojure.set\n", .{});
        return;
    };

    // Grow threshold after bootstrap (many live Values in Vars)
    gc.threshold = @max(gc.bytes_allocated * 2, gc.threshold);

    // Define REPL vars (*1, *2, *3, *e)
    _ = bootstrap.evalString(gc_alloc, &env, "(def *1 nil) (def *2 nil) (def *3 nil) (def *e nil)") catch {};

    try runServerLoop(gpa_allocator, &env, &gc, port);
}

/// Start nREPL server on an already-bootstrapped Env.
/// Used by built binaries (cljw build) with --nrepl flag.
pub fn startServerWithEnv(gpa_allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc, port: u16) !void {
    // Ensure REPL vars exist (*e may not be defined in user code)
    _ = bootstrap.evalString(gc.allocator(), env, "(def *e nil)") catch {};

    try runServerLoop(gpa_allocator, env, gc, port);
}

/// TCP listen/accept loop shared by startServer and startServerWithEnv.
fn runServerLoop(gpa_allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc, port: u16) !void {
    var state = ServerState{
        .env = env,
        .sessions = .empty,
        .mutex = .{},
        .running = true,
        .gpa = gpa_allocator,
        .gc = gc,
        .port_file_written = false,
    };
    defer {
        if (state.port_file_written) {
            std.fs.cwd().deleteFile(".nrepl-port") catch {};
        }
        // Free sessions
        var iter = state.sessions.iterator();
        while (iter.next()) |entry| {
            gpa_allocator.free(entry.value_ptr.id);
            gpa_allocator.free(entry.value_ptr.ns_name);
        }
        state.sessions.deinit(gpa_allocator);
    }

    // TCP listen
    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const actual_port = server.listen_address.getPort();

    // Write .nrepl-port file
    {
        var port_buf: [10]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{actual_port}) catch unreachable;
        std.fs.cwd().writeFile(.{ .sub_path = ".nrepl-port", .data = port_str }) catch {};
        state.port_file_written = true;
    }

    std.debug.print("nREPL server started on port {d} on host 127.0.0.1 - nrepl://127.0.0.1:{d}\n", .{ actual_port, actual_port });

    // Accept loop (poll-based with shutdown check)
    while (state.running and !lifecycle.isShutdownRequested()) {
        const conn = lifecycle.acceptWithShutdownCheck(&server) orelse break;

        const thread = std.Thread.spawn(.{}, handleClient, .{ &state, conn }) catch |e| {
            std.debug.print("thread spawn error: {s}\n", .{@errorName(e)});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }

    std.debug.print("nREPL server shutting down\n", .{});
}

/// Client connection handler (thread entry).
fn handleClient(state: *ServerState, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    messageLoop(state, conn.stream);
}

/// Bencode message loop — read, decode, dispatch.
fn messageLoop(state: *ServerState, stream: std.net.Stream) void {
    var recv_buf: [65536]u8 = undefined;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(state.gpa);

    while (true) {
        const n = stream.read(&recv_buf) catch break;
        if (n == 0) break;

        pending.appendSlice(state.gpa, recv_buf[0..n]) catch break;

        while (pending.items.len > 0) {
            var arena = std.heap.ArenaAllocator.init(state.gpa);
            defer arena.deinit();

            const result = bencode.decode(arena.allocator(), pending.items) catch |e| {
                switch (e) {
                    error.UnexpectedEof => break,
                    else => return,
                }
            };

            const msg = switch (result.value) {
                .dict => |d| d,
                else => {
                    shiftPending(&pending, result.consumed);
                    continue;
                },
            };

            dispatchOp(state, msg, stream, arena.allocator());
            shiftPending(&pending, result.consumed);
        }
    }
}

/// Remove consumed bytes from pending buffer.
fn shiftPending(pending: *std.ArrayList(u8), n: usize) void {
    if (n >= pending.items.len) {
        pending.clearRetainingCapacity();
    } else {
        std.mem.copyForwards(u8, pending.items[0..], pending.items[n..]);
        pending.items.len -= n;
    }
}

// ====================================================================
// Op dispatch
// ====================================================================

/// Unified op handler signature.
const OpHandler = *const fn (*ServerState, []const BencodeValue.DictEntry, std.net.Stream, Allocator) void;

/// Dispatch table entry: op name -> handler function.
const OpEntry = struct {
    name: []const u8,
    handler: OpHandler,
};

/// Comptime dispatch table — all supported nREPL ops.
const op_table = [_]OpEntry{
    .{ .name = "clone", .handler = opClone },
    .{ .name = "close", .handler = opClose },
    .{ .name = "describe", .handler = opDescribe },
    .{ .name = "eval", .handler = opEval },
    .{ .name = "load-file", .handler = opLoadFile },
    .{ .name = "ls-sessions", .handler = opLsSessions },
    .{ .name = "completions", .handler = opCompletions },
    .{ .name = "complete", .handler = opCompletions },
    .{ .name = "info", .handler = opInfo },
    .{ .name = "lookup", .handler = opInfo },
    .{ .name = "eldoc", .handler = opEldoc },
    .{ .name = "ns-list", .handler = opNsList },
    .{ .name = "stdin", .handler = opStdin },
    .{ .name = "interrupt", .handler = opInterrupt },
    .{ .name = "stacktrace", .handler = opStacktrace },
    .{ .name = "analyze-last-stacktrace", .handler = opStacktrace },
};

/// Route incoming message to the appropriate op handler.
fn dispatchOp(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const op = bencode.dictGetString(msg, "op") orelse {
        sendError(stream, msg, "missing-op", "No op specified", allocator);
        return;
    };

    inline for (op_table) |entry| {
        if (std.mem.eql(u8, op, entry.name)) {
            entry.handler(state, msg, stream, allocator);
            return;
        }
    }

    // Unknown op — return done so editors don't hang
    sendDone(stream, msg, allocator);
}

// ====================================================================
// Op implementations
// ====================================================================

/// clone: create a new session.
fn opClone(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const session_id = generateUUID(allocator) catch return;

    state.mutex.lock();
    const ns_name = state.gpa.dupe(u8, "user") catch {
        state.mutex.unlock();
        return;
    };
    const id_persistent = state.gpa.dupe(u8, session_id) catch {
        state.mutex.unlock();
        return;
    };
    state.sessions.put(state.gpa, id_persistent, .{
        .id = id_persistent,
        .ns_name = ns_name,
    }) catch {
        state.mutex.unlock();
        return;
    };
    state.mutex.unlock();

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "new-session", .value = .{ .string = session_id } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// close: destroy a session.
fn opClose(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    if (bencode.dictGetString(msg, "session")) |sid| {
        state.mutex.lock();
        if (state.sessions.fetchRemove(sid)) |entry| {
            state.gpa.free(entry.value.id);
            state.gpa.free(entry.value.ns_name);
        }
        state.mutex.unlock();
    }
    sendDone(stream, msg, allocator);
}

/// describe: server information and supported ops.
fn opDescribe(
    _: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    // Generate ops dict from dispatch table (single source of truth)
    const ops_entries = comptime blk: {
        var entries: [op_table.len]BencodeValue.DictEntry = undefined;
        for (op_table, 0..) |entry, i| {
            entries[i] = .{ .key = entry.name, .value = .{ .dict = &.{} } };
        }
        break :blk entries;
    };

    const version_entries = [_]BencodeValue.DictEntry{
        .{ .key = "major", .value = .{ .integer = 0 } },
        .{ .key = "minor", .value = .{ .integer = 1 } },
        .{ .key = "incremental", .value = .{ .integer = 0 } },
    };

    const clj_version = [_]BencodeValue.DictEntry{
        .{ .key = "major", .value = .{ .integer = 1 } },
        .{ .key = "minor", .value = .{ .integer = 11 } },
        .{ .key = "incremental", .value = .{ .integer = 0 } },
        .{ .key = "qualifier", .value = .{ .string = "" } },
    };

    const aux_entries = [_]BencodeValue.DictEntry{
        .{ .key = "current-ns", .value = .{ .string = "user" } },
    };

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "ops", .value = .{ .dict = &ops_entries } },
        .{ .key = "versions", .value = .{ .dict = &.{
            .{ .key = "clojure-wasm", .value = .{ .dict = &version_entries } },
            .{ .key = "clojure", .value = .{ .dict = &clj_version } },
            .{ .key = "nrepl", .value = .{ .dict = &version_entries } },
        } } },
        .{ .key = "aux", .value = .{ .dict = &aux_entries } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// eval: evaluate Clojure code.
fn opEval(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const code = bencode.dictGetString(msg, "code") orelse {
        sendError(stream, msg, "eval-error", "No code provided", allocator);
        return;
    };

    // Input size limit for nREPL (1MB)
    if (code.len > 1_048_576) {
        sendError(stream, msg, "eval-error", "Input exceeds maximum size (1MB)", allocator);
        return;
    }

    // Resolve session namespace
    const session_id = bencode.dictGetString(msg, "session");
    const ns_name = if (bencode.dictGetString(msg, "ns")) |n|
        n
    else if (session_id) |sid| blk: {
        state.mutex.lock();
        defer state.mutex.unlock();
        break :blk if (state.sessions.get(sid)) |s| s.ns_name else "user";
    } else "user";

    // Serialize evaluation
    state.mutex.lock();
    defer state.mutex.unlock();

    // Switch namespace
    if (state.env.findNamespace(ns_name)) |ns| {
        state.env.current_ns = ns;
    }

    // Set up output capture
    var capture_buf: std.ArrayList(u8) = .empty;
    defer capture_buf.deinit(state.gpa);
    io_mod.setOutputCapture(state.gpa, &capture_buf);
    defer io_mod.setOutputCapture(null, null);

    // Use GC allocator for Value allocation so transient values are collected.
    const eval_alloc = if (state.gc) |gc| gc.allocator() else state.gpa;

    // Dupe code with eval allocator so it outlives the message decode arena.
    // evalString's Reader and Analyzer may reference the source string.
    const code_persistent = eval_alloc.dupe(u8, code) catch {
        sendError(stream, msg, "eval-error", "Out of memory", allocator);
        return;
    };

    // Evaluate via bootstrap (TreeWalk) using GC allocator for Value allocation.
    const result = bootstrap.evalString(eval_alloc, state.env, code_persistent);

    // Flush captured output
    if (capture_buf.items.len > 0) {
        const out_entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            sessionEntry(msg),
            .{ .key = "out", .value = .{ .string = capture_buf.items } },
        };
        sendBencode(stream, &out_entries, allocator);
    }

    if (result) |val| {
        // Update *1, *2, *3 (shift history)
        updateReplVar(state, "*3", "*2");
        updateReplVar(state, "*2", "*1");
        setReplVar(state, "*1", val);

        // Format value as string
        var val_buf: [65536]u8 = undefined;
        var val_stream = std.io.fixedBufferStream(&val_buf);
        writeValue(val_stream.writer(), val);
        const val_str = val_stream.getWritten();

        const current_ns_name = if (state.env.current_ns) |ns| ns.name else "user";

        const val_entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            sessionEntry(msg),
            .{ .key = "value", .value = .{ .string = val_str } },
            .{ .key = "ns", .value = .{ .string = current_ns_name } },
        };
        sendBencode(stream, &val_entries, allocator);
        sendDone(stream, msg, allocator);
    } else |_| {
        // Error — bind *e and save error state for stacktrace op
        const err_import = @import("../common/error.zig");
        const err_info = err_import.getLastError();
        const err_msg = if (err_info) |info| info.message else "evaluation failed";

        setReplVar(state, "*e", Value.initString(allocator, err_msg));

        // Save error info into ServerState for stacktrace op
        err_import.saveCallStack();
        const saved_stack = err_import.getSavedCallStack();
        state.last_error_stack_depth = @intCast(saved_stack.len);
        if (saved_stack.len > 0) {
            @memcpy(state.last_error_stack[0..saved_stack.len], saved_stack);
        }
        if (err_info) |info| {
            // Copy message to persistent buffer (threadlocal msg_buf gets overwritten)
            const msg_len = @min(info.message.len, state.last_error_msg_buf.len);
            @memcpy(state.last_error_msg_buf[0..msg_len], info.message[0..msg_len]);
            state.last_error_info = .{
                .kind = info.kind,
                .phase = info.phase,
                .message = state.last_error_msg_buf[0..msg_len],
                .location = info.location,
            };
        } else {
            state.last_error_info = null;
        }

        sendEvalError(stream, msg, err_msg, allocator);
        err_import.clearCallStack();
    }

    // Update session namespace
    if (session_id) |sid| {
        if (state.sessions.getPtr(sid)) |session| {
            if (state.env.current_ns) |ns| {
                state.gpa.free(session.ns_name);
                session.ns_name = state.gpa.dupe(u8, ns.name) catch session.ns_name;
            }
        }
    }

    // GC safe point — collect transient Values after eval (F113)
    if (state.gc) |gc| {
        gc.collectIfNeeded(.{ .env = state.env });
    }
}

/// Send eval error response.
fn sendEvalError(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    err_msg: []const u8,
    allocator: Allocator,
) void {
    const err_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "err", .value = .{ .string = err_msg } },
    };
    sendBencode(stream, &err_entries, allocator);

    const ex_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "ex", .value = .{ .string = err_msg } },
    };
    sendBencode(stream, &ex_entries, allocator);

    const status_items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = "eval-error" },
    };
    const done_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "status", .value = .{ .list = &status_items } },
    };
    sendBencode(stream, &done_entries, allocator);
}

/// load-file: evaluate file content as code.
fn opLoadFile(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const file_content = bencode.dictGetString(msg, "file") orelse {
        sendError(stream, msg, "eval-error", "No file content provided", allocator);
        return;
    };

    // Build a synthetic eval message with code = file content
    var eval_msg_buf: [8]BencodeValue.DictEntry = undefined;
    var eval_msg_len: usize = 0;

    for (msg) |entry| {
        if (eval_msg_len >= eval_msg_buf.len) break;
        if (std.mem.eql(u8, entry.key, "op")) {
            eval_msg_buf[eval_msg_len] = .{ .key = "op", .value = .{ .string = "eval" } };
        } else if (std.mem.eql(u8, entry.key, "file")) {
            eval_msg_buf[eval_msg_len] = .{ .key = "code", .value = .{ .string = file_content } };
        } else {
            eval_msg_buf[eval_msg_len] = entry;
        }
        eval_msg_len += 1;
    }

    opEval(state, eval_msg_buf[0..eval_msg_len], stream, allocator);
}

/// ls-sessions: list active sessions.
fn opLsSessions(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var session_list: std.ArrayList(BencodeValue) = .empty;
    var iter = state.sessions.iterator();
    while (iter.next()) |entry| {
        session_list.append(allocator, .{ .string = entry.value_ptr.id }) catch {};
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "sessions", .value = .{ .list = session_list.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// completions: symbol prefix completion.
fn opCompletions(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const prefix = bencode.dictGetString(msg, "prefix") orelse
        bencode.dictGetString(msg, "symbol") orelse "";

    state.mutex.lock();
    defer state.mutex.unlock();

    var completions: std.ArrayList(BencodeValue) = .empty;

    // Current namespace vars + refers
    if (state.env.current_ns) |ns| {
        collectCompletions(allocator, &completions, &ns.mappings, prefix, ns.name);
        collectCompletions(allocator, &completions, &ns.refers, prefix, null);
    }

    // clojure.core vars
    if (state.env.findNamespace("clojure.core")) |core_ns| {
        collectCompletions(allocator, &completions, &core_ns.mappings, prefix, "clojure.core");
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "completions", .value = .{ .list = completions.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// Collect completion candidates from a VarMap.
fn collectCompletions(
    allocator: Allocator,
    completions: *std.ArrayList(BencodeValue),
    var_map: *const clj.namespace.VarMap,
    prefix: []const u8,
    ns_name: ?[]const u8,
) void {
    var iter = var_map.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            const v: *const Var = entry.value_ptr.*;
            if (v.isPrivate()) continue;

            var comp_entries_buf: [3]BencodeValue.DictEntry = undefined;
            var comp_len: usize = 0;
            comp_entries_buf[comp_len] = .{ .key = "candidate", .value = .{ .string = name } };
            comp_len += 1;
            if (ns_name) |ns| {
                comp_entries_buf[comp_len] = .{ .key = "ns", .value = .{ .string = ns } };
                comp_len += 1;
            }
            comp_entries_buf[comp_len] = .{ .key = "type", .value = .{ .string = "var" } };
            comp_len += 1;

            const comp_dict = allocator.dupe(BencodeValue.DictEntry, comp_entries_buf[0..comp_len]) catch continue;
            completions.append(allocator, .{ .dict = comp_dict }) catch {};
        }
    }
}

/// info / lookup: symbol documentation.
fn opInfo(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const sym_name = bencode.dictGetString(msg, "sym") orelse
        bencode.dictGetString(msg, "symbol") orelse {
        sendDone(stream, msg, allocator);
        return;
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const v = resolveSymbol(state.env, sym_name, bencode.dictGetString(msg, "ns"));
    if (v == null) {
        const status_items = [_]BencodeValue{
            .{ .string = "done" },
            .{ .string = "no-info" },
        };
        const entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            .{ .key = "status", .value = .{ .list = &status_items } },
        };
        sendBencode(stream, &entries, allocator);
        return;
    }

    const var_ptr = v.?;
    var info_entries: std.ArrayList(BencodeValue.DictEntry) = .empty;
    info_entries.append(allocator, idEntry(msg)) catch {};
    info_entries.append(allocator, .{ .key = "name", .value = .{ .string = var_ptr.sym.name } }) catch {};
    if (var_ptr.ns_name.len > 0) {
        info_entries.append(allocator, .{ .key = "ns", .value = .{ .string = var_ptr.ns_name } }) catch {};
    }
    if (var_ptr.doc) |doc| {
        info_entries.append(allocator, .{ .key = "doc", .value = .{ .string = doc } }) catch {};
    }
    if (var_ptr.arglists) |arglists| {
        info_entries.append(allocator, .{ .key = "arglists-str", .value = .{ .string = arglists } }) catch {};
    }
    if (var_ptr.file) |file| {
        info_entries.append(allocator, .{ .key = "file", .value = .{ .string = file } }) catch {};
    }
    if (var_ptr.line > 0) {
        info_entries.append(allocator, .{ .key = "line", .value = .{ .integer = @intCast(var_ptr.line) } }) catch {};
    }
    if (var_ptr.added) |added| {
        info_entries.append(allocator, .{ .key = "added", .value = .{ .string = added } }) catch {};
    }
    info_entries.append(allocator, statusDone()) catch {};

    sendBencode(stream, info_entries.items, allocator);
}

/// eldoc: function argument list for editor display.
fn opEldoc(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const sym_name = bencode.dictGetString(msg, "sym") orelse
        bencode.dictGetString(msg, "symbol") orelse
        bencode.dictGetString(msg, "ns") orelse {
        sendDone(stream, msg, allocator);
        return;
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const v = resolveSymbol(state.env, sym_name, bencode.dictGetString(msg, "ns"));
    if (v == null) {
        sendDone(stream, msg, allocator);
        return;
    }

    const var_ptr = v.?;
    var eldoc_entries: std.ArrayList(BencodeValue.DictEntry) = .empty;
    eldoc_entries.append(allocator, idEntry(msg)) catch {};
    eldoc_entries.append(allocator, .{ .key = "name", .value = .{ .string = var_ptr.sym.name } }) catch {};
    if (var_ptr.ns_name.len > 0) {
        eldoc_entries.append(allocator, .{ .key = "ns", .value = .{ .string = var_ptr.ns_name } }) catch {};
    }
    if (var_ptr.arglists) |arglists| {
        const eldoc_list = [_]BencodeValue{.{ .string = arglists }};
        eldoc_entries.append(allocator, .{ .key = "eldoc", .value = .{ .list = &eldoc_list } }) catch {};
    }
    if (var_ptr.doc) |doc| {
        eldoc_entries.append(allocator, .{ .key = "docstring", .value = .{ .string = doc } }) catch {};
    }
    eldoc_entries.append(allocator, .{ .key = "type", .value = .{ .string = "function" } }) catch {};
    eldoc_entries.append(allocator, statusDone()) catch {};

    sendBencode(stream, eldoc_entries.items, allocator);
}

/// ns-list: list all namespaces.
fn opNsList(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var ns_list: std.ArrayList(BencodeValue) = .empty;
    var iter = state.env.namespaces.iterator();
    while (iter.next()) |entry| {
        ns_list.append(allocator, .{ .string = entry.key_ptr.* }) catch {};
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "ns-list", .value = .{ .list = ns_list.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// stdin: input stub (not supported, returns done).
fn opStdin(
    _: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    sendDone(stream, msg, allocator);
}

/// interrupt: cancel evaluation stub (not supported, returns done).
fn opInterrupt(
    _: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    const status_items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = "session-idle" },
    };
    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "status", .value = .{ .list = &status_items } },
    };
    sendBencode(stream, &entries, allocator);
}

/// stacktrace / analyze-last-stacktrace: return error + call stack from last eval error.
/// CIDER sends this after receiving an eval-error status.
fn opStacktrace(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: Allocator,
) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    const err_info = state.last_error_info orelse {
        // No saved error
        const status_items = [_]BencodeValue{
            .{ .string = "done" },
            .{ .string = "no-error" },
        };
        const entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            sessionEntry(msg),
            .{ .key = "status", .value = .{ .list = &status_items } },
        };
        sendBencode(stream, &entries, allocator);
        return;
    };

    // Build stacktrace frame list
    const stack = state.last_error_stack[0..state.last_error_stack_depth];
    var frame_list: std.ArrayList(BencodeValue) = .empty;

    for (stack) |frame| {
        const fn_name = frame.fn_name orelse "unknown";
        const ns_str = frame.ns orelse "";
        const file_str = frame.file orelse "REPL";
        const var_name = if (frame.ns) |ns|
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, fn_name }) catch fn_name
        else
            fn_name;

        const clj_flag = [_]BencodeValue{.{ .string = "clj" }};
        const frame_entries = allocator.dupe(BencodeValue.DictEntry, &.{
            .{ .key = "name", .value = .{ .string = var_name } },
            .{ .key = "file", .value = .{ .string = file_str } },
            .{ .key = "line", .value = .{ .integer = @intCast(frame.line) } },
            .{ .key = "type", .value = .{ .string = "clj" } },
            .{ .key = "flags", .value = .{ .list = allocator.dupe(BencodeValue, &clj_flag) catch &.{} } },
            .{ .key = "ns", .value = .{ .string = ns_str } },
            .{ .key = "fn", .value = .{ .string = fn_name } },
            .{ .key = "var", .value = .{ .string = var_name } },
        }) catch continue;
        frame_list.append(allocator, .{ .dict = frame_entries }) catch {};
    }

    // If no frames, add a synthetic frame from error location
    if (frame_list.items.len == 0) {
        const file_str = if (err_info.location.file) |f| f else "REPL";
        const clj_flag = [_]BencodeValue{.{ .string = "clj" }};
        const frame_entries = allocator.dupe(BencodeValue.DictEntry, &.{
            .{ .key = "name", .value = .{ .string = "eval" } },
            .{ .key = "file", .value = .{ .string = file_str } },
            .{ .key = "line", .value = .{ .integer = @intCast(err_info.location.line) } },
            .{ .key = "type", .value = .{ .string = "clj" } },
            .{ .key = "flags", .value = .{ .list = allocator.dupe(BencodeValue, &clj_flag) catch &.{} } },
            .{ .key = "ns", .value = .{ .string = "" } },
            .{ .key = "fn", .value = .{ .string = "eval" } },
            .{ .key = "var", .value = .{ .string = "eval" } },
        }) catch &.{};
        frame_list.append(allocator, .{ .dict = frame_entries }) catch {};
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "class", .value = .{ .string = kindToClassName(err_info.kind) } },
        .{ .key = "message", .value = .{ .string = err_info.message } },
        .{ .key = "stacktrace", .value = .{ .list = frame_list.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// Map error.Kind to a human-readable exception class name.
fn kindToClassName(kind: err_mod.Kind) []const u8 {
    return switch (kind) {
        .syntax_error => "SyntaxError",
        .number_error => "NumberFormatError",
        .string_error => "StringError",
        .name_error => "NameError",
        .arity_error => "ArityError",
        .value_error => "ValueError",
        .type_error => "TypeError",
        .arithmetic_error => "ArithmeticError",
        .index_error => "IndexOutOfBoundsError",
        .io_error => "IOException",
        .internal_error => "InternalError",
        .out_of_memory => "OutOfMemoryError",
    };
}

// ====================================================================
// Helpers
// ====================================================================

/// Set a REPL var (*1, *2, *3, *e) to a value.
fn setReplVar(state: *ServerState, name: []const u8, val: Value) void {
    if (state.env.current_ns) |ns| {
        if (ns.resolve(name)) |v| {
            v.bindRoot(val);
        }
    }
}

/// Copy one REPL var's value to another (*3 = *2, *2 = *1).
fn updateReplVar(state: *ServerState, target: []const u8, source: []const u8) void {
    if (state.env.current_ns) |ns| {
        const src_val = if (ns.resolve(source)) |v| v.deref() else Value.nil_val;
        if (ns.resolve(target)) |tv| {
            tv.bindRoot(src_val);
        }
    }
}

/// Resolve a symbol in the environment.
fn resolveSymbol(env: *Env, sym_name: []const u8, ns_hint: ?[]const u8) ?*Var {
    // Qualified name (ns/name)
    if (std.mem.indexOfScalar(u8, sym_name, '/')) |slash| {
        const ns_part = sym_name[0..slash];
        const name_part = sym_name[slash + 1 ..];
        if (env.findNamespace(ns_part)) |ns| {
            return ns.resolve(name_part);
        }
    }

    // Namespace hint
    if (ns_hint) |ns_name| {
        if (env.findNamespace(ns_name)) |ns| {
            if (ns.resolve(sym_name)) |v| return v;
        }
    }

    // Current namespace
    if (env.current_ns) |ns| {
        if (ns.resolve(sym_name)) |v| return v;
    }

    // clojure.core
    if (env.findNamespace("clojure.core")) |core_ns| {
        return core_ns.resolve(sym_name);
    }

    return null;
}

/// UUID v4 generation.
fn generateUUID(allocator: Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // v4: version (bits 48-51) = 0100, variant (bits 64-65) = 10
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],
        bytes[6],  bytes[7],
        bytes[8],  bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

/// Build "id" entry from request message.
fn idEntry(msg: []const BencodeValue.DictEntry) BencodeValue.DictEntry {
    return .{
        .key = "id",
        .value = .{ .string = bencode.dictGetString(msg, "id") orelse "" },
    };
}

/// Build "session" entry from request message.
fn sessionEntry(msg: []const BencodeValue.DictEntry) BencodeValue.DictEntry {
    return .{
        .key = "session",
        .value = .{ .string = bencode.dictGetString(msg, "session") orelse "" },
    };
}

/// Build status "done" entry.
fn statusDone() BencodeValue.DictEntry {
    const done_items = [_]BencodeValue{.{ .string = "done" }};
    return .{ .key = "status", .value = .{ .list = &done_items } };
}

/// Encode and send a bencode dict over a TCP stream.
fn sendBencode(
    stream: std.net.Stream,
    entries: []const BencodeValue.DictEntry,
    allocator: Allocator,
) void {
    var buf: std.ArrayList(u8) = .empty;
    bencode.encode(allocator, &buf, .{ .dict = entries }) catch return;
    stream.writeAll(buf.items) catch {};
}

/// Send a simple "done" response.
fn sendDone(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    allocator: Allocator,
) void {
    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// Send an error response.
fn sendError(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    status: []const u8,
    err_msg: []const u8,
    allocator: Allocator,
) void {
    const status_items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = status },
    };
    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "err", .value = .{ .string = err_msg } },
        .{ .key = "status", .value = .{ .list = &status_items } },
    };
    sendBencode(stream, &entries, allocator);
}

/// Format a Value as a Clojure-readable string.
/// Equivalent to pr-str semantics.
fn writeValue(w: anytype, val: Value) void {
    switch (val.tag()) {
        .nil => w.print("nil", .{}) catch {},
        .boolean => w.print("{}", .{val.asBoolean()}) catch {},
        .integer => w.print("{d}", .{val.asInteger()}) catch {},
        .float => w.print("{d}", .{val.asFloat()}) catch {},
        .string => w.print("\"{s}\"", .{val.asString()}) catch {},
        .keyword => {
            const k = val.asKeyword();
            if (k.ns) |ns| {
                w.print(":{s}/{s}", .{ ns, k.name }) catch {};
            } else {
                w.print(":{s}", .{k.name}) catch {};
            }
        },
        .symbol => {
            const s = val.asSymbol();
            if (s.ns) |ns| {
                w.print("{s}/{s}", .{ ns, s.name }) catch {};
            } else {
                w.print("{s}", .{s.name}) catch {};
            }
        },
        .list => {
            const lst = val.asList();
            w.print("(", .{}) catch {};
            for (lst.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print(")", .{}) catch {};
        },
        .vector => {
            const vec = val.asVector();
            w.print("[", .{}) catch {};
            for (vec.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("]", .{}) catch {};
        },
        .map => {
            const m = val.asMap();
            w.print("{{", .{}) catch {};
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, m.entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, m.entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .hash_map => {
            const hm = val.asHashMap();
            w.print("{{", .{}) catch {};
            // Use arena allocator for temporary entry collection
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = hm.toEntries(arena.allocator()) catch &[_]Value{};
            var i: usize = 0;
            while (i < entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .set => {
            const s = val.asSet();
            w.print("#{{", .{}) catch {};
            for (s.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("}}", .{}) catch {};
        },
        .fn_val => w.print("#<fn>", .{}) catch {},
        .builtin_fn => w.print("#<builtin>", .{}) catch {},
        .atom => {
            const a = val.asAtom();
            w.print("(atom ", .{}) catch {};
            writeValue(w, a.value);
            w.print(")", .{}) catch {};
        },
        .volatile_ref => {
            const v = val.asVolatile();
            w.print("#<volatile ", .{}) catch {};
            writeValue(w, v.value);
            w.print(">", .{}) catch {};
        },
        .regex => {
            const p = val.asRegex();
            w.print("#\"{s}\"", .{p.source}) catch {};
        },
        .char => {
            const c = val.asChar();
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(buf[0..len]) catch {};
        },
        .protocol => w.print("#<protocol {s}>", .{val.asProtocol().name}) catch {},
        .protocol_fn => {
            const pf = val.asProtocolFn();
            w.print("#<protocol-fn {s}/{s}>", .{ pf.protocol.name, pf.method_name }) catch {};
        },
        .multi_fn => w.print("#<multifn {s}>", .{val.asMultiFn().name}) catch {},
        .lazy_seq => {
            const ls = val.asLazySeq();
            if (ls.realized) |r| {
                writeValue(w, r);
            } else {
                w.print("#<lazy-seq>", .{}) catch {};
            }
        },
        .cons => {
            const c = val.asCons();
            w.print("(", .{}) catch {};
            writeValue(w, c.first);
            w.print(" . ", .{}) catch {};
            writeValue(w, c.rest);
            w.print(")", .{}) catch {};
        },
        .var_ref => {
            const v = val.asVarRef();
            w.print("#'{s}/{s}", .{ v.ns_name, v.sym.name }) catch {};
        },
        .delay => {
            const d = val.asDelay();
            if (d.realized) {
                w.print("#delay[", .{}) catch {};
                if (d.cached) |v| writeValue(w, v) else w.print("nil", .{}) catch {};
                w.print("]", .{}) catch {};
            } else {
                w.print("#delay[pending]", .{}) catch {};
            }
        },
        .reduced => writeValue(w, val.asReduced().value),
        .transient_vector => w.print("#<TransientVector>", .{}) catch {},
        .transient_map => w.print("#<TransientMap>", .{}) catch {},
        .transient_set => w.print("#<TransientSet>", .{}) catch {},
        .chunked_cons => {
            const cc = val.asChunkedCons();
            w.print("(", .{}) catch {};
            var i: usize = 0;
            while (i < cc.chunk.count()) : (i += 1) {
                if (i > 0) w.print(" ", .{}) catch {};
                const elem = cc.chunk.nth(i) orelse Value.nil_val;
                writeValue(w, elem);
            }
            if (cc.more.tag() != .nil) w.print(" ...", .{}) catch {};
            w.print(")", .{}) catch {};
        },
        .chunk_buffer => w.print("#<ChunkBuffer>", .{}) catch {},
        .array_chunk => w.print("#<ArrayChunk>", .{}) catch {},
        .wasm_module => w.print("#<WasmModule>", .{}) catch {},
        .wasm_fn => w.print("#<WasmFn {s}>", .{val.asWasmFn().name}) catch {},
        .matcher => w.print("#<Matcher>", .{}) catch {},
        .array => {
            const arr = val.asArray();
            w.print("#<{s}[{d}]>", .{ @tagName(arr.element_type), arr.items.len }) catch {};
        },
        .big_int => w.print("#<BigInt>", .{}) catch {},
        .ratio => w.print("#<Ratio>", .{}) catch {},
    }
}

// ====================================================================
// Tests
// ====================================================================

test "nrepl - generateUUID format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uuid = try generateUUID(allocator);

    // UUID v4 format: 8-4-4-4-12 hex chars = 36 total
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);

    // Version nibble (position 14) should be '4'
    try std.testing.expectEqual(@as(u8, '4'), uuid[14]);

    // Variant nibble (position 19) should be 8, 9, a, or b
    const variant = uuid[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "nrepl - generateUUID uniqueness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uuid1 = try generateUUID(allocator);
    const uuid2 = try generateUUID(allocator);
    try std.testing.expect(!std.mem.eql(u8, uuid1, uuid2));
}

test "nrepl - idEntry extracts id from message" {
    const msg = [_]BencodeValue.DictEntry{
        .{ .key = "id", .value = .{ .string = "42" } },
        .{ .key = "op", .value = .{ .string = "eval" } },
    };
    const entry = idEntry(&msg);
    try std.testing.expectEqualSlices(u8, "id", entry.key);
    try std.testing.expectEqualSlices(u8, "42", entry.value.string);
}

test "nrepl - idEntry returns empty when no id" {
    const msg = [_]BencodeValue.DictEntry{
        .{ .key = "op", .value = .{ .string = "eval" } },
    };
    const entry = idEntry(&msg);
    try std.testing.expectEqualSlices(u8, "", entry.value.string);
}

test "nrepl - sessionEntry extracts session" {
    const msg = [_]BencodeValue.DictEntry{
        .{ .key = "session", .value = .{ .string = "abc-123" } },
    };
    const entry = sessionEntry(&msg);
    try std.testing.expectEqualSlices(u8, "session", entry.key);
    try std.testing.expectEqualSlices(u8, "abc-123", entry.value.string);
}

test "nrepl - statusDone produces done list" {
    const entry = statusDone();
    try std.testing.expectEqualSlices(u8, "status", entry.key);
    const list = entry.value.list;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualSlices(u8, "done", list[0].string);
}

test "nrepl - writeValue integer" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeValue(stream.writer(), Value.initInteger(42));
    try std.testing.expectEqualSlices(u8, "42", stream.getWritten());
}

test "nrepl - writeValue string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeValue(stream.writer(), Value.initString(arena.allocator(), "hello"));
    try std.testing.expectEqualSlices(u8, "\"hello\"", stream.getWritten());
}

test "nrepl - writeValue nil" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeValue(stream.writer(), Value.nil_val);
    try std.testing.expectEqualSlices(u8, "nil", stream.getWritten());
}

test "nrepl - writeValue boolean" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeValue(stream.writer(), Value.true_val);
    try std.testing.expectEqualSlices(u8, "true", stream.getWritten());
}

test "nrepl - writeValue keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeValue(stream.writer(), Value.initKeyword(arena.allocator(), .{ .name = "foo", .ns = null }));
    try std.testing.expectEqualSlices(u8, ":foo", stream.getWritten());
}

test "nrepl - dispatch table covers all expected ops" {
    // Verify key ops are in the dispatch table
    const expected_ops = [_][]const u8{
        "clone",     "close",     "describe",    "eval",
        "load-file", "ls-sessions", "completions", "complete",
        "info",      "lookup",    "eldoc",       "ns-list",
        "stdin",     "interrupt", "stacktrace",  "analyze-last-stacktrace",
    };
    for (expected_ops) |expected| {
        var found = false;
        for (op_table) |entry| {
            if (std.mem.eql(u8, entry.name, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "nrepl - describe ops generated from dispatch table" {
    // Verify describe response has same op count as dispatch table
    comptime {
        var count: usize = 0;
        for (op_table) |_| count += 1;
        if (count != 16) @compileError("expected 16 ops in dispatch table");
    }
}

test "nrepl - kindToClassName maps all kinds" {
    // Verify all error kinds have a class name
    try std.testing.expectEqualSlices(u8, "SyntaxError", kindToClassName(.syntax_error));
    try std.testing.expectEqualSlices(u8, "NumberFormatError", kindToClassName(.number_error));
    try std.testing.expectEqualSlices(u8, "StringError", kindToClassName(.string_error));
    try std.testing.expectEqualSlices(u8, "NameError", kindToClassName(.name_error));
    try std.testing.expectEqualSlices(u8, "ArityError", kindToClassName(.arity_error));
    try std.testing.expectEqualSlices(u8, "ValueError", kindToClassName(.value_error));
    try std.testing.expectEqualSlices(u8, "TypeError", kindToClassName(.type_error));
    try std.testing.expectEqualSlices(u8, "ArithmeticError", kindToClassName(.arithmetic_error));
    try std.testing.expectEqualSlices(u8, "IndexOutOfBoundsError", kindToClassName(.index_error));
    try std.testing.expectEqualSlices(u8, "IOException", kindToClassName(.io_error));
    try std.testing.expectEqualSlices(u8, "InternalError", kindToClassName(.internal_error));
    try std.testing.expectEqualSlices(u8, "OutOfMemoryError", kindToClassName(.out_of_memory));
}

test "nrepl - stacktrace op returns no-error when no previous error" {
    // Test stacktrace with no saved error state
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create minimal ServerState (no env needed for stacktrace)
    var state = ServerState{
        .env = undefined,
        .sessions = .empty,
        .mutex = .{},
        .running = true,
        .gpa = allocator,
        .gc = null,
        .port_file_written = false,
    };

    // Call opStacktrace with a mock stream via TCP
    const address = std.net.Address.parseIp("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ClientThread = struct {
        fn run(p: u16, s: *ServerState) !void {
            const alloc = std.testing.allocator;
            const addr = std.net.Address.parseIp("127.0.0.1", p) catch unreachable;
            var stream = try std.net.tcpConnectToAddress(addr);
            defer stream.close();

            var a = std.heap.ArenaAllocator.init(alloc);
            defer a.deinit();

            const m = [_]BencodeValue.DictEntry{
                .{ .key = "op", .value = .{ .string = "stacktrace" } },
                .{ .key = "id", .value = .{ .string = "42" } },
                .{ .key = "session", .value = .{ .string = "test-session" } },
            };
            opStacktrace(s, &m, stream, a.allocator());
        }
    };

    const client_thread = try std.Thread.spawn(.{}, ClientThread.run, .{ port, &state });

    const conn = try server.accept();
    defer conn.stream.close();

    var recv_buf: [4096]u8 = undefined;
    const n = try conn.stream.read(&recv_buf);
    try std.testing.expect(n > 0);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const result = try bencode.decode(decode_arena.allocator(), recv_buf[0..n]);
    const dict = result.value.dict;

    // Verify no-error status
    const status_val = bencode.dictGet(dict, "status").?;
    const status_list = status_val.list;
    try std.testing.expect(status_list.len == 2);
    try std.testing.expectEqualSlices(u8, "done", status_list[0].string);
    try std.testing.expectEqualSlices(u8, "no-error", status_list[1].string);

    client_thread.join();
}

test "nrepl - stacktrace op returns frames when error saved" {
    const allocator = std.testing.allocator;

    var state = ServerState{
        .env = undefined,
        .sessions = .empty,
        .mutex = .{},
        .running = true,
        .gpa = allocator,
        .gc = null,
        .port_file_written = false,
    };

    // Simulate saved error state
    const err_msg = "Divide by zero";
    @memcpy(state.last_error_msg_buf[0..err_msg.len], err_msg);
    state.last_error_info = .{
        .kind = .arithmetic_error,
        .phase = .eval,
        .message = state.last_error_msg_buf[0..err_msg.len],
        .location = .{ .file = "REPL", .line = 1 },
    };
    state.last_error_stack[0] = .{
        .fn_name = "my-fn",
        .ns = "user",
        .file = "REPL",
        .line = 1,
    };
    state.last_error_stack_depth = 1;

    // Use TCP for mock stream
    const address = std.net.Address.parseIp("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ClientThread = struct {
        fn run(p: u16, s: *ServerState) !void {
            const alloc = std.testing.allocator;
            const addr = std.net.Address.parseIp("127.0.0.1", p) catch unreachable;
            var stream = try std.net.tcpConnectToAddress(addr);
            defer stream.close();

            var a = std.heap.ArenaAllocator.init(alloc);
            defer a.deinit();

            const m = [_]BencodeValue.DictEntry{
                .{ .key = "op", .value = .{ .string = "stacktrace" } },
                .{ .key = "id", .value = .{ .string = "7" } },
                .{ .key = "session", .value = .{ .string = "sess-1" } },
            };
            opStacktrace(s, &m, stream, a.allocator());
        }
    };

    const client_thread = try std.Thread.spawn(.{}, ClientThread.run, .{ port, &state });

    const conn = try server.accept();
    defer conn.stream.close();

    var recv_buf: [8192]u8 = undefined;
    const n = try conn.stream.read(&recv_buf);
    try std.testing.expect(n > 0);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const result = try bencode.decode(decode_arena.allocator(), recv_buf[0..n]);
    const dict = result.value.dict;

    // Verify class and message
    try std.testing.expectEqualSlices(u8, "ArithmeticError", bencode.dictGetString(dict, "class").?);
    try std.testing.expectEqualSlices(u8, "Divide by zero", bencode.dictGetString(dict, "message").?);

    // Verify stacktrace is a list with at least one frame
    const st_val = bencode.dictGet(dict, "stacktrace").?;
    const st_list = st_val.list;
    try std.testing.expect(st_list.len >= 1);

    // Verify first frame has expected fields
    const frame_dict = st_list[0].dict;
    try std.testing.expectEqualSlices(u8, "user/my-fn", bencode.dictGetString(frame_dict, "name").?);
    try std.testing.expectEqualSlices(u8, "REPL", bencode.dictGetString(frame_dict, "file").?);
    try std.testing.expectEqualSlices(u8, "clj", bencode.dictGetString(frame_dict, "type").?);
    try std.testing.expectEqualSlices(u8, "my-fn", bencode.dictGetString(frame_dict, "fn").?);
    try std.testing.expectEqualSlices(u8, "user", bencode.dictGetString(frame_dict, "ns").?);
    const line_val = bencode.dictGetInt(frame_dict, "line");
    try std.testing.expect(line_val != null);
    try std.testing.expectEqual(@as(i64, 1), line_val.?);

    client_thread.join();
}

test "nrepl - TCP integration: describe op" {
    // Start server on random port
    const allocator = std.testing.allocator;

    const address = std.net.Address.parseIp("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Client thread: connect and send describe request
    const ClientThread = struct {
        fn run(p: u16) !void {
            const alloc = std.testing.allocator;
            var decode_arena = std.heap.ArenaAllocator.init(alloc);
            defer decode_arena.deinit();

            const addr = std.net.Address.parseIp("127.0.0.1", p) catch unreachable;
            var stream = try std.net.tcpConnectToAddress(addr);
            defer stream.close();

            // Send describe request
            var send_buf: std.ArrayList(u8) = .empty;
            defer send_buf.deinit(alloc);
            const msg_entries = [_]BencodeValue.DictEntry{
                .{ .key = "op", .value = .{ .string = "describe" } },
                .{ .key = "id", .value = .{ .string = "1" } },
            };
            try bencode.encode(alloc, &send_buf, .{ .dict = &msg_entries });
            try stream.writeAll(send_buf.items);

            // Read response
            var recv_buf: [4096]u8 = undefined;
            const n = try stream.read(&recv_buf);
            try std.testing.expect(n > 0);

            // Decode and verify (use arena to avoid leak)
            const result = try bencode.decode(decode_arena.allocator(), recv_buf[0..n]);
            const dict = result.value.dict;
            try std.testing.expectEqualSlices(u8, "1", bencode.dictGetString(dict, "id").?);
            // Should have ops key
            try std.testing.expect(bencode.dictGet(dict, "ops") != null);
        }
    };

    const client_thread = try std.Thread.spawn(.{}, ClientThread.run, .{port});

    // Server side: accept one connection and process one message
    const conn = try server.accept();
    defer conn.stream.close();

    // Read request
    var recv_buf: [4096]u8 = undefined;
    const n = try conn.stream.read(&recv_buf);
    if (n > 0) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = bencode.decode(arena.allocator(), recv_buf[0..n]) catch unreachable;
        const msg = result.value.dict;
        opDescribe(undefined, msg, conn.stream, arena.allocator());
    }

    client_thread.join();
}
