// SPDX-License-Identifier: EPL-2.0
//! One portable "read a chunk from process stdin" primitive, shared by the
//! `*in*` readers (text_io, host_stream), via `std.Io.File`.

const std = @import("std");
const builtin = @import("builtin");

/// Read up to `buf.len` bytes from stdin into `buf`. Returns bytes read
/// (0 = EOF).
pub fn readChunk(io: std.Io, buf: []u8) std.Io.File.ReadStreamingError!usize {
    return std.Io.File.stdin().readStreaming(io, &.{buf});
}

/// How long a stdin fill waits for input before running an idle collect.
pub const idle_poll_ms: i32 = 1000;

/// Wait up to `timeout_ms` for stdin to become readable (data, EOF or
/// hang-up). True when a read will not block. Answers true at once where
/// there is no `poll`, so callers never spin.
pub fn waitReadable(timeout_ms: i32) bool {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&fds, timeout_ms) catch return true;
    return n > 0;
}

/// Ready a demand-filled stdin buffer for its next fill: drop its consumed
/// prefix, then wait for input, calling `gc.collectBeforeIdle()` each time
/// `idle_poll_ms` passes with none, so a process blocked on stdin still
/// collects and returns memory.
pub fn beforeFill(infra: std.mem.Allocator, data: *std.ArrayList(u8), pos: *usize, gc: anytype) void {
    dropConsumed(infra, data, pos);
    while (!waitReadable(idle_poll_ms)) gc.collectBeforeIdle();
}

/// Capacity up to which `dropConsumed` never frees a stdin buffer's excess, so
/// a steady stream of small lines does not realloc per fill.
pub const retained_capacity: usize = 64 * 1024;

/// Drop the consumed prefix `data[0..pos]` of a demand-filled stdin buffer
/// and reset `pos` to 0, so a long-running reader holds only its unread tail.
/// Frees the excess allocation once it is over 4x the tail and
/// `retained_capacity`.
/// Call before appending a fill: the append may move `data` anyway, so no
/// caller holds a slice or offset across it.
pub fn dropConsumed(infra: std.mem.Allocator, data: *std.ArrayList(u8), pos: *usize) void {
    const consumed = pos.*;
    if (consumed == 0) return;
    const rest = data.items.len - consumed;
    std.mem.copyForwards(u8, data.items[0..rest], data.items[consumed..]);
    data.shrinkRetainingCapacity(rest);
    pos.* = 0;
    if (data.capacity > retained_capacity and data.capacity > rest * 4)
        data.shrinkAndFree(infra, rest);
}

test "dropConsumed keeps the unread tail and resets pos" {
    const a = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    try data.appendSlice(a, "line one\nline two");
    var pos: usize = 9;
    dropConsumed(a, &data, &pos);
    try std.testing.expectEqualStrings("line two", data.items);
    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "dropConsumed releases a buffer that grew far past its tail" {
    const a = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    try data.appendNTimes(a, 'x', 1024 * 1024);
    var pos: usize = data.items.len - 3;
    dropConsumed(a, &data, &pos);
    try std.testing.expectEqual(@as(usize, 3), data.items.len);
    try std.testing.expect(data.capacity <= retained_capacity);
}

test "dropConsumed is a no-op at pos 0" {
    const a = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    try data.appendSlice(a, "abc");
    var pos: usize = 0;
    dropConsumed(a, &data, &pos);
    try std.testing.expectEqualStrings("abc", data.items);
}
