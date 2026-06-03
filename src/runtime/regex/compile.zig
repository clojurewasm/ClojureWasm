// SPDX-License-Identifier: EPL-2.0
//! Regex compile pipeline (parser + AST + IR) — namespace-neutral
//! implementation per F-009.
//!
//! Implements ADR-0031 Alternative 2 (two-tier IR + lazy DFA over
//! Pike-NFA). This module owns the parser → AST → `Program` IR
//! pipeline. The matcher lives in `match.zig` (Pike VM, cycle 1
//! correctness baseline) and `dfa.zig` (lazy DFA fast path,
//! cycle 2).
//!
//! Two surfaces consume this file:
//!   1. `lang/primitive/regex.zig` — Clojure-ns peer (`re-pattern`
//!      / `re-find` / `re-matches` / `re-seq` / `re-groups` in
//!      clojure.core).
//!   2. `runtime/java/util/regex/Pattern.zig` — Java surface
//!      (`(java.util.regex.Pattern/compile ...)` etc.).
//!
//! Cycle 1 (Phase 6.6) supports: literal bytes, `.` wildcard,
//! concatenation, alternation `|`, and the greedy quantifiers
//! `*` / `+` / `?`. Character classes, escapes, anchors, capture
//! groups, and named groups land in cycle 2+.

const std = @import("std");

/// Compile flags. `(?i)` inline modifier rewrites at compile
/// time into case-folded character classes (ADR-0031 Alt 2 cycle
/// 4); the runtime sees only the folded form.
pub const Flags = packed struct(u8) {
    case_insensitive: bool = false,
    _pad: u7 = 0,
};

/// Parsed AST node. The parser produces this tree; the IR
/// emitter walks it to populate `Program.insts`.
/// Sentinel `max` for an unbounded `{n,}` repeat (`.repeat.max == REPEAT_INF`
/// ⇒ `n` mandatory copies followed by `*`).
pub const REPEAT_INF: u16 = std.math.maxInt(u16);

pub const Node = union(enum) {
    /// A single literal byte (e.g. `a`).
    lit: u8,
    /// A character-class bitmap (e.g. `[a-z]`, `\d`).
    class: CharClass,
    /// Sequential composition (`ab`).
    concat: []Node,
    /// Alternation (`a|b`).
    alt: []Node,
    /// `e*` — zero or more (greedy).
    star: *Node,
    /// `e+` — one or more (greedy).
    plus: *Node,
    /// `e?` — optional.
    quest: *Node,
    /// `e{n,m}` — bounded repetition.
    repeat: struct { child: *Node, min: u16, max: u16 },
    /// Capturing group `(e)` — `index` is the slot pair offset.
    group: struct { child: *Node, index: u16 },
    /// Non-capturing group `(?:e)`.
    non_capture: *Node,
    /// Position anchor (`^`, `$`, `\b`, `\B`).
    anchor: Anchor,
};

/// Character-class bitmap: 256 bits over the byte alphabet.
/// Phase 6.6 cycle 1 stays ASCII; Unicode `\p{...}` lands as a
/// debt row at cycle 3+.
pub const CharClass = struct {
    bits: [32]u8 = [_]u8{0} ** 32,

    pub fn set(self: *CharClass, b: u8) void {
        self.bits[b >> 3] |= @as(u8, 1) << @intCast(b & 7);
    }

    pub fn contains(self: CharClass, b: u8) bool {
        return (self.bits[b >> 3] & (@as(u8, 1) << @intCast(b & 7))) != 0;
    }
};

pub const Anchor = enum {
    line_start,
    line_end,
    word_boundary,
    non_word_boundary,
};

