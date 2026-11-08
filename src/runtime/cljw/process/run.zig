// SPDX-License-Identifier: EPL-2.0
//! cljw.process — run a native host program and capture its result
//! (ADR-0199). The substrate under `clojure.java.shell/sh`; the native
//! sibling of `wasm/run`, with the same exit-as-data contract (ADR-0124).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.process/run
//!
//! Surface: `(cljw.process/run argv)` / `(cljw.process/run argv opts)`
//!   argv = a non-empty vector of strings, program first (resolved on PATH)
//!   opts = `{:in "<stdin>" :dir "<cwd>" :env {"NAME" "value" …}}`
//!   → `{:exit <int> :out "<stdout>" :err "<stderr>"}`
//! A non-zero exit is data, not an exception. `:env` REPLACES the child's
//! environment, as `clojure.java.shell/sh` does. A child killed by signal N
//! reports exit 128+N (POSIX). Only a malformed argument, a program the host
//! cannot start, or a call under a restriction a child would escape
//! (`restriction.zig`: the filesystem jail, an eval budget) raises.
//!
//! The program is spawned by argv vector, never through a shell, so argument
//! text cannot inject shell syntax. `:in` is written from a concurrent task
//! while stdout/stderr drain, so a child that answers before it finishes
//! reading cannot deadlock the pipe pair.
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const keyword_mod = @import("../../keyword.zig");
const restriction = @import("../../restriction.zig");
const safepoint = @import("../../concurrency/safepoint.zig");

const Io = std.Io;

// ── Value objects ────────────────────────────────────────────────────────────

/// One program invocation, as plain host data. Its strings are views into GC
/// strings the caller's `args` keeps rooted; its slices live in a scratch arena.
const Request = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    stdin: ?[]const u8,
};

/// A finished process. `out`/`err` are owned by the allocator `execute` got.
const Outcome = struct {
    term: std.process.Child.Term,
    out: []u8,
    err: []u8,
};

// ── Collect: Clojure arguments -> Request ────────────────────────────────────

/// Accumulator for the `:env` map walk. A key may be a string or a keyword
/// (its name is used); the value must be a string. A non-conforming entry sets
/// `bad`. The map copies both strings into the scratch arena.
const EnvCollect = struct {
    map: *std.process.Environ.Map,
    bad: bool = false,
};
fn collectEnvEntry(c: *EnvCollect, k: Value, v: Value) anyerror!void {
    if (!v.isString()) {
        c.bad = true;
        return;
    }
    const name = if (k.isString())
        string_mod.asString(k)
    else if (k.tag() == .keyword)
        keyword_mod.asKeyword(k).name
    else {
        c.bad = true;
        return;
    };
    // `put` asserts a valid name (non-empty, no '=' or NUL); check it here so a
    // bad key is a catchable error, not a ReleaseSafe panic.
    if (!std.process.Environ.Map.validateKeyForPut(name)) {
        c.bad = true;
        return;
    }
    try c.map.put(name, string_mod.asString(v));
}

fn argInvalid(loc: SourceLocation, detail: []const u8) anyerror {
    return error_catalog.raise(.process_arg_invalid, loc, .{ .detail = detail });
}

/// Read a `Request` out of `(run argv)` / `(run argv opts)`, raising
/// `process_arg_invalid` on a malformed argument. Allocates only in `scratch`.
fn collect(rt: *Runtime, args: []const Value, scratch: std.mem.Allocator, loc: SourceLocation) !Request {
    const argv_v = args[0];
    if (argv_v.tag() != .vector or vector_mod.count(argv_v) == 0)
        return argInvalid(loc, "the command must be a non-empty vector of strings");
    const n = vector_mod.count(argv_v);
    const argv = try scratch.alloc([]const u8, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = vector_mod.nth(argv_v, i);
        if (!e.isString()) return argInvalid(loc, "every command element must be a string");
        argv[i] = string_mod.asString(e);
    }

    var req: Request = .{ .argv = argv, .cwd = .inherit, .environ_map = null, .stdin = null };
    if (args.len < 2 or args[1].isNil()) return req;

    const m = args[1];
    if (m.tag() != .array_map and m.tag() != .hash_map)
        return argInvalid(loc, "the options argument must be a map");

    const in_v = map_mod.get(m, try keyword_mod.intern(rt, null, "in")) catch Value.nil_val;
    if (!in_v.isNil()) {
        if (!in_v.isString()) return argInvalid(loc, "the :in option must be a string");
        req.stdin = string_mod.asString(in_v);
    }

    const dir_v = map_mod.get(m, try keyword_mod.intern(rt, null, "dir")) catch Value.nil_val;
    if (!dir_v.isNil()) {
        if (!dir_v.isString()) return argInvalid(loc, "the :dir option must be a string");
        req.cwd = .{ .path = string_mod.asString(dir_v) };
    }

    const env_v = map_mod.get(m, try keyword_mod.intern(rt, null, "env")) catch Value.nil_val;
    if (!env_v.isNil()) {
        if (env_v.tag() != .array_map and env_v.tag() != .hash_map)
            return argInvalid(loc, "the :env option must be a map of name to string value");
        const em = try scratch.create(std.process.Environ.Map);
        em.* = std.process.Environ.Map.init(scratch);
        var ec = EnvCollect{ .map = em };
        try map_mod.forEachEntry(env_v, &ec, collectEnvEntry);
        if (ec.bad) return argInvalid(loc, "every :env key must be a valid variable name (string/keyword) and every value a string");
        req.environ_map = em;
    }
    return req;
}

