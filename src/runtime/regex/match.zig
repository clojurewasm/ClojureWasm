// SPDX-License-Identifier: EPL-2.0
//! Pike NFA matcher (Thompson thread-list VM) — namespace-neutral
//! implementation per F-009.
//!
//! Implements ADR-0031 Alt 2 cycle 1 (correctness baseline). The
//! lazy DFA fast path lands in cycle 2 (`dfa.zig`); both backends
//! share the `Program` IR defined in `compile.zig`.
//!
//! Design (per Russ Cox's "Regular Expression Matching: the
//! Virtual Machine Approach"):
//!
//!   - Two thread lists (`current`, `next`); each thread carries a
//!     PC. A per-list bitmap dedups so the same PC is processed at
//!     most once per input position.
//!   - Epsilon-closure (`jmp` / `split` / `save` / `anchor`) is
//!     expanded eagerly by `addThread` before threads enter the
//!     consume list, so the step loop only sees byte-consuming
//!     opcodes and `.match`.
//!   - Greedy semantics fall out of split priority: `emitStar`
//!     orders `split{body, after}`, so the body thread is added
//!     first; the `.match` thread is recorded each iteration and
//!     the final best is the longest greedy match.
//!   - O(n·m) worst case, no catastrophic backtracking.
//!
//! Cycle 2+ extends this with anchor-position handling, capture
//! groups, lazy DFA dispatch, and the surface primitives.

const std = @import("std");
const compile = @import("compile.zig");

/// Maximum capture-group slot count (start + end for each group).
/// JVM Clojure supports more, but the Phase 6.6 cycle-1 baseline
/// caps at 8 groups (16 slots). Wider patterns fall back to a
/// heap-allocated slot array in cycle 3.
pub const MAX_SLOTS_INLINE: usize = 16;

/// Capture-slot snapshot carried by each thread. -1 means
/// "unset". On match, the slot array is the user-visible result
/// of `re-groups`. Cycle 1 produces no captures; the field is
/// preserved for cycle-3 wiring without re-shaping `MatchResult`.
pub const Captures = struct {
    slots: [MAX_SLOTS_INLINE]i32 = [_]i32{-1} ** MAX_SLOTS_INLINE,
    used: usize = 0,
};

/// One live Pike VM thread. Cycle 1 keeps only the PC; cycle 3
/// adds the capture-slot snapshot.
pub const Thread = struct {
    pc: u32,
};

/// Match result returned by `find` / `match`. `null` slot ends
/// mean "no match" (analogous to JVM Pattern.find returning
/// false).
pub const MatchResult = struct {
    start: u32,
    end: u32,
    captures: Captures,
};

pub const MatchError = error{} || std.mem.Allocator.Error;

/// `(re-find pattern input)` baseline: find the first match
/// anywhere in `input`. Returns null when no match exists.
pub fn find(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    var start: u32 = 0;
    while (start <= input.len) : (start += 1) {
        if (try tryMatchAt(alloc, program, input, start)) |result| return result;
    }
    return null;
}

/// `(re-matches pattern input)` baseline: succeeds iff the
/// whole input matches the pattern (anchored at both ends).
pub fn matchFull(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    const result = (try tryMatchAt(alloc, program, input, 0)) orelse return null;
    if (result.end != input.len) return null;
    return result;
}

/// Per-step thread list — set of PCs the VM is about to step
/// from. The `seen` bitmap prevents re-processing the same PC
/// within a single input position (key Pike-VM invariant that
/// bounds runtime at O(n·m)).
const ThreadList = struct {
    pcs: std.ArrayList(u32) = .empty,
    seen: []bool,

    fn init(alloc: std.mem.Allocator, n_insts: usize) MatchError!ThreadList {
        const seen = try alloc.alloc(bool, n_insts);
        @memset(seen, false);
        return .{ .seen = seen };
    }

    fn deinit(self: *ThreadList, alloc: std.mem.Allocator) void {
        self.pcs.deinit(alloc);
        alloc.free(self.seen);
    }

    fn clear(self: *ThreadList) void {
        self.pcs.clearRetainingCapacity();
        @memset(self.seen, false);
    }
};

/// Add a thread at `pc`, expanding epsilon transitions
/// (`jmp` / `split` / `save` / `anchor`) so the list contains
/// only byte-consuming opcodes plus `.match`. Cycle-1 `save` and
/// `anchor` are pass-through stubs; cycle-2 wires real semantics.
fn addThread(
    list: *ThreadList,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    pc: u32,
) MatchError!void {
    if (list.seen[pc]) return;
    list.seen[pc] = true;
    switch (program.insts[pc]) {
        .jmp => |target| try addThread(list, alloc, program, target),
        .split => |s| {
            try addThread(list, alloc, program, s.a);
            try addThread(list, alloc, program, s.b);
        },
        .save => try addThread(list, alloc, program, pc + 1),
        .anchor => try addThread(list, alloc, program, pc + 1),
        else => try list.pcs.append(alloc, pc),
    }
}