/// IR instruction (Pike VM opcode). Matches Russ Cox's
/// thread-list VM design — `char` / `range` advance, `match` is
/// the accept state, `jmp` / `split` change the PC, `save`
/// records a capture-group boundary into the thread's slot
/// array.
pub const Inst = union(enum) {
    char: u8,
    range: struct { lo: u8, hi: u8 },
    class: CharClass,
    anchor: Anchor,
    match: void,
    jmp: u32,
    split: struct { a: u32, b: u32 },
    save: u32,
};

/// Compiled program — the IR boundary between parser/optimiser
/// and the runtime matcher (NFA / DFA). Lifetime equals the
/// `Pattern` Value that owns it.
pub const Program = struct {
    insts: []const Inst,
    capture_count: u16,
    flags: Flags,

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        alloc.free(self.insts);
    }
};

pub const CompileError = error{
    /// Pattern source contains a feature not yet implemented at
    /// cycle 1 (empty pattern, character classes `[...]`,
    /// groups `(...)`, escapes `\\d` / `\\w`, anchors `^` / `$`,
    /// bounded `{n,m}`). Per `no_op_stub_forbidden`, the error
    /// is explicit rather than silent.
    NotImplemented,

    /// Parser-level syntax error: stray metacharacter, dangling
    /// quantifier, etc. Replaces JVM's `PatternSyntaxException`
    /// in cycle 1; refinement lands in cycle 5.
    UnexpectedToken,
    UnclosedGroup,
    UnclosedClass,
    InvalidQuantifier,
    InvalidEscape,
} || std.mem.Allocator.Error;

/// Compile a regex pattern source into a `Program`. Caller owns
/// the resulting `Program` and must call `Program.deinit` to
/// free the IR slice.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Program {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var group_count: u16 = 0;
    const node = try parsePattern(arena.allocator(), pattern, flags, &group_count);
    return try emit(alloc, node, flags, group_count);
}