// ── Promote: pure derivations ────────────────────────────────────────────────

/// A process status as the integer `sh` reports: the exit code, or 128+N for
/// a child killed (or stopped) by signal N.
fn exitCode(term: std.process.Child.Term) i64 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
        .unknown => |code| code,
    };
}

/// The `{:exit :out :err}` map for a finished process. The map and its strings
/// are fresh objects held only in Zig locals until returned, so they are built
/// where no collection can run.
fn resultValue(rt: *Runtime, done: Outcome) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var result = map_mod.empty();
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "exit"), Value.initInteger(exitCode(done.term)));
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "out"), try string_mod.alloc(rt, done.out));
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "err"), try string_mod.alloc(rt, done.err));
    return result;
}

// ── Facade ───────────────────────────────────────────────────────────────────

pub fn runFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("cljw.process/run", args, 1, 2, loc);

    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const req = try collect(rt, args, arena_state.allocator(), loc);

    if (restriction.active(rt)) |r|
        return error_catalog.raise(.process_spawn_restricted, loc, .{ .program = req.argv[0], .reason = r.describe() });

    var failure: []const u8 = "";
    const done = safepoint.blocking(execute, .{ rt.io, rt.gpa, req, &failure }) catch |e| switch (e) {
        error.ProcessFailed => return error_catalog.raise(.process_spawn_failed, loc, .{ .program = req.argv[0], .detail = failure }),
        error.OutOfMemory => return e,
    };
    defer rt.gpa.free(done.out);
    defer rt.gpa.free(done.err);
    return resultValue(rt, done);
}

// ── Boundary: the only code that touches the OS ──────────────────────────────

/// Write `bytes` to the child's stdin, then close it so the child sees EOF.
/// A child that exits without reading makes the write fail (EPIPE); that is
/// the child's choice, not an error of the call.
fn feedStdin(io: Io, file: Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
    file.close(io);
}

/// Spawn, feed stdin, drain stdout/stderr, wait. Pure OS work: no cljw value
/// is created or raised. On failure `failure` names the OS error and
/// `error.ProcessFailed` is returned; the caller owns `out`/`err` on success.
fn execute(io: Io, gpa: std.mem.Allocator, req: Request, failure: *[]const u8) error{ ProcessFailed, OutOfMemory }!Outcome {
    // Declared before the child so its deferred await runs AFTER the deferred
    // kill: on an error path the kill closes the pipe and unblocks the writer.
    var feeder: ?Io.Future(void) = null;
    defer if (feeder) |*f| f.await(io);

    var child = std.process.spawn(io, .{
        .argv = req.argv,
        .cwd = req.cwd,
        .environ_map = req.environ_map,
        .stdin = if (req.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        failure.* = @errorName(e);
        return error.ProcessFailed;
    };
    defer child.kill(io);

    if (req.stdin) |bytes| {
        const file = child.stdin.?;
        child.stdin = null;
        feeder = io.concurrent(feedStdin, .{ io, file, bytes }) catch blk: {
            // No concurrency available: write first, then drain. Correct for
            // any child that reads all of stdin before it fills a pipe buffer.
            feedStdin(io, file, bytes);
            break :blk null;
        };
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| {
            failure.* = @errorName(e);
            return error.ProcessFailed;
        },
    }
    multi_reader.checkAnyError() catch |e| {
        failure.* = @errorName(e);
        return error.ProcessFailed;
    };

    if (feeder) |*f| {
        f.await(io);
        feeder = null;
    }
    const term = child.wait(io) catch |e| {
        failure.* = @errorName(e);
        return error.ProcessFailed;
    };

    const out = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_bytes = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .out = out, .err = err_bytes };
}

/// Create the `cljw.process` host namespace. Called by
/// `runtime/cljw/_host_api.zig::installAll` on every non-WASI target.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("cljw.process");
    _ = try env.intern(ns, "run", Value.initBuiltinFn(&runFn), null);
}

// --- tests ---

const testing = std.testing;

test "exitCode maps a normal exit to its code and a signal to 128+N" {
    try testing.expectEqual(@as(i64, 0), exitCode(.{ .exited = 0 }));
    try testing.expectEqual(@as(i64, 3), exitCode(.{ .exited = 3 }));
    try testing.expectEqual(@as(i64, 128 + 9), exitCode(.{ .signal = .KILL }));
}