/// Try to match the program starting at `start` in `input`.
/// Returns the longest greedy match anchored at `start`, or null
/// if no thread reaches `.match` from `start`.
fn tryMatchAt(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?MatchResult {
    var current = try ThreadList.init(alloc, program.insts.len);
    defer current.deinit(alloc);
    var next = try ThreadList.init(alloc, program.insts.len);
    defer next.deinit(alloc);

    try addThread(&current, alloc, program, 0);

    var best: ?MatchResult = null;
    var pos: u32 = start;

    while (true) {
        // Record any .match in the current set — greedy semantics
        // keep extending so the final best holds the longest match.
        for (current.pcs.items) |pc| {
            if (program.insts[pc] == .match) {
                best = .{ .start = start, .end = pos, .captures = .{} };
                break;
            }
        }

        if (pos >= input.len) break;
        if (current.pcs.items.len == 0) break;

        const c = input[pos];
        for (current.pcs.items) |pc| {
            switch (program.insts[pc]) {
                .char => |cc| if (c == cc) try addThread(&next, alloc, program, pc + 1),
                .class => |cls| if (cls.contains(c)) try addThread(&next, alloc, program, pc + 1),
                .range => |r| if (c >= r.lo and c <= r.hi) try addThread(&next, alloc, program, pc + 1),
                .match => {},
                else => {}, // epsilon ops are pre-expanded by addThread
            }
        }
        std.mem.swap(ThreadList, &current, &next);
        next.clear();
        pos += 1;
    }
    return best;
}

// --- tests ---

const testing = std.testing;

test "find single-char literal in middle of input" {
    var prog = try compile.compile(testing.allocator, "b", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abc")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 2), r.end);
}

test "find returns null on no match" {
    var prog = try compile.compile(testing.allocator, "z", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "abc"));
}

test "matchFull only succeeds on full-string match" {
    var prog = try compile.compile(testing.allocator, "a", .{});
    defer prog.deinit(testing.allocator);
    const r1 = try matchFull(testing.allocator, &prog, "a");
    try testing.expect(r1 != null);
    const r2 = try matchFull(testing.allocator, &prog, "abc");
    try testing.expectEqual(@as(?MatchResult, null), r2);
}

test "find multi-char literal in middle of input" {
    var prog = try compile.compile(testing.allocator, "bc", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "xabcd")).?;
    try testing.expectEqual(@as(u32, 2), r.start);
    try testing.expectEqual(@as(u32, 4), r.end);
}

test "matchFull green on exact multi-char literal" {
    var prog = try compile.compile(testing.allocator, "abc", .{});
    defer prog.deinit(testing.allocator);
    const r = (try matchFull(testing.allocator, &prog, "abc")).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "dot matches any single character" {
    var prog = try compile.compile(testing.allocator, ".", .{});
    defer prog.deinit(testing.allocator);
    const r1 = (try matchFull(testing.allocator, &prog, "x")).?;
    try testing.expectEqual(@as(u32, 1), r1.end);
    const r2 = (try matchFull(testing.allocator, &prog, "Z")).?;
    try testing.expectEqual(@as(u32, 1), r2.end);
}

test "a.c matches abc / aZc but not ac" {
    var prog = try compile.compile(testing.allocator, "a.c", .{});
    defer prog.deinit(testing.allocator);
    try testing.expect((try matchFull(testing.allocator, &prog, "abc")) != null);
    try testing.expect((try matchFull(testing.allocator, &prog, "aZc")) != null);
    try testing.expectEqual(@as(?MatchResult, null), try matchFull(testing.allocator, &prog, "ac"));
}

// ADR-0031 cycle 1 acceptance tests (Resume contract).

test "cycle 1 acceptance: find a|b in xby returns {1, 2}" {
    var prog = try compile.compile(testing.allocator, "a|b", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "xby")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 2), r.end);
}

test "cycle 1 acceptance: find a* in aaa returns {0, 3}" {
    var prog = try compile.compile(testing.allocator, "a*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "find a* at start of xxx matches empty (Pike greedy)" {
    var prog = try compile.compile(testing.allocator, "a*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "xxx")).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 0), r.end);
}

test "find a+ requires at least one match" {
    var prog = try compile.compile(testing.allocator, "a+", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "xxx"));
    const r = (try find(testing.allocator, &prog, "xaay")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "find a? matches optional" {
    var prog = try compile.compile(testing.allocator, "a?", .{});
    defer prog.deinit(testing.allocator);
    const r1 = (try find(testing.allocator, &prog, "abc")).?;
    try testing.expectEqual(@as(u32, 0), r1.start);
    try testing.expectEqual(@as(u32, 1), r1.end);
    // No 'a' at start: empty match at 0.
    const r2 = (try find(testing.allocator, &prog, "xyz")).?;
    try testing.expectEqual(@as(u32, 0), r2.start);
    try testing.expectEqual(@as(u32, 0), r2.end);
}

test "find a|bc handles unequal-length alternation" {
    var prog = try compile.compile(testing.allocator, "a|bc", .{});
    defer prog.deinit(testing.allocator);
    const r1 = (try find(testing.allocator, &prog, "xa")).?;
    try testing.expectEqual(@as(u32, 1), r1.start);
    try testing.expectEqual(@as(u32, 2), r1.end);
    const r2 = (try find(testing.allocator, &prog, "xbc")).?;
    try testing.expectEqual(@as(u32, 1), r2.start);
    try testing.expectEqual(@as(u32, 3), r2.end);
}

test "find ab+ matches one a followed by greedy b run" {
    var prog = try compile.compile(testing.allocator, "ab+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "xabbby")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 5), r.end);
}
