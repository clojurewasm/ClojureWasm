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
pub fn find(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    _ = alloc;
    _ = program;
    _ = input;
    return MatchError.NotImplemented;
}

/// `(re-matches pattern input)` baseline: succeeds iff the
/// whole input matches the pattern (anchored at both ends).
pub fn matchFull(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    _ = alloc;
    _ = program;
    _ = input;
    return MatchError.NotImplemented;
}