/// Recursive-descent parser entry: produces an AST `Node` tree
/// into the supplied arena allocator.
///
/// Grammar (cycle 1):
///
/// ```text
/// pattern := alt
/// alt     := concat ('|' concat)*
/// concat  := quant+                       -- empty branches reject in cycle 1
/// quant   := atom ('*' | '+' | '?')?
/// atom    := '.' | char_class | escape | literal_byte
/// char_class := '[' '^'? class_item+ ']'
/// class_item := escape | byte ('-' byte)?
/// escape  := '\' ('d'|'D'|'w'|'W'|'s'|'S'|'t'|'n'|'r'|'f'|meta_byte)
/// ```
pub fn parsePattern(arena: std.mem.Allocator, pattern: []const u8, flags: Flags, group_count_out: *u16) CompileError!*const Node {
    _ = flags;
    if (pattern.len == 0) {
        // `#""` / `(re-pattern "")` — an empty pattern matches the empty string
        // at every position (clj parity). An empty `.concat` emits no insts, so
        // `emit` produces just the trailing `.match`.
        const node = try arena.create(Node);
        node.* = .{ .concat = &.{} };
        group_count_out.* = 0;
        return node;
    }
    var parser: Parser = .{ .src = pattern, .pos = 0, .arena = arena };
    const node = try parser.parseAlt();
    if (!parser.atEnd()) return CompileError.UnexpectedToken;
    group_count_out.* = parser.group_count;
    return node;
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    /// Next capturing-group index to assign (1-based; group 0 is the whole
    /// match, carried by MatchResult.start/end, not a slot pair).
    group_count: u16 = 0,

    fn atEnd(self: Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: Parser) ?u8 {
        if (self.atEnd()) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.atEnd()) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn parseAlt(self: *Parser) CompileError!*Node {
        const first = try self.parseConcat();
        if (self.peek() != @as(?u8, '|')) return first;
        var children: std.ArrayList(Node) = .empty;
        try children.append(self.arena, first.*);
        while (self.peek() == @as(?u8, '|')) {
            _ = self.advance();
            const branch = try self.parseConcat();
            try children.append(self.arena, branch.*);
        }
        const node = try self.arena.create(Node);
        node.* = .{ .alt = try children.toOwnedSlice(self.arena) };
        return node;
    }

    fn parseConcat(self: *Parser) CompileError!*Node {
        var children: std.ArrayList(Node) = .empty;
        while (true) {
            const p = self.peek() orelse break;
            if (p == '|') break;
            if (p == ')') break; // close of the enclosing group
            // Quantifier with no operand: '*' / '+' / '?' here is a syntax error.
            if (p == '*' or p == '+' or p == '?') return CompileError.UnexpectedToken;
            // Cycle-1 supports `.`, `[`, and `\`. Other metas
            // (`(`, `)`, `^`, `$`, `{`, `}`, stray `]`) reach
            // parseAtom which raises NotImplemented / UnexpectedToken.
            const atom = try self.parseQuant();
            try children.append(self.arena, atom.*);
        }
        if (children.items.len == 0) return CompileError.NotImplemented;
        if (children.items.len == 1) {
            const single = try self.arena.create(Node);
            single.* = children.items[0];
            return single;
        }
        const node = try self.arena.create(Node);
        node.* = .{ .concat = try children.toOwnedSlice(self.arena) };
        return node;
    }

    fn parseQuant(self: *Parser) CompileError!*Node {
        const atom = try self.parseAtom();
        const p = self.peek() orelse return atom;
        const wrapped: Node = switch (p) {
            '*' => .{ .star = atom },
            '+' => .{ .plus = atom },
            '?' => .{ .quest = atom },
            // `{n}` / `{n,}` / `{n,m}` bounded repetition.
            '{' => return try self.parseRepeat(atom),
            else => return atom,
        };
        _ = self.advance();
        const node = try self.arena.create(Node);
        node.* = wrapped;
        return node;
    }

    /// Parse a `{n}` / `{n,}` / `{n,m}` bound after `atom` (cursor at `{`).
    fn parseRepeat(self: *Parser, atom: *Node) CompileError!*Node {
        _ = self.advance(); // consume '{'
        const min = try self.parseUint();
        var max: u16 = min;
        if (self.peek() == @as(?u8, ',')) {
            _ = self.advance();
            if (self.peek() == @as(?u8, '}')) {
                max = REPEAT_INF; // `{n,}` — unbounded
            } else {
                max = try self.parseUint();
            }
        }
        if (self.peek() != @as(?u8, '}')) return CompileError.UnexpectedToken;
        _ = self.advance(); // consume '}'
        if (max != REPEAT_INF and max < min) return CompileError.UnexpectedToken;
        const node = try self.arena.create(Node);
        node.* = .{ .repeat = .{ .child = atom, .min = min, .max = max } };
        return node;
    }

    /// Parse one or more ASCII digits as a u16 (at least one required).
    fn parseUint(self: *Parser) CompileError!u16 {
        var n: u32 = 0;
        var any = false;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            _ = self.advance();
            n = n * 10 + (c - '0');
            if (n > std.math.maxInt(u16)) return CompileError.UnexpectedToken;
            any = true;
        }
        if (!any) return CompileError.UnexpectedToken;
        return @intCast(n);
    }

    fn parseAtom(self: *Parser) CompileError!*Node {
        const c = self.advance() orelse return CompileError.UnexpectedToken;
        const node = try self.arena.create(Node);
        if (c == '.') {
            node.* = atomFor('.');
            return node;
        }
        if (c == '[') {
            node.* = .{ .class = try self.parseCharClass() };
            return node;
        }
        if (c == '\\') {
            node.* = try self.parseEscape();
            return node;
        }
        if (c == '^') {
            node.* = .{ .anchor = .line_start };
            return node;
        }
        if (c == '$') {
            node.* = .{ .anchor = .line_end };
            return node;
        }
        if (c == '(') {
            // `(?:e)` non-capturing vs `(e)` capturing. Other `(?…)` forms
            // (lookaround, named groups, inline flags) are not yet supported.
            var capturing = true;
            var idx: u16 = 0;
            if (self.peek() == @as(?u8, '?')) {
                _ = self.advance();
                if (self.advance() != @as(?u8, ':')) return CompileError.NotImplemented;
                capturing = false;
            } else {
                self.group_count += 1;
                idx = self.group_count;
                if (idx >= 8) return CompileError.NotImplemented; // MAX_SLOTS_INLINE/2
            }
            const child = try self.parseAlt();
            if (self.advance() != @as(?u8, ')')) return CompileError.UnclosedGroup;
            node.* = if (capturing) .{ .group = .{ .child = child, .index = idx } } else .{ .non_capture = child };
            return node;
        }
        if (c == ']') return CompileError.UnexpectedToken;
        // Remaining cycle-1 unsupported metas: ), {, }.
        if (isMetaChar(c)) return CompileError.NotImplemented;
        node.* = .{ .lit = c };
        return node;
    }

    fn parseCharClass(self: *Parser) CompileError!CharClass {
        var negate = false;
        if (self.peek() == @as(?u8, '^')) {
            _ = self.advance();
            negate = true;
        }
        if (self.atEnd()) return CompileError.UnclosedClass;
        if (self.peek() == @as(?u8, ']')) {
            // Empty class `[]` / `[^]` — cycle 1 holds back; JVM
            // treats `[]` as a syntax error and `[^]` as
            // "anything", neither of which we need yet.
            return CompileError.NotImplemented;
        }
        var cls: CharClass = .{};
        while (true) {
            const c = self.advance() orelse return CompileError.UnclosedClass;
            if (c == ']') break;
            if (c == '\\') {
                const esc = try self.parseEscape();
                switch (esc) {
                    .lit => |b| cls.set(b),
                    .class => |sub| {
                        for (0..cls.bits.len) |i| cls.bits[i] |= sub.bits[i];
                    },
                    else => return CompileError.InvalidEscape,
                }
                continue;
            }
            // Range a-z: peek `-` and the following char is not `]`.
            if (self.peek() == @as(?u8, '-') and
                self.pos + 1 < self.src.len and
                self.src[self.pos + 1] != ']')
            {
                _ = self.advance(); // consume '-'
                const hi = self.advance() orelse return CompileError.UnclosedClass;
                // Escaped range endpoint deferred to cycle 1b.
                if (hi == '\\') return CompileError.NotImplemented;
                if (c > hi) return CompileError.InvalidQuantifier;
                var b: u16 = c;
                while (b <= hi) : (b += 1) cls.set(@intCast(b));
            } else {
                cls.set(c);
            }
        }
        if (negate) {
            for (0..cls.bits.len) |i| cls.bits[i] = ~cls.bits[i];
        }
        return cls;
    }

    fn parseEscape(self: *Parser) CompileError!Node {
        const c = self.advance() orelse return CompileError.InvalidEscape;
        return switch (c) {
            'd' => .{ .class = digitClass() },
            'D' => .{ .class = negateClass(digitClass()) },
            'w' => .{ .class = wordClass() },
            'W' => .{ .class = negateClass(wordClass()) },
            's' => .{ .class = whitespaceClass() },
            'S' => .{ .class = negateClass(whitespaceClass()) },
            't' => .{ .lit = '\t' },
            'n' => .{ .lit = '\n' },
            'r' => .{ .lit = '\r' },
            'f' => .{ .lit = 12 },
            'b' => .{ .anchor = .word_boundary },
            'B' => .{ .anchor = .non_word_boundary },
            '.', '*', '+', '?', '(', ')', '[', ']', '|', '\\', '^', '$', '{', '}', '/' => .{ .lit = c },
            else => CompileError.InvalidEscape,
        };
    }
};

