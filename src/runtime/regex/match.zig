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
//!   - Two thread lists (`current`, `next`); each thread is a PC
//!     plus a fixed-size capture-slot snapshot.
//!   - Step input character-by-character; epsilon closures
//!     (`jmp` / `split` / `save`) expand on demand.
//!   - On `match` instruction, record captures; on input
//!     exhaustion with no live thread, no match.
//!   - O(n·m) worst case, no catastrophic backtracking.
//!
//! Status: Phase 6.6 cycle 1 SKELETON — types declared, the
//! `find` / `match` / `seq` drivers raise NotImplemented until
//! the parser + IR emit lands in `compile.zig`.

const std = @import("std");
const compile = @import("compile.zig");

/// Maximum capture-group slot count (start + end for each group).
/// JVM Clojure supports more, but the Phase 6.6 cycle-1 baseline
/// caps at 8 groups (16 slots). Wider patterns fall back to a
/// heap-allocated slot array in cycle 3.
pub const MAX_SLOTS_INLINE: usize = 16;

/// Capture-slot snapshot carried by each thread. -1 means
/// "unset". On match, the slot array is the user-visible result
/// of `re-groups`.
pub const Captures = struct {
    slots: [MAX_SLOTS_INLINE]i32 = [_]i32{-1} ** MAX_SLOTS_INLINE,
    used: usize = 0,
};

/// One live Pike VM thread.
pub const Thread = struct {
    pc: u32,
    captures: Captures,
};

/// Match result returned by `find` / `match`. `null` slot ends
/// mean "no match" (analogous to JVM Pattern.find returning
/// false).
pub const MatchResult = struct {
    start: u32,
    end: u32,
    captures: Captures,
};

pub const MatchError = error{
    /// Phase 6.6 cycle 1 skeleton — body lands next commit.
    NotImplemented,
} || std.mem.Allocator.Error;

/// `(re-find pattern input)` baseline: find the first match
/// anywhere in `input`. Returns null when no match exists.
///
/// Cycle-1 first cell: single-thread linear scan. Handles
/// programs consisting of `Inst.char` followed by `Inst.match`
/// (single-character literal patterns). Alternation /
/// quantifiers / classes require the full Pike-VM driver and
/// land together with the parser's cycle-1 expansion.
pub fn find(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    _ = alloc;
    var start: u32 = 0;
    while (start <= input.len) : (start += 1) {
        if (try tryMatchAt(program, input, start)) |result| return result;
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
    _ = alloc;
    const result = (try tryMatchAt(program, input, 0)) orelse return null;
    if (result.end != input.len) return null;
    return result;
}

/// Attempt one match starting at `start`. Cycle-1 baseline:
/// straight-line execution through the IR; the Pike-VM thread
/// list is unused for the single-character literal case.
fn tryMatchAt(
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?MatchResult {
    var pc: u32 = 0;
    var ip: u32 = start;
    while (pc < program.insts.len) : (pc += 1) {
        switch (program.insts[pc]) {
            .char => |c| {
                if (ip >= input.len) return null;
                if (input[ip] != c) return null;
                ip += 1;
            },
            .match => return MatchResult{
                .start = start,
                .end = ip,
                .captures = .{},
            },
            else => return MatchError.NotImplemented,
        }
    }
    return null;
}

test "find single-char literal in middle of input" {
    var prog = try compile.compile(std.testing.allocator, "b", .{});
    defer prog.deinit(std.testing.allocator);
    const r = (try find(std.testing.allocator, &prog, "abc")).?;
    try std.testing.expectEqual(@as(u32, 1), r.start);
    try std.testing.expectEqual(@as(u32, 2), r.end);
}

test "find returns null on no match" {
    var prog = try compile.compile(std.testing.allocator, "z", .{});
    defer prog.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?MatchResult, null), try find(std.testing.allocator, &prog, "abc"));
}

test "matchFull only succeeds on full-string match" {
    var prog = try compile.compile(std.testing.allocator, "a", .{});
    defer prog.deinit(std.testing.allocator);
    const r1 = try matchFull(std.testing.allocator, &prog, "a");
    try std.testing.expect(r1 != null);
    const r2 = try matchFull(std.testing.allocator, &prog, "abc");
    try std.testing.expectEqual(@as(?MatchResult, null), r2);
}

test "find multi-char literal in middle of input" {
    var prog = try compile.compile(std.testing.allocator, "bc", .{});
    defer prog.deinit(std.testing.allocator);
    const r = (try find(std.testing.allocator, &prog, "xabcd")).?;
    try std.testing.expectEqual(@as(u32, 2), r.start);
    try std.testing.expectEqual(@as(u32, 4), r.end);
}

test "matchFull green on exact multi-char literal" {
    var prog = try compile.compile(std.testing.allocator, "abc", .{});
    defer prog.deinit(std.testing.allocator);
    const r = (try matchFull(std.testing.allocator, &prog, "abc")).?;
    try std.testing.expectEqual(@as(u32, 0), r.start);
    try std.testing.expectEqual(@as(u32, 3), r.end);
}

/// One Pike-VM step: advance every live thread by consuming
/// (or rejecting) the input byte `c` at position `pos`.
/// Epsilon-closure (`jmp` / `split` / `save`) is followed
/// inline before the byte test.
///
/// Status: skeleton — body lands together with the parser /
/// emit in `compile.zig`. Once green, this function is the
/// hot loop the matcher driver invokes per input byte.
fn step(
    program: *const compile.Program,
    current: []Thread,
    next: *std.ArrayList(Thread),
    c: u8,
    pos: u32,
) MatchError!void {
    _ = program;
    _ = current;
    _ = next;
    _ = c;
    _ = pos;
    return MatchError.NotImplemented;
}

test "step is currently NotImplemented" {
    var threads: [0]Thread = .{};
    var next: std.ArrayList(Thread) = .empty;
    defer next.deinit(std.testing.allocator);
    const prog = compile.Program{
        .insts = &.{},
        .capture_count = 0,
        .flags = .{},
    };
    try std.testing.expectError(MatchError.NotImplemented, step(&prog, &threads, &next, 0, 0));
}
