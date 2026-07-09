// SPDX-License-Identifier: EPL-2.0
//! Lazy DFA backend (ADR-0147 Stage 3, Alt 2) — a caching subset-construction over
//! the byte automaton in `compile.zig`'s `Program`. This is the regex engine's
//! throughput backend: where the Pike VM (`match.zig`) simulates every live thread
//! per input byte, this determinizes on the fly — one DFA state = the set of NFA PCs
//! reachable so far (in PRIORITY order, cut at the first `.match`), advancing one
//! state per byte via a memoized `(state, byte) → state` transition. The first time
//! an edge is taken it is computed (epsilon-closure of the successors) and cached;
//! later visits are a map lookup.
//!
//! ## Status (this increment): forward, anchored, span-only — NOT yet wired in.
//! This file builds the FORWARD half: `matchEndAnchored` returns the leftmost-first
//! greedy match END for a match that BEGINS at a given offset, byte-identical to the
//! Pike VM's `matchAnchored` (the equivalence test below locks this). The reverse
//! DFA (leftmost START → O(input) `find`) and the `find`/`findAll` wire-in land in
//! the completing commit (ADR-0147 S3 = forward+reverse, Alt 2). Until then the Pike
//! VM in `match.zig` remains the sole user-facing matcher; this module is exercised
//! only by its own unit tests. Span-only: captures stay the two-pass Pike VM.
//!
//! ## Leftmost-FIRST (matches the Pike VM's cut-on-match behaviour)
//! Determinization keeps the NFA PCs in priority order and CUTS on match — a `.match`
//! in a state's PC-list means lower-priority PCs do not advance on a transition
//! (they cannot beat a higher-priority match). So a span never disagrees with the
//! Pike VM (`a|ab` on "ab" → "a", not "ab").
//!
//! ## Eligibility
//! Anchors (`^`/`$`/`\b`) and lookaround are position-dependent and are NOT encoded
//! in a byte-DFA state — `eligible(program)` returns false for them, and the caller
//! falls back to the Pike VM. (Folding anchors into the DFA state is the deferred
//! Alt-3 follow-up; see ADR-0147.)

const std = @import("std");
const compile = @import("compile.zig");
const Program = compile.Program;

pub const StateId = u32;

/// A determinized state: the epsilon-closed NFA PC-set in priority order (the same
/// order `match.zig:addThread` produces), plus whether it is accepting. The `pcs`
/// slice is owned by the `LazyDfa` that interned it.
const State = struct {
    pcs: []const u32,
    is_match: bool,
};

/// Returns true iff every match of `program` must consume a determinable byte
/// sequence with no position-dependent assertion — i.e. the program has no
/// `.anchor` and no `.look` inst. Only such programs are byte-DFA-representable.
pub fn eligible(program: *const Program) bool {
    for (program.insts) |inst| {
        switch (inst) {
            .anchor, .look, .look_behind => return false,
            else => {},
        }
    }
    return true;
}

