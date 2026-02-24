// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Process lifecycle management — signal handling and shutdown hooks.
//!
//! Provides graceful shutdown for long-running processes:
//!   - SIGINT/SIGTERM handler sets atomic shutdown flag
//!   - Accept loops poll with timeout and check the flag
//!   - Shutdown hooks (Clojure fns) run before process exit
//!   - SIGPIPE ignored (broken pipe on closed sockets)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const dispatch = @import("dispatch.zig");
const Env = @import("env.zig").Env;
const thread_pool = @import("thread_pool.zig");

// ============================================================
// Shutdown flag
// ============================================================

/// Global shutdown flag. Set by signal handler, checked by accept loops.
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

// ============================================================
// Signal handlers
// ============================================================

/// Install SIGINT/SIGTERM handlers and ignore SIGPIPE.
/// Call once at process startup (main.zig).
pub fn installSignalHandlers() void {
    const handler_action = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &handler_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &handler_action, null);

    // Ignore SIGPIPE — writing to a closed socket should return error, not kill.
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore_action, null);
}

fn handleShutdownSignal(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .release);
    // Write newline to stderr so the shell prompt appears cleanly.
    // write() is async-signal-safe.
    _ = std.posix.write(std.posix.STDERR_FILENO, "\n") catch {};
}

// ============================================================
// Poll-based accept with shutdown check
// ============================================================

/// Wait for a connection on the listener socket, checking shutdown flag
/// every ~1 second. Returns null if shutdown was requested.
pub fn acceptWithShutdownCheck(server: *std.net.Server) ?std.net.Server.Connection {
    const fd = server.stream.handle;
    var fds = [1]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (!isShutdownRequested()) {
        const ready = std.posix.poll(&fds, 1000) catch |e| {
            std.debug.print("poll error: {s}\n", .{@errorName(e)});
            if (isShutdownRequested()) return null;
            continue;
        };
        if (ready == 0) continue; // timeout — check flag and retry

        // Socket is ready for accept
        return server.accept() catch |e| {
            if (isShutdownRequested()) return null;
            std.debug.print("accept error: {s}\n", .{@errorName(e)});
            continue;
        };
    }
    return null;
}

// ============================================================
// Shutdown hooks
// ============================================================

const MAX_HOOKS = 16;

const ShutdownHook = struct {
    key: [64]u8,
    key_len: usize,
    func: Value,
};

var hooks: [MAX_HOOKS]?ShutdownHook = .{null} ** MAX_HOOKS;
var hook_mutex: std.Thread.Mutex = .{};

/// Register a shutdown hook. Returns true on success, false if table is full
/// or key already exists.
pub fn addShutdownHook(key: []const u8, func: Value) bool {
    hook_mutex.lock();
    defer hook_mutex.unlock();

    // Check for duplicate key
    for (&hooks) |*slot| {
        if (slot.*) |h| {
            if (std.mem.eql(u8, h.key[0..h.key_len], key)) {
                // Update existing
                slot.*.?.func = func;
                return true;
            }
        }
    }

    // Find empty slot
    for (&hooks) |*slot| {
        if (slot.* == null) {
            var hook: ShutdownHook = .{
                .key = undefined,
                .key_len = @min(key.len, 64),
                .func = func,
            };
            @memcpy(hook.key[0..hook.key_len], key[0..hook.key_len]);
            slot.* = hook;
            return true;
        }
    }
    return false; // table full
}

/// Remove a shutdown hook by key. Returns true if found and removed.
pub fn removeShutdownHook(key: []const u8) bool {
    hook_mutex.lock();
    defer hook_mutex.unlock();

    for (&hooks) |*slot| {
        if (slot.*) |h| {
            if (std.mem.eql(u8, h.key[0..h.key_len], key)) {
                slot.* = null;
                return true;
            }
        }
    }
    return false;
}

