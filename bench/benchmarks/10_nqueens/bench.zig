const std = @import("std");

const N = 8;

var queens: [N]i32 = undefined;
var solutions: i32 = 0;

fn safe(row: usize, col: i32) bool {
    for (0..row) |r| {
        const qc = queens[r];
        const dr: i32 = @intCast(@as(i32, @intCast(r)) - @as(i32, @intCast(row)));
        if (qc == col or qc - col == dr or col - qc == dr) return false;
    }
    return true;
}

fn solve(row: usize) void {
    if (row == N) {
        solutions += 1;
        return;
    }
    for (0..N) |c| {
        const col: i32 = @intCast(c);
        if (safe(row, col)) {
            queens[row] = col;
            solve(row + 1);
        }
    }
}

pub fn main() !void {
    solve(0);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{solutions});
}
