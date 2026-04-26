// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Process-wide default `std.Io` accessor.
//!
//! Zig 0.16 removed `std.Thread.Mutex` and friends; the replacement
//! `std.Io.Mutex` requires an `io` argument for lock/unlock. CW carries
//! many module-level mutexes (interned keywords, hooks, namespaces, etc.)
//! that don't have access to an `init.io` value at the call site.
//!
//! This module exposes a single shared `std.Io` that defaults to a
//! single-threaded io suitable for tests and pre-init code paths.
//! Production entry points (main, cache_gen) call `set(init.io)` early
//! to upgrade the shared io to the real cancelable one used by
//! `thread_pool.zig`. After that, every mutex picks up the production io.

const std = @import("std");

var single_threaded: std.Io.Threaded = .init_single_threaded;
var current_io: std.Io = undefined;
var initialized: bool = false;

/// Return the process-wide default io. Lazily initializes to a single-
/// threaded io on first call so tests and ad-hoc callers don't have to
/// remember to call `set()`.
pub fn get() std.Io {
    if (!initialized) {
        current_io = single_threaded.io();
        initialized = true;
    }
    return current_io;
}

/// Override the process-wide default io. Production entry points
/// (main/cache_gen) call this with `init.io` so the thread_pool path
/// gets the real cancelable mutex semantics.
pub fn set(io: std.Io) void {
    current_io = io;
    initialized = true;
}

// =====================================================================
// Convenience helpers — mirror the deleted std.Thread.{Mutex,Condition}
// API surface so call sites that previously passed no io argument keep
// roughly the same shape.
// =====================================================================

/// Lock a mutex using the default io. Uncancelable variant: never
/// returns an error, matching the old std.Thread.Mutex.lock() shape.
pub fn lockMutex(m: *std.Io.Mutex) void {
    m.lockUncancelable(get());
}

pub fn unlockMutex(m: *std.Io.Mutex) void {
    m.unlock(get());
}

/// std.Io.Condition.wait, but uncancelable and uses default io.
pub fn condWait(cond: *std.Io.Condition, mutex: *std.Io.Mutex) void {
    cond.waitUncancelable(get(), mutex);
}

/// Timed wait on a condition. Returns true on timeout, false on signal/broadcast.
/// Mirrors zwasm's `condTimedWait` (D135). The deadline is computed once
/// outside the loop so spurious wake-ups don't extend the wait.
pub fn condTimedWait(cond: *std.Io.Condition, mutex: *std.Io.Mutex, timeout_ns: u64) bool {
    const io = get();
    var epoch = cond.epoch.load(.acquire);
    _ = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    const start = std.Io.Timestamp.now(io, .awake);
    const deadline_ts = start.addDuration(.fromNanoseconds(@intCast(timeout_ns)));
    const deadline_clock_ts: std.Io.Clock.Timestamp = .{ .raw = deadline_ts, .clock = .awake };
    const timeout: std.Io.Timeout = .{ .deadline = deadline_clock_ts };

    while (true) {
        // futexWaitTimeout returns Cancelable!void — error.Timeout is not in
        // that error set, so the timeout case is detected by checking the
        // current Timestamp against the deadline rather than via the error.
        std.Io.futexWaitTimeout(io, u32, &cond.epoch.raw, epoch, timeout) catch {};
        epoch = cond.epoch.load(.acquire);
        const cur = cond.state.load(.monotonic);
        if (cur.signals > 0) {
            const new_state: @TypeOf(cur) = .{
                .waiters = cur.waiters - 1,
                .signals = cur.signals - 1,
            };
            if (cond.state.cmpxchgWeak(cur, new_state, .acquire, .monotonic) == null) {
                return false;
            }
        }
        // Check if deadline passed (timeout case)
        const now_ts = std.Io.Timestamp.now(io, .awake);
        if (now_ts.nanoseconds >= deadline_ts.nanoseconds) return true;
    }
}

pub fn condSignal(cond: *std.Io.Condition) void {
    cond.signal(get());
}

pub fn condBroadcast(cond: *std.Io.Condition) void {
    cond.broadcast(get());
}

/// Sleep for `ns` nanoseconds. Replaces std.Thread.sleep(ns).
pub fn sleep(ns: u64) void {
    std.Io.sleep(get(), .fromNanoseconds(@intCast(ns)), .awake) catch {};
}

// =====================================================================
// Environment access — mirrors zwasm/platform.setEnvironMap. The Process
// init block carries an `environ_map` we can borrow from main/cache_gen
// so other modules can read env vars without calling libc's getenv.
// =====================================================================

var env_map_ref: ?*const std.process.Environ.Map = null;

pub fn setEnvironMap(m: *const std.process.Environ.Map) void {
    env_map_ref = m;
}

/// Look up an environment variable. Returns null when the var is unset
/// or `setEnvironMap` was never called (tests, pre-init).
pub fn getEnv(name: []const u8) ?[]const u8 {
    const m = env_map_ref orelse return null;
    return m.get(name);
}

// =====================================================================
// Time helpers
// =====================================================================

/// Nanoseconds since some monotonic epoch. Replaces std.time.nanoTimestamp().
pub fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(get(), .real);
    return @intCast(ts.nanoseconds);
}

/// Milliseconds since the wall-clock epoch. Replaces std.time.milliTimestamp().
pub fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(get(), .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}