/// Run all registered shutdown hooks. Call before process exit.
/// env must be provided to set up eval context for Clojure fn calls.
pub fn runShutdownHooks(allocator: Allocator, env_ptr: *Env) void {
    hook_mutex.lock();
    // Copy hooks to local array to release mutex before calling Clojure fns
    var local_hooks: [MAX_HOOKS]?ShutdownHook = hooks;
    hook_mutex.unlock();

    // Set eval context for callFnVal (bytecodeCallBridge needs it)
    dispatch.macro_eval_env = env_ptr;
    dispatch.current_env = env_ptr;

    for (&local_hooks) |*slot| {
        if (slot.*) |h| {
            _ = dispatch.callFnVal(allocator, h.func, &[0]Value{}) catch |e| {
                std.debug.print("shutdown hook error ({s}): {s}\n", .{ h.key[0..h.key_len], @errorName(e) });
            };
        }
    }

    // Shutdown the global thread pool (if active)
    thread_pool.shutdownGlobalPool();
}

// ============================================================
// Builtin functions for Clojure API
// ============================================================

const var_mod = @import("var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err_mod = @import("error.zig");

/// (add-shutdown-hook! key f)
/// Register a 0-arg function to call on graceful shutdown.
pub fn addShutdownHookFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to add-shutdown-hook!", .{args.len});

    const key_val = args[0];
    const func_val = args[1];

    const key = switch (key_val.tag()) {
        .string => key_val.asString(),
        .keyword => key_val.asKeyword().name,
        else => return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "add-shutdown-hook!: key must be a string or keyword" }),
    };

    switch (func_val.tag()) {
        .fn_val, .builtin_fn => {},
        else => return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "add-shutdown-hook!: second argument must be a function" }),
    }

    if (addShutdownHook(key, func_val)) {
        return key_val;
    }
    return err_mod.setError(.{ .kind = .value_error, .phase = .eval, .message = "add-shutdown-hook!: too many hooks registered" });
}

/// (remove-shutdown-hook! key)
/// Remove a previously registered shutdown hook.
pub fn removeShutdownHookFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to remove-shutdown-hook!", .{args.len});

    const key_val = args[0];
    const key = switch (key_val.tag()) {
        .string => key_val.asString(),
        .keyword => key_val.asKeyword().name,
        else => return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "remove-shutdown-hook!: key must be a string or keyword" }),
    };

    return if (removeShutdownHook(key)) Value.true_val else Value.false_val;
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "add-shutdown-hook!",
        .func = &addShutdownHookFn,
        .doc = "Register a 0-arg function to call on graceful shutdown. Key identifies the hook for removal.",
        .arglists = "([key f])",
        .added = "cljw",
    },
    .{
        .name = "remove-shutdown-hook!",
        .func = &removeShutdownHookFn,
        .doc = "Remove a previously registered shutdown hook by key.",
        .arglists = "([key])",
        .added = "cljw",
    },
};

// ============================================================
// Tests
// ============================================================

test "lifecycle - shutdown flag initially false" {
    // Reset for test
    shutdown_requested.store(false, .release);
    try std.testing.expect(!isShutdownRequested());
}

test "lifecycle - requestShutdown sets flag" {
    shutdown_requested.store(false, .release);
    requestShutdown();
    try std.testing.expect(isShutdownRequested());
    // Reset
    shutdown_requested.store(false, .release);
}

test "lifecycle - shutdown hooks add/remove" {
    // Clear hooks
    for (&hooks) |*slot| slot.* = null;

    const result = addShutdownHook("test-hook", Value.nil_val);
    try std.testing.expect(result);

    // Duplicate key should update
    const result2 = addShutdownHook("test-hook", Value.true_val);
    try std.testing.expect(result2);

    // Remove
    const removed = removeShutdownHook("test-hook");
    try std.testing.expect(removed);

    // Remove non-existent
    const removed2 = removeShutdownHook("nonexistent");
    try std.testing.expect(!removed2);

    // Clean up
    for (&hooks) |*slot| slot.* = null;
}

test "lifecycle - hook table overflow" {
    // Clear hooks
    for (&hooks) |*slot| slot.* = null;

    // Fill all slots
    for (0..MAX_HOOKS) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "h{d}", .{i}) catch unreachable;
        try std.testing.expect(addShutdownHook(key, Value.nil_val));
    }

    // Should fail (table full)
    try std.testing.expect(!addShutdownHook("overflow", Value.nil_val));

    // Clean up
    for (&hooks) |*slot| slot.* = null;
}
