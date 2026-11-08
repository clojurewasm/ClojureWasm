// SPDX-License-Identifier: EPL-2.0
//! A one-shot "it happened" edge that a waiter can wait on with a DEADLINE.
//!
//! Every blocking primitive cljw has waits for the same thing: a fact that is
//! false, becomes true once, and is never false again — a future is realised, a
//! promise is delivered, a thread is done, a cancel is requested. That is a
//! latch, and `std.Io.Event` is exactly a latch.
//!
//! These were all built on `std.Io.Condition`, which has no timed wait. That
//! shaped two things it should not have: the timed `deref` polled `isRealised`
//! in 1 ms sleeps, and every bound cljw wanted to place on a blocking call had
//! to be approximated by slicing a sleep. `std.Io.Event.waitTimeout` is the
//! timed wait, and `Io.Timeout` carries an absolute `.deadline`, so neither
//! approximation is needed.
//!
//! The mutex stays where a latch has a PAYLOAD (the future's value, the
//! promise's value): the mutex guards the payload, the latch carries the edge.
//! Order matters — publish the payload under the mutex, THEN `signal`. `set`
//! releases prior writes, so a waiter that observes the latch observes the
//! payload (`std.Io.Event.set`'s own documented guarantee).
//!
//! `waitTimeout` returns `error.Timeout` on a SPURIOUS wakeup as well as a real
//! one, so `wait` re-checks against its own absolute deadline rather than
//! trusting the return. That is why the deadline is passed as an instant and
//! not as a duration: a duration would restart on every spurious wakeup.

const std = @import("std");
const io_default = @import("io_default.zig");
const clock = @import("../clock.zig");
const safepoint = @import("safepoint.zig");

/// A monotonic one-shot flag. Zero value is "not yet".
pub const Latch = struct {
    event: std.Io.Event = .unset,

    /// Raise the latch and wake every waiter. Idempotent.
    pub fn signal(self: *Latch) void {
        self.event.set(io_default.get());
    }

    /// Non-blocking read.
    pub fn isSet(self: *const Latch) bool {
        return self.event.isSet();
    }

    /// Block until the latch is raised, or until `deadline_ns` (a
    /// `clock.nanoTime` instant; `null` = wait forever). Returns true iff the
    /// latch was raised.
    ///
    /// No polling: with no deadline this is one uninterrupted futex wait, and
    /// with one it is a single wait that lands on the instant. The loop
    /// iterates only on a spurious wakeup.
    ///
    /// A registered worker counts as parked for the wait (`safepoint.blocking`),
    /// so a collection another thread requests does not wait for the latch.
    /// Without it, a future derefing a promise that the collecting thread will
    /// deliver after its collection is a deadlock. The wait allocates nothing
    /// and raises nothing, which is the bracket's contract.
    pub fn wait(self: *Latch, deadline_ns: ?i64) bool {
        if (self.isSet()) return true;
        return safepoint.blocking(waitUnbracketed, .{ self, deadline_ns });
    }

    fn waitUnbracketed(self: *Latch, deadline_ns: ?i64) bool {
        const io = io_default.get();
        while (true) {
            if (self.isSet()) return true;
            const timeout: std.Io.Timeout = if (deadline_ns) |d| blk: {
                const remaining = d - clock.nanoTime(io);
                if (remaining <= 0) return self.isSet();
                break :blk .{ .duration = .{
                    .raw = .{ .nanoseconds = remaining },
                    .clock = .awake,
                } };
            } else .none;
            self.event.waitTimeout(io, timeout) catch {
                // Timeout OR spurious wakeup — indistinguishable here, so the
                // loop head re-checks both the latch and the deadline. With no
                // deadline armed a spurious wakeup simply re-waits.
                continue;
            };
            return true;
        }
    }
};

const testing = std.testing;

test "an unset latch reads false and a signalled one reads true" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    io_default.set(th.io());

    var l: Latch = .{};
    try testing.expect(!l.isSet());
    l.signal();
    try testing.expect(l.isSet());
    // Idempotent.
    l.signal();
    try testing.expect(l.isSet());
}

test "wait on an already-signalled latch returns immediately" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    io_default.set(th.io());

    var l: Latch = .{};
    l.signal();
    const t0 = clock.nanoTime(th.io());
    try testing.expect(l.wait(t0 + 10 * std.time.ns_per_s));
    // Order-of-magnitude bound, not a ratio: the failure it catches is "waited
    // out the whole 10 s deadline". A tighter bound would measure the CI
    // runner's load rather than this code (see eval_budget.zig's note).
    try testing.expect(clock.nanoTime(th.io()) - t0 < 2 * std.time.ns_per_s);
}

test "wait honours the deadline and reports not-signalled" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    io_default.set(th.io());

    var l: Latch = .{};
    const t0 = clock.nanoTime(th.io());
    try testing.expect(!l.wait(t0 + 80 * std.time.ns_per_ms));
    const elapsed = clock.nanoTime(th.io()) - t0;
    try testing.expect(elapsed >= 70 * std.time.ns_per_ms);
    // The bound is honoured, not merely eventually noticed.
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
}

test "a deadline already in the past does not block" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    io_default.set(th.io());

    var l: Latch = .{};
    const t0 = clock.nanoTime(th.io());
    try testing.expect(!l.wait(t0 - std.time.ns_per_s));
    // As above: catches "blocked anyway", not a few ms of scheduling noise.
    try testing.expect(clock.nanoTime(th.io()) - t0 < 2 * std.time.ns_per_s);
}

test "a waiter wakes on signal without waiting out its deadline" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    io_default.set(th.io());

    var l: Latch = .{};
    const Ctx = struct {
        fn run(latch: *Latch) void {
            io_default.sleep(60 * std.time.ns_per_ms);
            latch.signal();
        }
    };
    var t = try std.Thread.spawn(.{}, Ctx.run, .{&l});
    defer t.join();

    const t0 = clock.nanoTime(th.io());
    // A 30 s bound that must NOT be waited out: the signal is the wake.
    try testing.expect(l.wait(t0 + 30 * std.time.ns_per_s));
    try testing.expect(clock.nanoTime(th.io()) - t0 < 5 * std.time.ns_per_s);
}
