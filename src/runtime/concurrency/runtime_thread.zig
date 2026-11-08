// SPDX-License-Identifier: EPL-2.0
//! Runtime-thread geometry (ADR-0195): the one place cljw chooses the stack
//! every thread it spawns gets, and the entry hop that runs the program on
//! such a thread instead of the process's initial one.
//!
//! `RUNTIME_STACK_BYTES` sizes the entry thread (here) and every worker
//! (`spawn.zig`). `STACK_BUDGET_BYTES` is the byte budget at which ADR-0157's
//! self-calibrating guard raises a catchable `stack_overflow`; vm.zig and
//! tree_walk.zig read it from here. The margin between the two is asserted at
//! comptime below: budget + the static TLS reserve + slack must fit the stack,
//! because under glibc pthreads the thread's static TLS block is carved out of
//! the very allocation `stack_size` names. The dominant TLS consumer (vm.zig's
//! `VmArena`) asserts its own size against `TLS_RESERVE_BYTES` at its site.
//!
//! `runMain` is the entry hop. Single-threaded targets (wasm32-wasi,
//! ADR-0193) call through directly. A spawn failure degrades to a direct call
//! after one stderr line: a constrained host still runs, on the initial
//! thread's geometry, which the guard then cannot vouch for. The entry thread
//! registers no `ThreadGcContext` and never counts as a worker: to the GC and
//! the exit barrier it IS the main thread (a role, not a thread id).

const std = @import("std");
const builtin = @import("builtin");

/// Stack size of every thread cljw spawns. `std.Thread.SpawnConfig`'s own
/// default made explicit, so the entry thread and the workers agree.
pub const RUNTIME_STACK_BYTES: usize = 16 * 1024 * 1024;

/// Bytes consumed below the guard's anchor at which the evaluators raise
/// `stack_overflow` (ADR-0157 2a).
pub const STACK_BUDGET_BYTES: usize = 6 * 1024 * 1024;

/// Static TLS the runtime stack must also hold (vm.zig asserts `VmArena`
/// fits in it; it is the dominant consumer).
pub const TLS_RESERVE_BYTES: usize = 2 * 1024 * 1024;

/// Native frames the guard does not meter: reader / printer / analyzer
/// recursion between guarded entries, plus one frame of detection lag.
pub const STACK_SLACK_BYTES: usize = 1024 * 1024;

comptime {
    if (STACK_BUDGET_BYTES + TLS_RESERVE_BYTES + STACK_SLACK_BYTES > RUNTIME_STACK_BYTES)
        @compileError("ADR-0195: STACK_BUDGET_BYTES + TLS_RESERVE_BYTES + STACK_SLACK_BYTES exceeds RUNTIME_STACK_BYTES");
}

/// The spawn configuration every cljw thread uses.
pub const spawn_config: std.Thread.SpawnConfig = .{ .stack_size = RUNTIME_STACK_BYTES };

/// Comptime check for a threadlocal footprint: `bytes` must fit the reserve
/// the margin above accounts for.
pub fn assertTlsFits(comptime bytes: usize) void {
    comptime {
        if (bytes > TLS_RESERVE_BYTES)
            @compileError("ADR-0195: a threadlocal footprint exceeds TLS_RESERVE_BYTES; raise the reserve (and re-check the margin)");
    }
}

/// Run `function(args...)` on a runtime thread; return its result. The caller
/// blocks in `join` for the whole program. The callee's error (if any) comes
/// back so `main` reports it exactly as before, minus the callee thread's
/// error-return trace.
pub fn runMain(comptime function: anytype, args: anytype) anyerror!void {
    if (comptime builtin.single_threaded) return @call(.auto, function, args);

    const Args = @TypeOf(args);
    const Runner = struct {
        fn run(slot: *?anyerror, a: Args) void {
            @call(.auto, function, a) catch |e| {
                slot.* = e;
            };
        }
    };

    var failed: ?anyerror = null;
    const t = std.Thread.spawn(spawn_config, Runner.run, .{ &failed, args }) catch |e| {
        std.debug.print("cljw: could not spawn the runtime thread ({t}); running on the initial thread\n", .{e});
        return @call(.auto, function, args);
    };
    t.join();
    if (failed) |e| return e;
}

test "runMain runs the callback on a different OS thread" {
    const Probe = struct {
        var seen: std.Thread.Id = 0;
        fn body(x: u32) anyerror!void {
            seen = std.Thread.getCurrentId();
            if (x != 7) return error.WrongArgument;
        }
    };
    try runMain(Probe.body, .{@as(u32, 7)});
    if (!builtin.single_threaded)
        try std.testing.expect(Probe.seen != std.Thread.getCurrentId());
}

test "runMain propagates the callback's error" {
    const Boom = struct {
        fn body() anyerror!void {
            return error.Boom;
        }
    };
    try std.testing.expectError(error.Boom, runMain(Boom.body, .{}));
}

test "the entry thread is not a GC-registered worker" {
    const root_set = @import("../gc/root_set.zig");
    const before = root_set.registeredCountLockFree();
    const Probe = struct {
        var registered: bool = true;
        fn body() anyerror!void {
            registered = root_set.is_registered_worker;
        }
    };
    try runMain(Probe.body, .{});
    try std.testing.expect(!Probe.registered);
    try std.testing.expectEqual(before, root_set.registeredCountLockFree());
}

test "the spawn config carries the runtime stack size" {
    try std.testing.expectEqual(RUNTIME_STACK_BYTES, spawn_config.stack_size);
}
