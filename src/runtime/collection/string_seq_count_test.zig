// SPDX-License-Identifier: EPL-2.0
//! StringSeq count memo ([CLJW-STRING-SEQ]): the first `countOf` on a chain
//! scans; `rest` / `drop` / `withMeta` carry the answer forward so a
//! count-guarded walk stays linear. Split out of `string_seq.zig`, which is
//! already past the file-size ceiling.

const std = @import("std");
const testing = std.testing;
const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const string = @import("string.zig");
const ss = @import("string_seq.zig");

fn cellCount(v: Value) u32 {
    return v.decodePtr(*const ss.StringSeq).cached_count;
}

test "countOf memoises and rest/drop/withMeta inherit the memo" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    const s = try string.alloc(&rt, "aé→𝄞xyz"); // 7 codepoints, mixed widths
    const v = try ss.make(&rt, s, 0);
    try testing.expectEqual(ss.COUNT_UNKNOWN, cellCount(v));
    // No count taken: successors stay unknown, not a wrong guess.
    try testing.expectEqual(ss.COUNT_UNKNOWN, cellCount(try ss.rest(&rt, v)));

    try testing.expectEqual(@as(u32, 7), ss.countOf(v));
    try testing.expectEqual(@as(u32, 7), cellCount(v));

    var cur = v;
    var want: u32 = 7;
    while (!cur.isNil()) : (want -= 1) {
        // Inherited, then confirmed against a fresh scan of the same cursor.
        try testing.expectEqual(want, cellCount(cur));
        const fresh = try ss.make(&rt, s, ss.offsetOf(cur));
        try testing.expectEqual(want, ss.countOf(fresh));
        cur = try ss.rest(&rt, cur);
    }
    try testing.expectEqual(@as(u32, 0), want);

    const d = try ss.drop(&rt, v, 3);
    try testing.expectEqual(@as(u32, 4), cellCount(d));
    try testing.expect((try ss.drop(&rt, v, 99)).isNil());

    const m = try ss.withMeta(&rt, v, Value.initInteger(1));
    try testing.expectEqual(@as(u32, 7), cellCount(m));
}

test "StringSeq stays a 32-byte cell with the memo field" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(ss.StringSeq));
    try testing.expectEqual(@as(usize, 12), @offsetOf(ss.StringSeq, "cached_count"));
}
