// SPDX-License-Identifier: EPL-2.0
//! Pike NFA matcher (Thompson thread-list VM) — namespace-neutral
//! implementation per F-009.
//!
//! Implements ADR-0031 Alt 2 (correctness baseline) over the
//! `Program` IR defined in `compile.zig`. A lazy-DFA fast path was
//! reserved by ADR-0031 but never built (no `dfa.zig`); the Pike VM
//! here is the sole matcher.
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
//! Anchor-position handling, capture groups, and the surface
//! primitives are all implemented here; only the reserved lazy-DFA
//! fast path remains unbuilt.

const std = @import("std");
const compile = @import("compile.zig");

/// Capture-slot count a program's threads carry: a start + end slot per group,
/// indexed `2g` / `2g+1` (group 0's pair is unused — the whole match is
/// `MatchResult.start/end`). Sized per program, so a pattern with no groups
/// carries no slots and one with many groups is not capped by an inline array
/// (the bound is `compile.MAX_CAPTURE_GROUPS`, enforced at parse time).
pub fn slotCount(program: *const compile.Program) usize {
    if (program.capture_count == 0) return 0;
    return (@as(usize, program.capture_count) + 1) * 2;
}

/// Capture slots of a match. -1 means "unset" (the group did not
/// participate). `slots` is owned by the `MatchResult` (see `deinit`).
pub const Captures = struct {
    slots: []i32 = &.{},
};

/// One live Pike VM thread. Its capture-slot snapshot lives in the owning
/// `ThreadList`'s slab at the thread's index (Pike submatch — the first thread
/// to reach a `.match`, in priority order, owns the leftmost-greedy captures).
pub const Thread = struct {
    pc: u32,
};

/// Match result returned by `find` / `match`. `null` (no result) means "no
/// match" (analogous to JVM Pattern.find returning false). The capture slots
/// are allocated with the allocator passed to the matcher entry point; release
/// them with `deinit` (a no-op for a pattern without groups).
pub const MatchResult = struct {
    start: u32,
    end: u32,
    captures: Captures = .{},

    pub fn deinit(self: MatchResult, alloc: std.mem.Allocator) void {
        if (self.captures.slots.len > 0) alloc.free(self.captures.slots);
    }

    /// Byte span of capture group `g` (`g >= 1`), or null when the group
    /// did not participate or `g` is out of range.
    pub fn group(self: MatchResult, g: usize) ?struct { start: u32, end: u32 } {
        if (g == 0 or 2 * g + 1 >= self.captures.slots.len) return null;
        const s = self.captures.slots[2 * g];
        const e = self.captures.slots[2 * g + 1];
        if (s < 0 or e < 0) return null;
        return .{ .start = @intCast(s), .end = @intCast(e) };
    }
};

/// The working state of one VM run: the two thread lists, a seed-capture
/// scratch row, and the best match's capture row. Allocated once per scan and
/// reused across every start position (D-386 / O-024).
const Vm = struct {
    current: ThreadList,
    next: ThreadList,
    /// Seed captures (all -1) threaded through `addThread`'s save/restore.
    scratch: []i32,
    /// Capture row of the best `.match` thread seen so far.
    best: []i32,

    fn init(alloc: std.mem.Allocator, n_insts: usize, nslots: usize) MatchError!Vm {
        var current = try ThreadList.init(alloc, n_insts, nslots);
        errdefer current.deinit(alloc);
        var next = try ThreadList.init(alloc, n_insts, nslots);
        errdefer next.deinit(alloc);
        const scratch = try alloc.alloc(i32, nslots);
        errdefer alloc.free(scratch);
        const best = try alloc.alloc(i32, nslots);
        return .{ .current = current, .next = next, .scratch = scratch, .best = best };
    }

    fn deinit(self: *Vm, alloc: std.mem.Allocator) void {
        self.current.deinit(alloc);
        self.next.deinit(alloc);
        alloc.free(self.scratch);
        alloc.free(self.best);
    }

    /// Package the best match as an owned `MatchResult`.
    fn result(self: *Vm, alloc: std.mem.Allocator, start: u32, end: u32) MatchError!MatchResult {
        if (self.best.len == 0) return .{ .start = start, .end = end };
        return .{ .start = start, .end = end, .captures = .{ .slots = try alloc.dupe(i32, self.best) } };
    }
};

