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
/// only byte-consuming opcodes plus `.match`. Anchors consult
/// the current `pos` against `input` (line_start at pos 0,
/// line_end at input.len, \b on word/non-word transition);
/// failed anchors silently drop the thread. Cycle-1 `save`
/// stays a pass-through stub.
fn addThread(
    list: *ThreadList,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    pc: u32,
    pos: u32,
    input: []const u8,
) MatchError!void {
    if (list.seen[pc]) return;
    list.seen[pc] = true;
    switch (program.insts[pc]) {
        .jmp => |target| try addThread(list, alloc, program, target, pos, input),
        .split => |s| {
            try addThread(list, alloc, program, s.a, pos, input);
            try addThread(list, alloc, program, s.b, pos, input);
        },
        .save => try addThread(list, alloc, program, pc + 1, pos, input),
        .anchor => |a| {
            if (anchorMatches(a, pos, input)) {
                try addThread(list, alloc, program, pc + 1, pos, input);
            }
        },
        else => try list.pcs.append(alloc, pc),
    }
}

fn anchorMatches(a: compile.Anchor, pos: u32, input: []const u8) bool {
    return switch (a) {
        // Cycle 1 binds `^` and `$` to the string boundary;
        // multiline (`(?m)`) embedded-newline handling lands in
        // cycle 4.
        .line_start => pos == 0,
        .line_end => pos == input.len,
        .word_boundary => isWordBoundary(pos, input),
        .non_word_boundary => !isWordBoundary(pos, input),
    };
}

fn isWordBoundary(pos: u32, input: []const u8) bool {
    const left = pos != 0 and isWordByte(input[pos - 1]);
    const right = pos < input.len and isWordByte(input[pos]);
    return left != right;
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_';
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

    var best: ?MatchResult = null;
    var pos: u32 = start;
    try addThread(&current, alloc, program, 0, pos, input);

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
        const next_pos = pos + 1;
        for (current.pcs.items) |pc| {
            switch (program.insts[pc]) {
                .char => |cc| if (c == cc) try addThread(&next, alloc, program, pc + 1, next_pos, input),
                .class => |cls| if (cls.contains(c)) try addThread(&next, alloc, program, pc + 1, next_pos, input),
                .range => |r| if (c >= r.lo and c <= r.hi) try addThread(&next, alloc, program, pc + 1, next_pos, input),
                .match => {},
                else => {}, // epsilon ops are pre-expanded by addThread
            }
        }
        std.mem.swap(ThreadList, &current, &next);
        next.clear();
        pos = next_pos;
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

test "find \\d+ in abc123 returns the digit run" {
    var prog = try compile.compile(testing.allocator, "\\d+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abc123")).?;
    try testing.expectEqual(@as(u32, 3), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);
}

test "find [abc] in xyz returns null" {
    var prog = try compile.compile(testing.allocator, "[abc]", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "xyz"));
}

test "find [a-z]+ in ABCdef finds the lower-case run" {
    var prog = try compile.compile(testing.allocator, "[a-z]+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "ABCdef")).?;
    try testing.expectEqual(@as(u32, 3), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);
}

test "find [^a-z]+ skips lowercase run" {
    var prog = try compile.compile(testing.allocator, "[^a-z]+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abcXYZdef")).?;
    try testing.expectEqual(@as(u32, 3), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);
}

test "find \\s matches an ASCII space" {
    var prog = try compile.compile(testing.allocator, "\\s", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "a b")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 2), r.end);
}

test "find \\w+ skips whitespace and finds the word" {
    var prog = try compile.compile(testing.allocator, "\\w+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, " hello world ")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);
}

test "find \\. matches a literal dot in 1.2" {
    var prog = try compile.compile(testing.allocator, "\\.", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "1.2")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 2), r.end);
}

test "find ^abc matches at string start only" {
    var prog = try compile.compile(testing.allocator, "^abc", .{});
    defer prog.deinit(testing.allocator);
    try testing.expect((try find(testing.allocator, &prog, "abc")) != null);
    try testing.expect((try find(testing.allocator, &prog, "abcdef")) != null);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "xabc"));
}

test "find abc$ matches at string end only" {
    var prog = try compile.compile(testing.allocator, "abc$", .{});
    defer prog.deinit(testing.allocator);
    try testing.expect((try find(testing.allocator, &prog, "abc")) != null);
    try testing.expect((try find(testing.allocator, &prog, "xabc")) != null);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "abcd"));
}

test "find ^abc$ anchors both ends" {
    var prog = try compile.compile(testing.allocator, "^abc$", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abc")).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "xabc"));
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "abcx"));
}

test "find \\bword\\b matches whole word only" {
    var prog = try compile.compile(testing.allocator, "\\bword\\b", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "a word z")).?;
    try testing.expectEqual(@as(u32, 2), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);
    // No match when "word" sits inside a longer word.
    try testing.expectEqual(@as(?MatchResult, null), try find(testing.allocator, &prog, "swordfish"));
}

test "find \\Bxx\\B requires non-word boundary on both sides" {
    var prog = try compile.compile(testing.allocator, "\\Bxx\\B", .{});
    defer prog.deinit(testing.allocator);
    // "axxb" — between 'a'-'x' is word|word boundary (NOT \B);
    // between 'x'-'x' is word|word (IS \B); same on right.
    // So \Bxx\B starts at pos 1 (between two word chars) and
    // ends at pos 3 (between two word chars).
    const r = (try find(testing.allocator, &prog, "axxb")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "ADR-0031 cycle-1 exit smoke: re-find #\"\\d+\" \"abc123\" → \"123\"" {
    var prog = try compile.compile(testing.allocator, "\\d+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abc123")).?;
    try testing.expectEqualStrings("123", "abc123"[r.start..r.end]);
}

test "find ab+ matches one a followed by greedy b run" {
    var prog = try compile.compile(testing.allocator, "ab+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "xabbby")).?;
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 5), r.end);
}
