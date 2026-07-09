// SPDX-License-Identifier: EPL-2.0
//! Clock primitives — namespace-neutral implementation per F-009.
//!
//! Two surfaces consume this file:
//!   1. `runtime/java/lang/System.zig` — `(System/currentTimeMillis)` /
//!      `(System/nanoTime)`.
//!   2. (future) `lang/primitive/clock.zig` — when a Clojure-level
//!      wrapper like `(cljw/now)` lands. Today no Clojure peer exists
//!      (Clojure idiomatic time access goes through the Java surface).
//!
//! Zig 0.16 moved the clock API under `std.Io.Clock`; the call sites
//! must thread an `io: std.Io` through (Juicy-Main / Runtime.io).
//! The legacy `std.time.nanoTimestamp` was removed.

const std = @import("std");

/// Milliseconds since the Unix epoch. Mirrors JVM
/// `System.currentTimeMillis()`. Wall clock; subject to NTP jumps.
pub fn currentMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Monotonic nanoseconds. Mirrors JVM `System.nanoTime()`. The
/// absolute value is meaningless; only differences are. Unaffected
/// by wall-clock adjustments.
pub fn nanoTime(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

// --- tests ---

const testing = std.testing;

test "currentMillis returns a positive epoch milliseconds value" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const ms = currentMillis(th.io());
    // mid-2026 ≈ 1.77e12 ms past the Unix epoch.
    try testing.expect(ms > 1_700_000_000_000);
}

test "nanoTime advances monotonically across two consecutive calls" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const t1 = nanoTime(th.io());
    const t2 = nanoTime(th.io());
    try testing.expect(t2 >= t1);
}