pub const MatchError = error{} || std.mem.Allocator.Error;

/// `(re-find pattern input)` baseline: find the first match
/// anywhere in `input`. Returns null when no match exists.
pub fn find(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    return findFrom(alloc, program, input, 0);
}

/// Same as `find` but scan begins at byte offset `start`. Used by
/// `clojure.string/split` to iterate matches without re-walking
/// already-consumed prefix bytes. Exposed via
/// the `rt/re-find-from` primitive returning `[match start end]`.
pub fn findFrom(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?MatchResult {
    // PERF: D-386 (O-024) allocate the VM state ONCE for the whole scan;
    // tryMatchAt clears + reuses it per position (was: alloc+free per position).
    var vm = try Vm.init(alloc, program.insts.len, slotCount(program));
    defer vm.deinit(alloc);
    return scanFrom(&vm, alloc, program, input, start);
}

/// Leftmost match at or after `start`, using caller-owned VM state. Extracted
/// from `findFrom` so `findAll` can reuse ONE VM across every match in a
/// scan (tryMatchAt clears it per position, so reuse across scans is safe).
fn scanFrom(
    vm: *Vm,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?MatchResult {
    var pos: u32 = start;
    while (pos <= input.len) {
        // PERF: leading first-byte prefilter (O-036, ADR-0147 S2). When the
        // program must consume a determinable first byte, skip positions whose
        // byte cannot start a match with a cheap membership scan, instead of a
        // full ThreadList-clearing tryMatchAt at every position. The set is
        // exact-or-disabled (compile.zig:computeLeading), so this never skips a
        // position where a match could start — equivalence-neutral. A
        // non-nullable program cannot match at input.len, so exhausting the
        // scan returns null. [refs: O-036]
        if (program.leading) |lead| {
            while (pos < input.len and !lead.contains(input[pos])) pos += 1;
            if (pos >= input.len) return null;
        }
        if (try tryMatchAt(vm, alloc, program, input, pos)) |end| return try vm.result(alloc, pos, end);
        pos += 1;
    }
    return null;
}

/// A reusable leftmost-match scanner: ONE VM state for a whole multi-match
/// walk (`split`), where `findFrom` would allocate and free the thread lists
/// on every call. Same results as `findFrom(alloc, program, input, start)`.
/// [refs: O-072]
pub const Scanner = struct {
    vm: Vm,
    program: *const compile.Program,

    pub fn init(alloc: std.mem.Allocator, program: *const compile.Program) MatchError!Scanner {
        return .{ .vm = try Vm.init(alloc, program.insts.len, slotCount(program)), .program = program };
    }

    pub fn deinit(self: *Scanner, alloc: std.mem.Allocator) void {
        self.vm.deinit(alloc);
    }

    pub fn findFrom(self: *Scanner, alloc: std.mem.Allocator, input: []const u8, start: u32) MatchError!?MatchResult {
        return scanFrom(&self.vm, alloc, self.program, input, start);
    }
};

/// Append every non-overlapping match (scanning from offset 0) to `out`, reusing
/// ONE ThreadList pair across the whole scan — the one-pass backing for `re-seq`
/// (O-035, ADR-0147 Stage 1b). A zero-width match advances the scan by 1 so the
/// loop terminates (clj `re-seq` parity: `(re-seq #"a*" "aaa")` → `("aaa" "")`).
/// Each appended result owns its capture slots: release them with
/// `MatchResult.deinit` (see `deinitAll`).
pub fn findAll(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    out: *std.ArrayList(MatchResult),
) MatchError!void {
    var vm = try Vm.init(alloc, program.insts.len, slotCount(program));
    defer vm.deinit(alloc);
    var pos: u32 = 0;
    while (pos <= input.len) {
        const m = (try scanFrom(&vm, alloc, program, input, pos)) orelse break;
        out.append(alloc, m) catch |e| {
            m.deinit(alloc);
            return e;
        };
        pos = if (m.end == m.start) m.end + 1 else m.end;
    }
}

/// `(re-matches pattern input)` baseline: succeeds iff the WHOLE input matches
/// (anchored at both ends). A dedicated VM loop — NOT `tryMatchAt` + an
/// `end == len` check — because that takes the leftmost-first priority match and,
/// for a RELUCTANT quantifier (`a+?`), the priority match is the SHORTEST (and the
/// cut-on-match kills the expansion), so a full match like `(re-matches #"a+?"
/// "aaa")` → "aaa" would be missed. Here a `.match` thread counts ONLY at
/// `pos == input.len`; a `.match` reached earlier is dropped WITHOUT cutting, so a
/// lazy (or greedy) thread keeps consuming until it can satisfy the full span. At
/// end-of-input the highest-priority `.match` thread supplies the captures.
pub fn matchFull(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
) MatchError!?MatchResult {
    var vm = try Vm.init(alloc, program.insts.len, slotCount(program));
    defer vm.deinit(alloc);
    const current = &vm.current;
    const next = &vm.next;
    current.clear();
    next.clear();
    @memset(vm.scratch, -1);
    try addThread(current, alloc, program, 0, 0, input, vm.scratch);

    var pos: u32 = 0;
    while (true) {
        if (pos == input.len) {
            // Full match = the highest-priority `.match` thread at end-of-input.
            for (current.threads.items, 0..) |t, i| {
                if (program.insts[t.pc] == .match) {
                    @memcpy(vm.best, current.capsOf(i));
                    return try vm.result(alloc, 0, pos);
                }
            }
            return null;
        }
        const c = input[pos];
        const next_pos = pos + 1;
        for (current.threads.items, 0..) |t, i| {
            const caps = current.capsOf(i);
            switch (program.insts[t.pc]) {
                .char => |cc| if (c == cc) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps),
                .class => |cls| if (cls.contains(c)) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps),
                .range => |r| if (c >= r.lo and c <= r.hi) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps),
                else => {}, // `.match` at pos<len is NOT a full match — drop it (no cut, so a still-consuming thread survives); epsilons pre-expanded.
            }
        }
        if (next.threads.items.len == 0) return null;
        std.mem.swap(ThreadList, current, next);
        next.clear();
        pos = next_pos;
    }
}