fn digitClass() CharClass {
    var cls: CharClass = .{};
    var b: u8 = '0';
    while (b <= '9') : (b += 1) cls.set(b);
    return cls;
}

fn wordClass() CharClass {
    var cls: CharClass = digitClass();
    var b: u8 = 'a';
    while (b <= 'z') : (b += 1) cls.set(b);
    b = 'A';
    while (b <= 'Z') : (b += 1) cls.set(b);
    cls.set('_');
    return cls;
}

fn whitespaceClass() CharClass {
    var cls: CharClass = .{};
    cls.set(' ');
    cls.set('\t');
    cls.set('\n');
    cls.set('\r');
    cls.set(12); // form feed
    return cls;
}

fn negateClass(c: CharClass) CharClass {
    var out: CharClass = .{};
    for (0..c.bits.len) |i| out.bits[i] = ~c.bits[i];
    return out;
}

/// Cycle-1 atom builder: literal byte, or `.` → all-set
/// character class (cycle-1 simplification — JVM `.` excludes
/// `\n`; the line-ending exclusion lands with the `(?s)` flag
/// in cycle 4).
fn atomFor(c: u8) Node {
    if (c == '.') {
        var cls: CharClass = .{};
        for (0..256) |b| cls.set(@intCast(b));
        return .{ .class = cls };
    }
    return .{ .lit = c };
}

