//! 05: `const`と`var`

const std = @import("std");

pub fn main() !void {
    const greeting = "hi";
    const max_iter: u32 = 100;

    var counter: u32 = 0;
    counter = counter + 1;
    counter += 5;

    std.debug.print("[05] greeting : {s}\n", .{greeting});
    std.debug.print("[05] max_iter (count) : {d}\n", .{max_iter});
    std.debug.print("[05] counter (var) : {d}\n", .{counter});

    var arr: [3]i32 = .{ 10, 20, 30 };
    arr[1] = 99;
    std.debug.print("[05] mutated arr : {any}\n", .{arr});

    var tick: u32 = 0;
    while (tick < 3) : (tick += 1) {
        std.debug.print("[05] tick : {d}\n", .{tick});
    }
}