/// Anchored match at exactly `start` (no leftmost scan): the leftmost-first
/// greedy match that BEGINS at `start`, or null. This is the Pike-VM reference
/// the lazy DFA (`dfa.zig`, ADR-0147 S3) is equivalence-tested against — the DFA
/// must produce byte-identical spans. Allocates its own ThreadLists per call
/// (test/oracle use; the hot scan paths reuse a pair via `scanFrom`).
pub fn matchAnchored(
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?MatchResult {
    var vm = try Vm.init(alloc, program.insts.len, slotCount(program));
    defer vm.deinit(alloc);
    const end = (try tryMatchAt(&vm, alloc, program, input, start)) orelse return null;
    return try vm.result(alloc, start, end);
}

/// Per-step thread list — set of PCs the VM is about to step
/// from. The `seen` stamps prevent re-processing the same PC
/// within a single input position (key Pike-VM invariant that
/// bounds runtime at O(n·m)). Thread `i`'s capture row is
/// `caps[i*nslots ..][0..nslots]`: one contiguous slab sized by the
/// program's group count, so the slot count is not a compile-time cap.
const ThreadList = struct {
    threads: std.ArrayList(Thread) = .empty,
    caps: std.ArrayList(i32) = .empty,
    nslots: usize,
    // PERF: generation-stamped `seen` (O-034). `clear` bumps `gen` instead of
    // `@memset`-ing the whole array per input position — `findFrom` clears both
    // lists at every position, so the naive memset was O(positions × insts). A
    // pc counts as seen this position iff `seen[pc] == gen`. [refs: O-034]
    seen: []u32,
    gen: u32,

    fn init(alloc: std.mem.Allocator, n_insts: usize, nslots: usize) MatchError!ThreadList {
        const seen = try alloc.alloc(u32, n_insts);
        @memset(seen, 0);
        // gen starts at 1 so the 0-fill never matches a freshly-cleared list.
        return .{ .nslots = nslots, .seen = seen, .gen = 1 };
    }

    fn deinit(self: *ThreadList, alloc: std.mem.Allocator) void {
        self.threads.deinit(alloc);
        self.caps.deinit(alloc);
        alloc.free(self.seen);
    }

    /// Append a consuming thread at `pc` carrying a COPY of `caps`.
    fn append(self: *ThreadList, alloc: std.mem.Allocator, pc: u32, caps: []const i32) MatchError!void {
        std.debug.assert(caps.len == self.nslots);
        try self.threads.append(alloc, .{ .pc = pc });
        try self.caps.appendSlice(alloc, caps);
    }

    /// Thread `i`'s capture row.
    fn capsOf(self: *ThreadList, i: usize) []i32 {
        return self.caps.items[i * self.nslots ..][0..self.nslots];
    }

    fn clear(self: *ThreadList) void {
        self.threads.clearRetainingCapacity();
        self.caps.clearRetainingCapacity();
        // O(1) clear via generation bump. On wrap, re-zero the stamps so a
        // stale max-gen entry cannot false-positive against the new gen.
        if (self.gen == std.math.maxInt(u32)) {
            @memset(self.seen, 0);
            self.gen = 1;
        } else {
            self.gen += 1;
        }
    }

    /// Mark `pc` seen this position; returns true if it was already seen.
    fn markSeen(self: *ThreadList, pc: u32) bool {
        if (self.seen[pc] == self.gen) return true;
        self.seen[pc] = self.gen;
        return false;
    }
};

/// Add a thread at `pc`, expanding epsilon transitions
/// (`jmp` / `split` / `save` / `anchor`) so the list contains
/// only byte-consuming opcodes plus `.match`. Anchors consult
/// the current `pos` against `input` (line_start at pos 0,
/// line_end at input.len, \b on word/non-word transition);
/// failed anchors silently drop the thread. `save` records the
/// capture-slot boundary at the current position. `caps` is a mutable
/// scratch row: a `save` writes its slot, recurses, then RESTORES it, so
/// sibling threads keep the pre-save captures without a per-save copy.
fn addThread(
    list: *ThreadList,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    pc: u32,
    pos: u32,
    input: []const u8,
    caps: []i32,
) MatchError!void {
    if (list.markSeen(pc)) return;
    switch (program.insts[pc]) {
        .jmp => |target| try addThread(list, alloc, program, target, pos, input, caps),
        .split => |s| {
            try addThread(list, alloc, program, s.a, pos, input, caps);
            try addThread(list, alloc, program, s.b, pos, input, caps);
        },
        .save => |slot| {
            // Record the capture-slot boundary at the current position for the
            // continuation, then restore it for the sibling threads.
            if (slot < caps.len) {
                const old = caps[slot];
                caps[slot] = @intCast(pos);
                defer caps[slot] = old;
                try addThread(list, alloc, program, pc + 1, pos, input, caps);
            } else {
                try addThread(list, alloc, program, pc + 1, pos, input, caps);
            }
        },
        .anchor => |a| {
            if (anchorMatches(a, pos, input)) {
                try addThread(list, alloc, program, pc + 1, pos, input, caps);
            }
        },
        .look => |lk| {
            // Zero-width: run the sub-program anchored at `pos`; the thread
            // continues (consuming nothing) iff a match exists XOR negate. A
            // POSITIVE lookahead threads its inner capture groups into the
            // continuing thread (JVM parity — group indices share the global
            // numbering); a NEGATIVE lookahead exports no captures (it succeeds
            // only when the sub fails, so there is nothing to capture).
            const sub_prog = compile.Program{ .insts = lk.sub, .capture_count = 0, .flags = program.flags };
            // Lookahead runs a SEPARATE sub-program (different inst count) — it
            // needs its own VM (cannot reuse the outer scan's); rare path (only
            // lookahead patterns), so the per-eval alloc is fine. The sub-VM
            // carries the parent's slot width: group indices are global.
            var sub = try Vm.init(alloc, sub_prog.insts.len, caps.len);
            defer sub.deinit(alloc);
            const m = try tryMatchAt(&sub, alloc, &sub_prog, input, pos);
            try continueAfterLook(list, alloc, program, pc, pos, input, caps, m != null, lk.negate, sub.best);
        },
        .look_behind => |lb| {
            // Zero-width backward assertion: does the sub match ENDING exactly
            // at `pos`? The sub carries a `.line_end` anchor before its
            // `.match`, so on the truncated `input[0..pos]` only an
            // exactly-at-pos end survives. Scan starts backward from pos
            // (real-world lookbehinds are short, so the nearest j wins fast);
            // any j gives the same boolean, so order is correctness-neutral.
            const sub_prog = compile.Program{ .insts = lb.sub, .capture_count = 0, .flags = program.flags };
            var sub = try Vm.init(alloc, sub_prog.insts.len, caps.len);
            defer sub.deinit(alloc);
            var found = false;
            var j: u32 = pos;
            while (true) {
                if ((try tryMatchAt(&sub, alloc, &sub_prog, input[0..pos], j)) != null) {
                    found = true;
                    break;
                }
                if (j == 0) break;
                j -= 1;
            }
            try continueAfterLook(list, alloc, program, pc, pos, input, caps, found, lb.negate, sub.best);
        },
        else => try list.append(alloc, pc, caps),
    }
}

/// Shared tail of the lookaround arms: continue past the assertion when it
/// holds, merging a positive sub-match's participating slots into a copy of
/// `caps` (a negative assertion exports nothing).
fn continueAfterLook(
    list: *ThreadList,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    pc: u32,
    pos: u32,
    input: []const u8,
    caps: []i32,
    matched: bool,
    negate: bool,
    sub_caps: []const i32,
) MatchError!void {
    if (matched == negate) return;
    if (!matched or caps.len == 0) return addThread(list, alloc, program, pc + 1, pos, input, caps);
    const next_caps = try alloc.dupe(i32, caps);
    defer alloc.free(next_caps);
    for (sub_caps, 0..) |sv, i| {
        if (sv != -1) next_caps[i] = sv;
    }
    try addThread(list, alloc, program, pc + 1, pos, input, next_caps);
}

fn anchorMatches(a: compile.Anchor, pos: u32, input: []const u8) bool {
    return switch (a) {
        // Default `^`/`$` bind to the whole-input boundary.
        .line_start => pos == 0,
        .line_end => pos == input.len,
        .input_start => pos == 0,
        .input_end => pos == input.len,
        // `\Z`: input end, or just before a FINAL terminator (`\n`, `\r`,
        // `\r\n`) — Java parity.
        .input_end_final => pos == input.len or
            (pos + 1 == input.len and (input[pos] == '\n' or input[pos] == '\r')) or
            (pos + 2 == input.len and input[pos] == '\r' and input[pos + 1] == '\n'),
        // `(?m)` MULTILINE: `^` matches at input start or right after a line
        // terminator; `$` at input end or right before one. A line terminator is
        // `\n`, a lone `\r`, or the `\r\n` pair — the position *between* `\r` and
        // `\n` is inside one terminator and matches neither (Java parity).
        .line_start_multi => pos == 0 or
            input[pos - 1] == '\n' or
            (input[pos - 1] == '\r' and (pos >= input.len or input[pos] != '\n')),
        .line_end_multi => pos == input.len or
            input[pos] == '\r' or
            (input[pos] == '\n' and (pos == 0 or input[pos - 1] != '\r')),
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
/// Returns the leftmost-FIRST greedy match anchored at `start` (Java
/// `java.util.regex` priority semantics — an earlier alternative wins over a
/// longer later one, e.g. `a|ab` on "ab" → "a"), or null if no thread reaches
/// `.match` from `start`.
/// Returns the match END (the span starts at `start`); the winning thread's
/// captures are left in `vm.best`.
fn tryMatchAt(
    vm: *Vm,
    alloc: std.mem.Allocator,
    program: *const compile.Program,
    input: []const u8,
    start: u32,
) MatchError!?u32 {
    const current = &vm.current;
    const next = &vm.next;
    // PERF: D-386 (O-024) `current`/`next` are caller-owned + reused across every
    // position in `findFrom` (a single `clear` = a memset of `seen` + retained
    // ArrayList capacity), instead of an alloc+free of two ThreadLists per
    // position. re-seq drove ~30 ThreadList allocs per call ×10000 → ~2. [refs: O-024]
    current.clear();
    next.clear();

    var best: ?u32 = null;
    var pos: u32 = start;
    @memset(vm.scratch, -1);
    try addThread(current, alloc, program, 0, pos, input, vm.scratch);

    // Leftmost-FIRST (Java/`java.util.regex` semantics, NOT POSIX leftmost-longest):
    // step threads in PRIORITY order and CUT — at the first `.match` thread, record it
    // and stop, dropping every lower-priority thread (they cannot beat a higher-priority
    // match). Higher-priority threads were already advanced into `next` earlier in this
    // same loop, so a still-consuming greedy / earlier-alternative thread keeps extending
    // and overwrites `best` at a later position; a lower-priority *longer* alternative is
    // discarded. This is what makes `(re-find #"a|ab" "ab")` → "a" (clj), not "ab".
    // The unified step+match loop replaces the prior two-loop form whose second loop
    // stepped EVERY thread (so a lower-priority longer alt overrode → leftmost-longest bug).
    while (current.threads.items.len > 0) {
        const c: ?u8 = if (pos < input.len) input[pos] else null;
        const next_pos = pos + 1;
        for (current.threads.items, 0..) |t, i| {
            const caps = current.capsOf(i);
            switch (program.insts[t.pc]) {
                .match => {
                    best = pos;
                    @memcpy(vm.best, caps);
                    break; // cut every lower-priority thread
                },
                .char => |cc| if (c) |ch| {
                    if (ch == cc) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps);
                },
                .class => |cls| if (c) |ch| {
                    if (cls.contains(ch)) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps);
                },
                .range => |r| if (c) |ch| {
                    if (ch >= r.lo and ch <= r.hi) try addThread(next, alloc, program, t.pc + 1, next_pos, input, caps);
                },
                else => {}, // epsilon ops are pre-expanded by addThread
            }
        }
        if (pos >= input.len) break;
        std.mem.swap(ThreadList, current, next);
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

// D-448: a capture group inside an outer quantifier where the INNER can match
// empty takes Java's FINAL empty-iteration capture value. `(a*)*` on "aaa": the
// outer `*` runs one final empty inner iteration (inner `a*` matches "" at pos 3),
// so group 1 = [3,3] = "" — NOT the last non-empty [0,3] = "aaa". `(a+)* / (a)*`
// (non-nullable inner) already capture the last non-empty run, unchanged.
fn group1(r: MatchResult) struct { s: i32, e: i32 } {
    defer r.deinit(testing.allocator);
    return .{ .s = r.captures.slots[2], .e = r.captures.slots[3] };
}

test "D-448 nullable-inner outer star: final empty iteration owns the capture" {
    var prog = try compile.compile(testing.allocator, "(a*)*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    try testing.expectEqual(@as(u32, 3), r.end);
    const g = group1(r);
    try testing.expectEqual(@as(i32, 3), g.s); // group 1 start = 3 (empty final iter)
    try testing.expectEqual(@as(i32, 3), g.e); // group 1 end   = 3 → ""
}

test "D-448 nullable-inner outer plus: final empty iteration owns the capture" {
    var prog = try compile.compile(testing.allocator, "(a*)+", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    try testing.expectEqual(@as(u32, 3), r.end);
    const g = group1(r);
    try testing.expectEqual(@as(i32, 3), g.s);
    try testing.expectEqual(@as(i32, 3), g.e);
}

test "D-448 regression: non-nullable inner keeps the last non-empty capture" {
    // `(a+)*` on "aaa" → group 1 = [0,3] = "aaa" (inner `a+` cannot match empty,
    // so no final empty iteration); matches clj. Must NOT regress.
    var prog = try compile.compile(testing.allocator, "(a+)*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    const g = group1(r);
    try testing.expectEqual(@as(i32, 0), g.s);
    try testing.expectEqual(@as(i32, 3), g.e);
}

test "D-448 regression: single-char group star keeps the last iteration" {
    // `(a)*` on "aaa" → group 1 = [2,3] = "a" (last iteration); matches clj.
    var prog = try compile.compile(testing.allocator, "(a)*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    const g = group1(r);
    try testing.expectEqual(@as(i32, 2), g.s);
    try testing.expectEqual(@as(i32, 3), g.e);
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

test "findAll collects every \\d+ run in order" {
    var prog = try compile.compile(testing.allocator, "\\d+", .{});
    defer prog.deinit(testing.allocator);
    var out: std.ArrayList(MatchResult) = .empty;
    defer out.deinit(testing.allocator);
    try findAll(testing.allocator, &prog, "a12b345c6789d0e", &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].start);
    try testing.expectEqual(@as(u32, 3), out.items[0].end); // "12"
    try testing.expectEqual(@as(u32, 13), out.items[3].start);
    try testing.expectEqual(@as(u32, 14), out.items[3].end); // "0"
}

test "findAll zero-width: a* over aaa yields aaa then empty (re-seq parity)" {
    var prog = try compile.compile(testing.allocator, "a*", .{});
    defer prog.deinit(testing.allocator);
    var out: std.ArrayList(MatchResult) = .empty;
    defer out.deinit(testing.allocator);
    try findAll(testing.allocator, &prog, "aaa", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].start);
    try testing.expectEqual(@as(u32, 3), out.items[0].end); // "aaa"
    try testing.expectEqual(@as(u32, 3), out.items[1].start);
    try testing.expectEqual(@as(u32, 3), out.items[1].end); // ""
}

// Leftmost-FIRST (Java priority) — an earlier alternative wins over a longer
// later one (was leftmost-LONGEST before the cut-on-match fix).

test "leftmost-first: a|ab on ab matches a, not ab" {
    var prog = try compile.compile(testing.allocator, "a|ab", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "ab")).?;
    try testing.expectEqualStrings("a", "ab"[r.start..r.end]);
}

test "leftmost-first: a|ab|abc on abc matches a" {
    var prog = try compile.compile(testing.allocator, "a|ab|abc", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "abc")).?;
    try testing.expectEqualStrings("a", "abc"[r.start..r.end]);
}

test "leftmost-first: foo|foobar on foobar matches foo" {
    var prog = try compile.compile(testing.allocator, "foo|foobar", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "foobar")).?;
    try testing.expectEqualStrings("foo", "foobar"[r.start..r.end]);
}

test "leftmost-first: prefix-alt that fails overall falls through to longer alt" {
    // foo-branch consumes "foo" then needs "baz" but sees "bar" → dies; the
    // foobar-branch survives to match. Cut must not pre-empt this.
    var prog = try compile.compile(testing.allocator, "(foo|foobar)baz", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "foobarbaz")).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("foobarbaz", "foobarbaz"[r.start..r.end]);
}

test "leftmost-first preserves greedy: a* on aaa still matches aaa" {
    var prog = try compile.compile(testing.allocator, "a*", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaa")).?;
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "leftmost-first preserves greedy: ab? on ab still matches ab" {
    var prog = try compile.compile(testing.allocator, "ab?", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "ab")).?;
    try testing.expectEqualStrings("ab", "ab"[r.start..r.end]);
}

test "leftmost-first: re-seq x|xy on xyxy yields x,x" {
    var prog = try compile.compile(testing.allocator, "x|xy", .{});
    defer prog.deinit(testing.allocator);
    var out: std.ArrayList(MatchResult) = .empty;
    defer out.deinit(testing.allocator);
    try findAll(testing.allocator, &prog, "xyxy", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("x", "xyxy"[out.items[0].start..out.items[0].end]);
    try testing.expectEqualStrings("x", "xyxy"[out.items[1].start..out.items[1].end]);
}

// Reluctant (lazy) quantifiers — `*?` / `+?` / `??` / `{n,m}?` (D-447). Prefer the
// FEWEST reps; the split-priority swap + leftmost-first cut yields the short match.

test "reluctant a+? matches one (re-find), greedy a+ matches all" {
    var lazy = try compile.compile(testing.allocator, "a+?", .{});
    defer lazy.deinit(testing.allocator);
    const r = (try find(testing.allocator, &lazy, "aaa")).?;
    try testing.expectEqualStrings("a", "aaa"[r.start..r.end]);
}

test "reluctant a*? / a?? prefer the empty match" {
    inline for (.{ "a*?", "a??" }) |pat| {
        var prog = try compile.compile(testing.allocator, pat, .{});
        defer prog.deinit(testing.allocator);
        const r = (try find(testing.allocator, &prog, "aaa")).?;
        try testing.expectEqual(@as(u32, 0), r.end); // empty match at 0
    }
}

test "reluctant <.+?> stops at the first close (not greedy to last)" {
    var prog = try compile.compile(testing.allocator, "<.+?>", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "<a><b>")).?;
    try testing.expectEqualStrings("<a>", "<a><b>"[r.start..r.end]);
}

test "reluctant {2,4}? takes the minimum" {
    var prog = try compile.compile(testing.allocator, "a{2,4}?", .{});
    defer prog.deinit(testing.allocator);
    const r = (try find(testing.allocator, &prog, "aaaa")).?;
    try testing.expectEqualStrings("aa", "aaaa"[r.start..r.end]);
}

test "matchFull forces a reluctant quantifier to fill the whole input" {
    // re-matches anchors both ends, so a+? must expand to "aaa" (the bug the
    // dedicated matchFull loop fixes — tryMatchAt's priority match is the short one).
    var lazy = try compile.compile(testing.allocator, "a+?", .{});
    defer lazy.deinit(testing.allocator);
    const r = (try matchFull(testing.allocator, &lazy, "aaa")).?;
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "matchFull still rejects a non-full match (\\d+ over 12a)" {
    var prog = try compile.compile(testing.allocator, "\\d+", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(?MatchResult, null), try matchFull(testing.allocator, &prog, "12a"));
}

test "findAll no match yields empty out" {
    var prog = try compile.compile(testing.allocator, "z", .{});
    defer prog.deinit(testing.allocator);
    var out: std.ArrayList(MatchResult) = .empty;
    defer out.deinit(testing.allocator);
    try findAll(testing.allocator, &prog, "abc", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