fn isMetaChar(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '(', ')', '[', ']', '|', '\\', '^', '$', '{', '}' => true,
        else => false,
    };
}

/// IR emitter: walks the AST and emits Pike-VM instructions
/// into a flat `Inst` slice.
fn emit(alloc: std.mem.Allocator, node: *const Node, flags: Flags, capture_count: u16) CompileError!Program {
    var list: std.ArrayList(Inst) = .empty;
    errdefer list.deinit(alloc);
    try emitNode(&list, alloc, node);
    try list.append(alloc, .{ .match = {} });
    return Program{
        .insts = try list.toOwnedSlice(alloc),
        .capture_count = capture_count,
        .flags = flags,
    };
}

fn emitNode(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, node: *const Node) CompileError!void {
    switch (node.*) {
        .lit => |c| try list.append(alloc, .{ .char = c }),
        .class => |cls| try list.append(alloc, .{ .class = cls }),
        .anchor => |a| try list.append(alloc, .{ .anchor = a }),
        .concat => |children| {
            for (children) |*ch| try emitNode(list, alloc, ch);
        },
        .alt => |children| try emitAlt(list, alloc, children),
        .star => |child| try emitStar(list, alloc, child),
        .plus => |child| try emitPlus(list, alloc, child),
        .quest => |child| try emitQuest(list, alloc, child),
        .group => |g| {
            // save(2*idx) … child … save(2*idx+1): slot pair brackets the
            // sub-match so the matcher records group `idx`'s [start,end).
            try list.append(alloc, .{ .save = @as(u32, 2) * g.index });
            try emitNode(list, alloc, g.child);
            try list.append(alloc, .{ .save = @as(u32, 2) * g.index + 1 });
        },
        .non_capture => |child| try emitNode(list, alloc, child),
        // `{n,m}` → n mandatory copies, then (m-n) greedy-optional copies; a
        // `{n,}` (max == REPEAT_INF) appends `*` after the n mandatory copies.
        .repeat => |r| {
            var i: u16 = 0;
            while (i < r.min) : (i += 1) try emitNode(list, alloc, r.child);
            if (r.max == REPEAT_INF) {
                try emitStar(list, alloc, r.child);
            } else {
                var j: u16 = r.min;
                while (j < r.max) : (j += 1) try emitQuest(list, alloc, r.child);
            }
        },
    }
}