const PcSliceCtx = struct {
    pub fn hash(_: PcSliceCtx, key: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: PcSliceCtx, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

const StateMap = std.HashMapUnmanaged([]const u32, StateId, PcSliceCtx, std.hash_map.default_max_load_percentage);

/// Lazy DFA over one `Program`. Owns the interned states + the transition cache;
/// `deinit` frees everything. Build once per match call (or reuse across a scan).
pub const LazyDfa = struct {
    program: *const Program,
    alloc: std.mem.Allocator,
    states: std.ArrayList(State) = .empty,
    intern: StateMap = .empty,
    /// Anchored-step cache: `(state_id << 8) | byte` → next state id (no reseed).
    trans: std.AutoHashMapUnmanaged(u64, StateId) = .empty,
    /// Unanchored-step cache: same key shape; the transition re-seeds pc 0 at lowest
    /// priority (the leftmost `.*?` prefix) — used by the pre-match forward scan.
    utrans: std.AutoHashMapUnmanaged(u64, StateId) = .empty,
    /// Scratch reused across forward closure builds (visited stamps + ordered output).
    visited: []u32,
    gen: u32 = 1,
    scratch: std.ArrayList(u32) = .empty,
    // --- reverse automaton (leftmost START), built in init ---
    /// Reverse-epsilon predecessors in CSR form: `rev_eps[rev_eps_off[v]..off[v+1]]` =
    /// the PCs `u` with a forward epsilon edge `u → v` (jmp/split/save). Used by the
    /// reverse closure to walk backward over epsilon transitions.
    rev_eps_off: []u32,
    rev_eps: []u32,
    /// The forward `.match` PCs — the reverse automaton's start seed.
    match_seed: []u32,
    /// Reverse-closure scratch (transient PC-set per backward step; uncached — the
    /// reverse pass is a single O(n·m) backward scan per find, not a hot cache).
    rev_visited: []u32,
    rev_gen: u32 = 1,
    rev_members: std.ArrayList(u32) = .empty,

    pub fn init(alloc: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!LazyDfa {
        const n = program.insts.len;
        const visited = try alloc.alloc(u32, n);
        @memset(visited, 0);
        const rev_visited = try alloc.alloc(u32, n);
        @memset(rev_visited, 0);

        // Build the reverse-epsilon CSR + the match seed in two passes over the insts.
        const deg = try alloc.alloc(u32, n + 1);
        defer alloc.free(deg);
        @memset(deg, 0);
        var n_match: usize = 0;
        for (program.insts, 0..) |inst, pc| {
            switch (inst) {
                .jmp => |t| deg[t] += 1,
                .split => |s| {
                    deg[s.a] += 1;
                    deg[s.b] += 1;
                },
                .save => deg[pc + 1] += 1,
                .match => n_match += 1,
                else => {},
            }
        }
        const rev_eps_off = try alloc.alloc(u32, n + 1);
        var acc: u32 = 0;
        for (0..n) |v| {
            rev_eps_off[v] = acc;
            acc += deg[v];
        }
        rev_eps_off[n] = acc;
        const rev_eps = try alloc.alloc(u32, acc);
        const cursor = try alloc.alloc(u32, n);
        defer alloc.free(cursor);
        for (0..n) |v| cursor[v] = rev_eps_off[v];
        const match_seed = try alloc.alloc(u32, n_match);
        var mi: usize = 0;
        for (program.insts, 0..) |inst, pc| {
            const u: u32 = @intCast(pc);
            switch (inst) {
                .jmp => |t| {
                    rev_eps[cursor[t]] = u;
                    cursor[t] += 1;
                },
                .split => |s| {
                    rev_eps[cursor[s.a]] = u;
                    cursor[s.a] += 1;
                    rev_eps[cursor[s.b]] = u;
                    cursor[s.b] += 1;
                },
                .save => {
                    rev_eps[cursor[pc + 1]] = u;
                    cursor[pc + 1] += 1;
                },
                .match => {
                    match_seed[mi] = u;
                    mi += 1;
                },
                else => {},
            }
        }

        return .{
            .program = program,
            .alloc = alloc,
            .visited = visited,
            .rev_eps_off = rev_eps_off,
            .rev_eps = rev_eps,
            .match_seed = match_seed,
            .rev_visited = rev_visited,
        };
    }

    pub fn deinit(self: *LazyDfa) void {
        for (self.states.items) |st| self.alloc.free(st.pcs);
        self.states.deinit(self.alloc);
        self.intern.deinit(self.alloc);
        self.trans.deinit(self.alloc);
        self.utrans.deinit(self.alloc);
        self.alloc.free(self.visited);
        self.scratch.deinit(self.alloc);
        self.alloc.free(self.rev_eps_off);
        self.alloc.free(self.rev_eps);
        self.alloc.free(self.match_seed);
        self.alloc.free(self.rev_visited);
        self.rev_members.deinit(self.alloc);
    }

    /// Epsilon-closure of `seed` into `self.scratch` (priority order, dedup), mirroring
    /// `match.zig:addThread`: `jmp`/`split`/`save` are walked, consuming + `.match`
    /// insts are emitted. Eligible programs have no `.anchor`/`.look`.
    fn closure(self: *LazyDfa, seed: []const u32) std.mem.Allocator.Error!void {
        self.scratch.clearRetainingCapacity();
        // O(1) visited clear via generation bump (same idiom as ThreadList.seen).
        if (self.gen == std.math.maxInt(u32)) {
            @memset(self.visited, 0);
            self.gen = 1;
        } else {
            self.gen += 1;
        }
        for (seed) |pc| try self.addClosure(pc);
    }

    fn addClosure(self: *LazyDfa, pc: u32) std.mem.Allocator.Error!void {
        if (self.visited[pc] == self.gen) return;
        self.visited[pc] = self.gen;
        switch (self.program.insts[pc]) {
            .jmp => |t| try self.addClosure(t),
            .split => |s| {
                try self.addClosure(s.a);
                try self.addClosure(s.b);
            },
            .save => try self.addClosure(pc + 1),
            // Consuming insts + `.match` are the state's members. `.anchor`/`.look`
            // never reach here (eligible() excludes them); treat as a dead end.
            .char, .range, .class, .match => try self.scratch.append(self.alloc, pc),
            .anchor, .look, .look_behind => {},
        }
    }

    /// Intern the closure currently in `self.scratch` → its StateId (creating it on
    /// first sight). `is_match` = the closure contains a `.match` PC.
    fn intern_scratch(self: *LazyDfa) std.mem.Allocator.Error!StateId {
        const gop = try self.intern.getOrPut(self.alloc, self.scratch.items);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.alloc.dupe(u32, self.scratch.items);
        gop.key_ptr.* = owned;
        var is_match = false;
        for (owned) |pc| {
            if (self.program.insts[pc] == .match) {
                is_match = true;
                break;
            }
        }
        const id: StateId = @intCast(self.states.items.len);
        try self.states.append(self.alloc, .{ .pcs = owned, .is_match = is_match });
        gop.value_ptr.* = id;
        return id;
    }

    /// The start state = closure of pc 0.
    fn startState(self: *LazyDfa) std.mem.Allocator.Error!StateId {
        try self.closure(&[_]u32{0});
        return self.intern_scratch();
    }

    /// Transition `state` on byte `c` → next StateId, or null for the dead state
    /// (no thread survives). Cut at the first `.match` PC in priority order so a
    /// lower-priority longer alternative does not advance (leftmost-first).
    fn transition(self: *LazyDfa, state_id: StateId, c: u8) std.mem.Allocator.Error!?StateId {
        const key = (@as(u64, state_id) << 8) | c;
        if (self.trans.get(key)) |nx| return if (nx == DEAD) null else nx;
        // Compute the seed = advanced consuming PCs before the first match, into scratch.
        self.scratch.clearRetainingCapacity();
        // Snapshot the source PCs first: `closure` (called below) reuses `scratch`,
        // and `self.states` may reallocate when interning grows it.
        const pcs = self.states.items[state_id].pcs;
        var seed_buf: std.ArrayList(u32) = .empty;
        defer seed_buf.deinit(self.alloc);
        for (pcs) |pc| {
            switch (self.program.insts[pc]) {
                .match => break, // cut lower-priority threads
                .char => |cc| if (c == cc) try seed_buf.append(self.alloc, pc + 1),
                .class => |cls| if (cls.contains(c)) try seed_buf.append(self.alloc, pc + 1),
                .range => |r| if (c >= r.lo and c <= r.hi) try seed_buf.append(self.alloc, pc + 1),
                else => {},
            }
        }
        if (seed_buf.items.len == 0) {
            try self.trans.put(self.alloc, key, DEAD);
            return null;
        }
        try self.closure(seed_buf.items);
        const nx = try self.intern_scratch();
        try self.trans.put(self.alloc, key, nx);
        return nx;
    }

    const DEAD: StateId = std.math.maxInt(StateId);

    /// Leftmost-first greedy match END for a match anchored at `start`, or null.
    /// Byte-identical to `match.zig:matchAnchored(...).end`. The match span is
    /// `[start, returned)`.
    pub fn matchEndAnchored(self: *LazyDfa, input: []const u8, start: u32) std.mem.Allocator.Error!?u32 {
        var state_id = try self.startState();
        var pos: u32 = start;
        var best: ?u32 = if (self.states.items[state_id].is_match) pos else null;
        while (pos < input.len) {
            const nx = (try self.transition(state_id, input[pos])) orelse break;
            pos += 1;
            state_id = nx;
            if (self.states.items[state_id].is_match) best = pos;
        }
        return best;
    }

    /// Unanchored forward step (cached in `utrans`): advance the state's consuming PCs
    /// (cut at the first `.match`, leftmost-first) on byte `c`, THEN re-seed pc 0 at
    /// LOWEST priority — the leftmost `.*?` prefix, so a match may still begin later.
    /// Never dead (the reseed always seeds pc 0).
    fn ustepTransition(self: *LazyDfa, state_id: StateId, c: u8) std.mem.Allocator.Error!StateId {
        const key = (@as(u64, state_id) << 8) | c;
        if (self.utrans.get(key)) |nx| return nx;
        const pcs = self.states.items[state_id].pcs;
        var seed_buf: std.ArrayList(u32) = .empty;
        defer seed_buf.deinit(self.alloc);
        for (pcs) |pc| {
            switch (self.program.insts[pc]) {
                .match => break, // cut lower-priority threads
                .char => |cc| if (c == cc) try seed_buf.append(self.alloc, pc + 1),
                .class => |cls| if (cls.contains(c)) try seed_buf.append(self.alloc, pc + 1),
                .range => |r| if (c >= r.lo and c <= r.hi) try seed_buf.append(self.alloc, pc + 1),
                else => {},
            }
        }
        try seed_buf.append(self.alloc, 0); // reseed the start at lowest priority
        try self.closure(seed_buf.items);
        const nx = try self.intern_scratch();
        try self.utrans.put(self.alloc, key, nx);
        return nx;
    }

    /// Leftmost-first match END for the leftmost match at or after `start`, via the
    /// 2-phase forward scan: phase 1 re-seeds pc 0 each byte (`ustepTransition`) until the
    /// first accept pins the leftmost start; phase 2 switches to the anchored `transition`
    /// (no reseed) and extends that match greedily. Returns the END, or null if no match.
    fn findEnd(self: *LazyDfa, input: []const u8, start: u32) std.mem.Allocator.Error!?u32 {
        var state_id = try self.startState();
        var matched = self.states.items[state_id].is_match;
        var end: ?u32 = if (matched) start else null;
        var pos: u32 = start;
        while (pos < input.len) {
            if (matched) {
                const nx = (try self.transition(state_id, input[pos])) orelse break;
                pos += 1;
                state_id = nx;
                if (self.states.items[state_id].is_match) end = pos;
            } else {
                state_id = try self.ustepTransition(state_id, input[pos]);
                pos += 1;
                if (self.states.items[state_id].is_match) {
                    matched = true;
                    end = pos;
                }
            }
        }
        return end;
    }

    /// Reverse-epsilon closure of `seeds` into `self.rev_members`: walk reverse-epsilon
    /// edges; a member is a PC with a reverse-byte-out edge (`pc≥1 ∧ inst[pc-1]` consuming)
    /// or pc 0 (the reverse accept). Returns whether pc 0 was reached — i.e. the forward
    /// start is reachable, so `[·, end)` is a full match from this reverse position.
    fn revClosure(self: *LazyDfa, seeds: []const u32) std.mem.Allocator.Error!bool {
        self.rev_members.clearRetainingCapacity();
        if (self.rev_gen == std.math.maxInt(u32)) {
            @memset(self.rev_visited, 0);
            self.rev_gen = 1;
        } else {
            self.rev_gen += 1;
        }
        var accept = false;
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.alloc);
        for (seeds) |s| try stack.append(self.alloc, s);
        while (stack.pop()) |pc| {
            if (self.rev_visited[pc] == self.rev_gen) continue;
            self.rev_visited[pc] = self.rev_gen;
            if (pc == 0) accept = true;
            const is_byte_target = pc == 0 or (pc >= 1 and switch (self.program.insts[pc - 1]) {
                .char, .class, .range => true,
                else => false,
            });
            if (is_byte_target) try self.rev_members.append(self.alloc, pc);
            var e = self.rev_eps_off[pc];
            const hi = self.rev_eps_off[pc + 1];
            while (e < hi) : (e += 1) {
                const u = self.rev_eps[e];
                if (self.rev_visited[u] != self.rev_gen) try stack.append(self.alloc, u);
            }
        }
        return accept;
    }

    /// Leftmost START of the match known to END at `end`, scanning backward to `lo`. The
    /// reverse DFA accepts (reaches pc 0) at the smallest position `s` where `[s, end)` is
    /// a full match — the leftmost start. No priority/cut (the end is fixed; reachability
    /// of pc 0 is all that matters).
    fn revFindStart(self: *LazyDfa, input: []const u8, end: u32, lo: u32) std.mem.Allocator.Error!?u32 {
        var cur: std.ArrayList(u32) = .empty;
        defer cur.deinit(self.alloc);
        var accept = try self.revClosure(self.match_seed);
        try cur.appendSlice(self.alloc, self.rev_members.items);
        var best: ?u32 = if (accept) end else null;
        var pos: u32 = end;
        while (pos > lo) {
            const c = input[pos - 1];
            var seed: std.ArrayList(u32) = .empty;
            defer seed.deinit(self.alloc);
            for (cur.items) |m| {
                if (m >= 1) {
                    const matches = switch (self.program.insts[m - 1]) {
                        .char => |cc| c == cc,
                        .class => |cls| cls.contains(c),
                        .range => |r| c >= r.lo and c <= r.hi,
                        else => false,
                    };
                    if (matches) try seed.append(self.alloc, m - 1);
                }
            }
            if (seed.items.len == 0) break;
            accept = try self.revClosure(seed.items);
            cur.clearRetainingCapacity();
            try cur.appendSlice(self.alloc, self.rev_members.items);
            pos -= 1;
            if (accept) best = pos;
        }
        return best;
    }

    /// `(re-find …)` span via the lazy DFA: forward 2-phase finds the leftmost match END,
    /// the reverse DFA recovers its leftmost START. Byte-identical to the Pike VM's
    /// leftmost-first span. Returns `[start, end)` or null. Eligible programs only;
    /// captures, when needed, are a separate two-pass Pike VM run over the span.
    pub fn find(self: *LazyDfa, input: []const u8, from: u32) std.mem.Allocator.Error!?Span {
        const end = (try self.findEnd(input, from)) orelse return null;
        const start = (try self.revFindStart(input, end, from)).?;
        return .{ .start = start, .end = end };
    }
};

pub const Span = struct { start: u32, end: u32 };

// --- tests: equivalence vs the Pike VM (match.zig:matchAnchored) ---

const testing = std.testing;
const match = @import("match.zig");

/// Assert dfa.matchEndAnchored == pikeVM matchAnchored(...).end for `pat` over every
/// suffix-start of `input` — the exhaustive anchored-equivalence check.
fn expectDfaMatchesPike(pat: []const u8, input: []const u8) !void {
    var prog = try compile.compile(testing.allocator, pat, .{});
    defer prog.deinit(testing.allocator);
    try testing.expect(eligible(&prog)); // these test patterns are all DFA-eligible

    var dfa = try LazyDfa.init(testing.allocator, &prog);
    defer dfa.deinit();

    var start: u32 = 0;
    while (start <= input.len) : (start += 1) {
        const pike = try match.matchAnchored(testing.allocator, &prog, input, start);
        const pike_end: ?u32 = if (pike) |m| m.end else null;
        const dfa_end = try dfa.matchEndAnchored(input, start);
        try testing.expectEqual(pike_end, dfa_end);
    }
}

test "dfa eligible: anchors and lookaround are declined" {
    inline for (.{ "^a", "a$", "\\bword", "a(?=b)" }) |pat| {
        var prog = try compile.compile(testing.allocator, pat, .{});
        defer prog.deinit(testing.allocator);
        try testing.expect(!eligible(&prog));
    }
    inline for (.{ "\\d+", "a|ab", "[a-z]+", "(ab)+" }) |pat| {
        var prog = try compile.compile(testing.allocator, pat, .{});
        defer prog.deinit(testing.allocator);
        try testing.expect(eligible(&prog));
    }
}

test "dfa==pike: leftmost-first alternation a|ab" {
    try expectDfaMatchesPike("a|ab", "ab");
    try expectDfaMatchesPike("a|ab|abc", "abc");
    try expectDfaMatchesPike("foo|foobar", "foobar");
}

test "dfa==pike: greedy quantifiers" {
    try expectDfaMatchesPike("a*", "aaa");
    try expectDfaMatchesPike("a+", "aaab");
    try expectDfaMatchesPike("ab?", "ab");
    try expectDfaMatchesPike("a{2,3}", "aaaa");
}

test "dfa==pike: classes and digit runs" {
    try expectDfaMatchesPike("\\d+", "a12b345");
    try expectDfaMatchesPike("[a-z]+", "ABCdefGHI");
    try expectDfaMatchesPike("\\w+", "foo bar");
    try expectDfaMatchesPike("[^0-9]+", "abc123");
}

test "dfa==pike: alternation and groups (span only)" {
    try expectDfaMatchesPike("cat|dog", "xcatydog");
    try expectDfaMatchesPike("(ab)+", "ababab");
    try expectDfaMatchesPike("(a|b)+", "abba");
    try expectDfaMatchesPike("(foo|foobar)baz", "foobarbaz");
}

test "dfa==pike: no match and empty-capable" {
    try expectDfaMatchesPike("z", "abc");
    try expectDfaMatchesPike("x*", "");
    try expectDfaMatchesPike("a*", "bbb");
    try expectDfaMatchesPike("\\d+", "no digits here");
}

/// Assert `dfa.find(input, 0)` == the Pike VM's leftmost `find` SPAN (start+end).
fn expectDfaFindMatchesPike(pat: []const u8, input: []const u8) !void {
    var prog = try compile.compile(testing.allocator, pat, .{});
    defer prog.deinit(testing.allocator);
    try testing.expect(eligible(&prog));

    var dfa = try LazyDfa.init(testing.allocator, &prog);
    defer dfa.deinit();

    const pike = try match.find(testing.allocator, &prog, input);
    const span = try dfa.find(input, 0);
    if (pike) |m| {
        try testing.expect(span != null);
        try testing.expectEqual(m.start, span.?.start);
        try testing.expectEqual(m.end, span.?.end);
    } else {
        try testing.expect(span == null);
    }
}

test "dfa.find==pike: leftmost-first start, not earliest end" {
    // The leftmost match begins at the earliest START; a later-start shorter match
    // ending sooner must NOT win. abc|b on "xabc": "abc" at [1,4), not "b" at [2,3).
    try expectDfaFindMatchesPike("abc|b", "xabc");
    try expectDfaFindMatchesPike("a|ab", "ab");
    try expectDfaFindMatchesPike("foo|foobar", "xxfoobar");
    try expectDfaFindMatchesPike("(foo|foobar)baz", "zfoobarbaz");
}

test "dfa.find==pike: leftmost scan finds first occurrence" {
    try expectDfaFindMatchesPike("\\d+", "abc123def456");
    try expectDfaFindMatchesPike("[a-z]+", "  hello  ");
    try expectDfaFindMatchesPike("cat|dog", "the dog and cat");
    try expectDfaFindMatchesPike("ab+", "xxxabbby");
}

test "dfa.find==pike: greedy + empty-capable + no-match" {
    try expectDfaFindMatchesPike("a*", "aaab");
    try expectDfaFindMatchesPike("a*", "bbb");
    try expectDfaFindMatchesPike("a+", "bbb");
    try expectDfaFindMatchesPike("x*", "");
    try expectDfaFindMatchesPike("z", "abc");
    try expectDfaFindMatchesPike("a{2,3}", "xaaaa");
}

test "dfa.find==pike: quadratic-shape (begins-but-not-completes) stays correct" {
    // \d+x over a long digit run: many starts, the match completes only at the 'x'.
    try expectDfaFindMatchesPike("\\d+x", "1111111");
    try expectDfaFindMatchesPike("\\d+x", "1111111x");
    try expectDfaFindMatchesPike("a+b", "aaaaaaa");
    try expectDfaFindMatchesPike("a+b", "aaaaaaab");
}

test "dfa.find==pike: exhaustive small-alphabet fuzz" {
    // Deterministic matrix: every pattern × a fixed set of {a,b,c,1,2}* inputs. A
    // reverse-pass priority bug shows up as a wrong start on at least one pair.
    const pats = [_][]const u8{ "a|ab", "ab|a", "(a|b)+", "a*b", "\\d+", "[abc]+", "(ab)+c", "a+|b+", "ab?c", "\\w+" };
    const inputs = [_][]const u8{ "", "a", "ab", "abc", "ba", "aabb", "c1a2", "abcabc", "1a2b3", "bbbaaa", "xabcx", "12ab" };
    for (pats) |p| {
        for (inputs) |in| try expectDfaFindMatchesPike(p, in);
    }
}