/// `e1|e2|...|en` →
/// ```text
///   split{e1_start, rest_start}
///   <e1>
///   jmp end
///   split{e2_start, rest_start}    -- for n ≥ 3, chained per branch
///   <e2>
///   jmp end
///   ...
///   <en>
///   end:
/// ```
/// Each `split` and `jmp` is emitted as a placeholder and
/// backpatched once the operand's IR position is known.
fn emitAlt(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, children: []const Node) CompileError!void {
    if (children.len == 0) return;
    if (children.len == 1) {
        try emitNode(list, alloc, &children[0]);
        return;
    }
    var jmp_indices: std.ArrayList(u32) = .empty;
    defer jmp_indices.deinit(alloc);

    for (children, 0..) |*ch, i| {
        if (i == children.len - 1) {
            try emitNode(list, alloc, ch);
        } else {
            const split_idx = list.items.len;
            try list.append(alloc, .{ .split = .{ .a = 0, .b = 0 } });
            const ch_start: u32 = @intCast(list.items.len);
            try emitNode(list, alloc, ch);
            const jmp_idx: u32 = @intCast(list.items.len);
            try list.append(alloc, .{ .jmp = 0 });
            try jmp_indices.append(alloc, jmp_idx);
            const next_branch_start: u32 = @intCast(list.items.len);
            list.items[split_idx] = .{ .split = .{ .a = ch_start, .b = next_branch_start } };
        }
    }
    const end: u32 = @intCast(list.items.len);
    for (jmp_indices.items) |idx| {
        list.items[idx] = .{ .jmp = end };
    }
}

/// `e*` (greedy) →
/// ```text
///   L0: split{body, after}
///       <e>
///       jmp L0
///   after:
/// ```
/// `split.a = body` puts the consume branch ahead of the skip
/// branch — greedy semantics fall out of Pike VM thread priority.
fn emitStar(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, child: *const Node) CompileError!void {
    const L0: u32 = @intCast(list.items.len);
    const split_idx = list.items.len;
    try list.append(alloc, .{ .split = .{ .a = 0, .b = 0 } });
    const body_start: u32 = @intCast(list.items.len);
    try emitNode(list, alloc, child);
    try list.append(alloc, .{ .jmp = L0 });
    const after: u32 = @intCast(list.items.len);
    list.items[split_idx] = .{ .split = .{ .a = body_start, .b = after } };
}

/// `e+` (greedy) →
/// ```text
///   L0: <e>
///       split{L0, after}
///   after:
/// ```
fn emitPlus(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, child: *const Node) CompileError!void {
    const L0: u32 = @intCast(list.items.len);
    try emitNode(list, alloc, child);
    const split_idx = list.items.len;
    try list.append(alloc, .{ .split = .{ .a = L0, .b = 0 } });
    const after: u32 = @intCast(list.items.len);
    list.items[split_idx].split.b = after;
}

/// `e?` (greedy) →
/// ```text
///   split{body, after}
///   <e>
///   after:
/// ```
fn emitQuest(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, child: *const Node) CompileError!void {
    const split_idx = list.items.len;
    try list.append(alloc, .{ .split = .{ .a = 0, .b = 0 } });
    const body_start: u32 = @intCast(list.items.len);
    try emitNode(list, alloc, child);
    const after: u32 = @intCast(list.items.len);
    list.items[split_idx] = .{ .split = .{ .a = body_start, .b = after } };
}

// --- tests ---

const testing = std.testing;

test "compile single-char literal emits [char, match]" {
    var prog = try compile(testing.allocator, "a", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), prog.insts.len);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[0].char);
    try testing.expectEqual({}, prog.insts[1].match);
}

test "compile rejects unsupported metas / stray quantifier" {
    // Empty pattern compiles to just `[match]` — matches the empty string at any
    // position (clj `#""` parity, D-232).
    {
        var prog = try compile(testing.allocator, "", .{});
        defer prog.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), prog.insts.len);
        try testing.expectEqual({}, prog.insts[0].match);
    }
    // Stray quantifier (no operand): syntax error.
    try testing.expectError(CompileError.UnexpectedToken, compile(testing.allocator, "*", .{}));
    try testing.expectError(CompileError.UnexpectedToken, compile(testing.allocator, "+", .{}));
    try testing.expectError(CompileError.UnexpectedToken, compile(testing.allocator, "?", .{}));
    // Cycle-1 unsupported metas: explicit not-implemented.
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, "(", .{}));
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, "{", .{}));
    // Lone trailing backslash: parseEscape sees end-of-input.
    try testing.expectError(CompileError.InvalidEscape, compile(testing.allocator, "\\", .{}));
    // Unclosed character class.
    try testing.expectError(CompileError.UnclosedClass, compile(testing.allocator, "[", .{}));
}

test "compile multi-char literal emits sequence of char + match" {
    var prog = try compile(testing.allocator, "abc", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), prog.insts.len);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[0].char);
    try testing.expectEqual(@as(u8, 'b'), prog.insts[1].char);
    try testing.expectEqual(@as(u8, 'c'), prog.insts[2].char);
    try testing.expectEqual({}, prog.insts[3].match);
}

test "compile a|b emits split + char + jmp + char + match" {
    var prog = try compile(testing.allocator, "a|b", .{});
    defer prog.deinit(testing.allocator);
    // Layout: 0 split{1,3}, 1 char 'a', 2 jmp 4, 3 char 'b', 4 match
    try testing.expectEqual(@as(usize, 5), prog.insts.len);
    try testing.expectEqual(@as(u32, 1), prog.insts[0].split.a);
    try testing.expectEqual(@as(u32, 3), prog.insts[0].split.b);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[1].char);
    try testing.expectEqual(@as(u32, 4), prog.insts[2].jmp);
    try testing.expectEqual(@as(u8, 'b'), prog.insts[3].char);
    try testing.expectEqual({}, prog.insts[4].match);
}

test "compile a* emits L0 split + char + jmp L0 + match" {
    var prog = try compile(testing.allocator, "a*", .{});
    defer prog.deinit(testing.allocator);
    // Layout: 0 split{1,3}, 1 char 'a', 2 jmp 0, 3 match
    try testing.expectEqual(@as(usize, 4), prog.insts.len);
    try testing.expectEqual(@as(u32, 1), prog.insts[0].split.a);
    try testing.expectEqual(@as(u32, 3), prog.insts[0].split.b);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[1].char);
    try testing.expectEqual(@as(u32, 0), prog.insts[2].jmp);
    try testing.expectEqual({}, prog.insts[3].match);
}

test "compile a+ emits char + split{L0,after} + match" {
    var prog = try compile(testing.allocator, "a+", .{});
    defer prog.deinit(testing.allocator);
    // Layout: 0 char 'a', 1 split{0,2}, 2 match — body before after for greedy.
    try testing.expectEqual(@as(usize, 3), prog.insts.len);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[0].char);
    try testing.expectEqual(@as(u32, 0), prog.insts[1].split.a);
    try testing.expectEqual(@as(u32, 2), prog.insts[1].split.b);
    try testing.expectEqual({}, prog.insts[2].match);
}

test "compile a? emits split{1,2} + char + match" {
    var prog = try compile(testing.allocator, "a?", .{});
    defer prog.deinit(testing.allocator);
    // Layout: 0 split{1,2}, 1 char 'a', 2 match
    try testing.expectEqual(@as(usize, 3), prog.insts.len);
    try testing.expectEqual(@as(u32, 1), prog.insts[0].split.a);
    try testing.expectEqual(@as(u32, 2), prog.insts[0].split.b);
    try testing.expectEqual(@as(u8, 'a'), prog.insts[1].char);
    try testing.expectEqual({}, prog.insts[2].match);
}

test "isMetaChar covers the cycle-1 + future metachar set" {
    try testing.expect(isMetaChar('.'));
    try testing.expect(isMetaChar('*'));
    try testing.expect(isMetaChar('+'));
    try testing.expect(isMetaChar('?'));
    try testing.expect(isMetaChar('('));
    try testing.expect(isMetaChar(')'));
    try testing.expect(isMetaChar('['));
    try testing.expect(isMetaChar(']'));
    try testing.expect(isMetaChar('|'));
    try testing.expect(isMetaChar('\\'));
    try testing.expect(isMetaChar('^'));
    try testing.expect(isMetaChar('$'));
    try testing.expect(isMetaChar('{'));
    try testing.expect(isMetaChar('}'));
    try testing.expect(!isMetaChar('a'));
    try testing.expect(!isMetaChar('1'));
    try testing.expect(!isMetaChar(' '));
}

test "compile \\d emits class[0-9] + match" {
    var prog = try compile(testing.allocator, "\\d", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), prog.insts.len);
    const cls = prog.insts[0].class;
    try testing.expect(cls.contains('0'));
    try testing.expect(cls.contains('9'));
    try testing.expect(!cls.contains('a'));
    try testing.expect(!cls.contains(' '));
}

test "compile \\D is the negation of \\d" {
    var prog = try compile(testing.allocator, "\\D", .{});
    defer prog.deinit(testing.allocator);
    const cls = prog.insts[0].class;
    try testing.expect(!cls.contains('0'));
    try testing.expect(cls.contains('a'));
    try testing.expect(cls.contains(' '));
}

test "compile [abc] emits the literal set bitmap" {
    var prog = try compile(testing.allocator, "[abc]", .{});
    defer prog.deinit(testing.allocator);
    const cls = prog.insts[0].class;
    try testing.expect(cls.contains('a'));
    try testing.expect(cls.contains('b'));
    try testing.expect(cls.contains('c'));
    try testing.expect(!cls.contains('d'));
}

test "compile [a-z] emits the range bitmap" {
    var prog = try compile(testing.allocator, "[a-z]", .{});
    defer prog.deinit(testing.allocator);
    const cls = prog.insts[0].class;
    var b: u16 = 'a';
    while (b <= 'z') : (b += 1) try testing.expect(cls.contains(@intCast(b)));
    try testing.expect(!cls.contains('A'));
    try testing.expect(!cls.contains('0'));
}

test "compile [^abc] negates the literal set" {
    var prog = try compile(testing.allocator, "[^abc]", .{});
    defer prog.deinit(testing.allocator);
    const cls = prog.insts[0].class;
    try testing.expect(!cls.contains('a'));
    try testing.expect(!cls.contains('c'));
    try testing.expect(cls.contains('d'));
    try testing.expect(cls.contains('0'));
}

test "compile [\\d] uses the escape's bitmap inside the class" {
    var prog = try compile(testing.allocator, "[\\d]", .{});
    defer prog.deinit(testing.allocator);
    const cls = prog.insts[0].class;
    try testing.expect(cls.contains('5'));
    try testing.expect(!cls.contains('x'));
}

test "compile \\. emits literal dot, not the all-set class" {
    var prog = try compile(testing.allocator, "\\.", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, '.'), prog.insts[0].char);
}

test "compile rejects bad escape" {
    try testing.expectError(CompileError.InvalidEscape, compile(testing.allocator, "\\q", .{}));
}

test "compile rejects reversed range" {
    try testing.expectError(CompileError.InvalidQuantifier, compile(testing.allocator, "[z-a]", .{}));
}

test "compile rejects unclosed class" {
    try testing.expectError(CompileError.UnclosedClass, compile(testing.allocator, "[abc", .{}));
}

test "CharClass set / contains is bit-exact" {
    var cls: CharClass = .{};
    cls.set('a');
    cls.set('z');
    try testing.expect(cls.contains('a'));
    try testing.expect(cls.contains('z'));
    try testing.expect(!cls.contains('b'));
    try testing.expect(!cls.contains(0));
    try testing.expect(!cls.contains(255));
}
