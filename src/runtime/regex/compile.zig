// SPDX-License-Identifier: EPL-2.0
//! Regex compile pipeline (parser + AST + IR) — namespace-neutral
//! implementation per F-009.
//!
//! Implements ADR-0031 Alternative 2 (Pike-NFA `Program` IR). This
//! module owns the parser → AST → `Program` IR pipeline. The matcher
//! lives in `match.zig` (Pike VM). The lazy-DFA fast path reserved by
//! ADR-0031 was never built (no `dfa.zig`).
//!
//! Two surfaces consume this file:
//!   1. `lang/primitive/regex.zig` — Clojure-ns peer (`re-pattern`
//!      / `re-find` / `re-matches` / `re-seq` / `re-groups` in
//!      clojure.core).
//!   2. `runtime/java/util/regex/Pattern.zig` — Java surface
//!      (`(java.util.regex.Pattern/compile ...)` etc.).
//!
//! Supported: literal bytes, `.` wildcard, concatenation,
//! alternation `|`, greedy quantifiers `*` / `+` / `?`, bounded
//! `{n,m}`, character classes `[...]`, escapes (`\d \w \s` etc.),
//! anchors (`^ $ \b \B`), capture + non-capturing groups, and the
//! inline flags `(?i) (?m) (?s)` plus `\Q...\E` and POSIX
//! `\p{Alpha}`-style classes. Not supported: named groups,
//! lookaround, and Unicode category `\p{L}` / script names.

const std = @import("std");

/// Compile flags. `(?i)` inline modifier rewrites at compile
/// time into case-folded character classes; the runtime sees only
/// the folded form.
pub const Flags = packed struct(u8) {
    case_insensitive: bool = false,
    /// `(?s)` DOTALL — `.` matches every byte incl. `\n`/`\r`. Default off:
    /// `.` excludes `\n`/`\r` (Java line terminators), built at parse time.
    dotall: bool = false,
    /// `(?m)` MULTILINE — `^`/`$` also match at embedded line boundaries.
    /// Encoded into `line_start_multi`/`line_end_multi` anchors at parse time,
    /// so this flag is informational once compiled (the variant carries it).
    multiline: bool = false,
    _pad: u5 = 0,
};

/// Parsed AST node. The parser produces this tree; the IR
/// emitter walks it to populate `Program.insts`.
/// Sentinel `max` for an unbounded `{n,}` repeat (`.repeat.max == REPEAT_INF`
/// ⇒ `n` mandatory copies followed by `*`).
pub const REPEAT_INF: u16 = std.math.maxInt(u16);

/// Upper bound on a compiled program's instruction count. Legitimate patterns
/// sit well under ~10^3 insts; this 100k cap leaves ~100× headroom while
/// blocking the nested-counted-repetition compile-bomb on untrusted
/// `(re-pattern …)` input: `(a{n}){m}` expands to n·m insts inline, so
/// `(a{65535}){65535}` would emit ~4.3e9 insts → multi-GB OOM (INV-1, measured
/// 1 GB at `(a{5000}){5000}`). The Pike-NFA matcher is already ReDoS-immune for
/// untrusted *input*; this guards the compile side against untrusted *patterns*.
pub const MAX_PROGRAM_INSTS: usize = 100_000;

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
    /// Zero-width lookahead `(?=e)` (negate=false) / `(?!e)` (negate=true). The
    /// child is matched anchored at the current position and consumes nothing; a
    /// POSITIVE lookahead's inner captures thread through (JVM parity, ADR-0115).
    look: struct { child: *Node, negate: bool },
};

/// Character-class bitmap: 256 bits over the byte alphabet.
/// ASCII-only: POSIX `\p{Alpha}`-style names are supported, but
/// Unicode category `\p{L}` / script names are not.
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
    /// `(?m)` MULTILINE variants: `^`/`$` also match at embedded line
    /// boundaries (after / before a line terminator), not just input ends.
    line_start_multi,
    line_end_multi,
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
    /// Zero-width lookahead: run `sub` (its own Program, terminated by `.match`)
    /// anchored at the current position; the thread continues (consuming nothing)
    /// iff a match exists XOR `negate`. A positive lookahead merges `sub`'s
    /// captures into the continuing thread (ADR-0115); a negative one exports none.
    look: struct { sub: []const Inst, negate: bool },
};

/// Compiled program — the IR boundary between parser/optimiser
/// and the runtime matcher (NFA / DFA). Lifetime equals the
/// `Pattern` Value that owns it.
pub const Program = struct {
    insts: []const Inst,
    capture_count: u16,
    flags: Flags,

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        // A `look` inst owns a nested sub-Program's IR slice (lookahead); free it
        // before the top-level slice (recursive for nested lookaheads).
        for (self.insts) |inst| {
            if (inst == .look) {
                var sub = Program{ .insts = inst.look.sub, .capture_count = 0, .flags = self.flags };
                sub.deinit(alloc);
            }
        }
        alloc.free(self.insts);
    }
};

pub const CompileError = error{
    /// Pattern source uses a feature that is recognised but not
    /// implemented: named groups, lookaround, Unicode category
    /// `\\p{L}` / script names, the `(?x)` extended / `(?m)`-only
    /// mid-pattern flag forms, more than 8 capture groups, and an
    /// escaped range endpoint inside `[...]`. Per
    /// `no_op_stub_forbidden`, the error is explicit, not silent.
    NotImplemented,

    /// Parser-level syntax error: stray metacharacter, dangling
    /// quantifier, etc. Replaces JVM's `PatternSyntaxException`
    /// (cljw reports its own message, not the JVM exception).
    UnexpectedToken,
    UnclosedGroup,
    UnclosedClass,
    InvalidQuantifier,
    InvalidEscape,

    /// The compiled program would exceed `MAX_PROGRAM_INSTS` instructions —
    /// almost always a nested counted repetition (`(a{n}){m}` → n·m insts) on
    /// untrusted pattern input. Rejected as a clean catchable error instead of
    /// an OOM (INV-1); the matcher is Pike-NFA / ReDoS-immune, so only the
    /// compile side needs this bound.
    PatternTooLarge,
} || std.mem.Allocator.Error;

/// Compile a regex pattern source into a `Program`. Caller owns
/// the resulting `Program` and must call `Program.deinit` to
/// free the IR slice.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Program {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var f = flags;
    var pat = pattern;
    // Leading `(?flags)` (flags ⊆ {i,s}) — clj applies them to the whole pattern.
    // `i` → compile-time case-fold (foldCI); `s` → DOTALL (parse-time `.` build).
    // A `:` before `)` means a scoped group `(?i:…)`, NOT a leading flag — leave
    // it for the group parser. Other flags (m/x) and mid-pattern flags stay
    // unsupported (clean parse error).
    if (pat.len >= 4 and pat[0] == '(' and pat[1] == '?') {
        var j: usize = 2;
        var ci = false;
        var da = false;
        var ml = false;
        var only_flags = true;
        while (j < pat.len and pat[j] != ')' and pat[j] != ':') : (j += 1) {
            switch (pat[j]) {
                'i' => ci = true,
                's' => da = true,
                'm' => ml = true,
                else => {
                    only_flags = false;
                    break;
                },
            }
        }
        if (only_flags and j > 2 and j < pat.len and pat[j] == ')') {
            f.case_insensitive = f.case_insensitive or ci;
            f.dotall = f.dotall or da;
            f.multiline = f.multiline or ml;
            pat = pat[j + 1 ..];
        }
    }
    var group_count: u16 = 0;
    const node = try parsePattern(arena.allocator(), pat, f, &group_count);
    if (f.case_insensitive) foldCI(@constCast(node));
    return try emit(alloc, node, f, group_count);
}

/// ASCII case-swap (`a`↔`A`); non-letters unchanged.
fn asciiSwapCase(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// For every ASCII letter set in the class, also set its other case.
fn foldClassBits(cls: *CharClass) void {
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) {
        if (cls.contains(c)) cls.set(c - 32);
        if (cls.contains(c - 32)) cls.set(c);
    }
}

/// Case-insensitive AST fold (cycle-4 `(?i)`): a `lit` letter becomes a
/// 2-element class `{c, swapcase(c)}`; a `class` gains each letter's other
/// case. Mutates the arena-owned AST in place; recurses into all children.
fn foldCI(node: *Node) void {
    switch (node.*) {
        .lit => |c| {
            const s = asciiSwapCase(c);
            if (s != c) {
                var cc = CharClass{};
                cc.set(c);
                cc.set(s);
                node.* = .{ .class = cc };
            }
        },
        .class => |*cls| foldClassBits(cls),
        .anchor => {},
        .concat => |children| for (children) |*ch| foldCI(ch),
        .alt => |children| for (children) |*ch| foldCI(ch),
        .star => |child| foldCI(child),
        .plus => |child| foldCI(child),
        .quest => |child| foldCI(child),
        .non_capture => |child| foldCI(child),
        .group => |g| foldCI(g.child),
        .repeat => |r| foldCI(r.child),
        .look => |lk| foldCI(lk.child),
    }
}

/// Recursive-descent parser entry: produces an AST `Node` tree
/// into the supplied arena allocator.
///
/// Grammar (core subset; groups / anchors / `{n,m}` / inline flags
/// also parse — see the module-level supported-features list):
///
/// ```text
/// pattern := alt
/// alt     := concat ('|' concat)*
/// concat  := quant+                       -- empty branches reject
/// quant   := atom ('*' | '+' | '?')?
/// atom    := '.' | char_class | escape | literal_byte
/// char_class := '[' '^'? class_item+ ']'
/// class_item := escape | byte ('-' byte)?
/// escape  := '\' ('d'|'D'|'w'|'W'|'s'|'S'|'t'|'n'|'r'|'f'|meta_byte)
/// ```
pub fn parsePattern(arena: std.mem.Allocator, pattern: []const u8, flags: Flags, group_count_out: *u16) CompileError!*const Node {
    if (pattern.len == 0) {
        // `#""` / `(re-pattern "")` — an empty pattern matches the empty string
        // at every position (clj parity). An empty `.concat` emits no insts, so
        // `emit` produces just the trailing `.match`.
        const node = try arena.create(Node);
        node.* = .{ .concat = &.{} };
        group_count_out.* = 0;
        return node;
    }
    var parser: Parser = .{ .src = pattern, .pos = 0, .arena = arena, .dotall = flags.dotall, .multiline = flags.multiline };
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
    /// DOTALL scope (`(?s)` / `(?s:…)`): when true, `.` matches `\n`/`\r` too.
    dotall: bool = false,
    /// MULTILINE scope (`(?m)` / `(?m:…)`): when true, `^`/`$` build their
    /// embedded-line-boundary anchor variants.
    multiline: bool = false,

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
            node.* = atomFor('.', self.dotall);
            return node;
        }
        if (c == '[') {
            node.* = .{ .class = try self.parseCharClass() };
            return node;
        }
        if (c == '\\') {
            // `\Q…\E` quote block: every byte until `\E` (or end-of-pattern,
            // which Java tolerates) is a literal, metacharacters included.
            // Emitted as a `.concat` of `.lit` nodes.
            if (self.peek() == @as(?u8, 'Q')) {
                _ = self.advance(); // consume 'Q'
                var lits: std.ArrayList(Node) = .empty;
                while (self.advance()) |lc| {
                    if (lc == '\\' and self.peek() == @as(?u8, 'E')) {
                        _ = self.advance(); // consume 'E'
                        break;
                    }
                    try lits.append(self.arena, .{ .lit = lc });
                }
                node.* = .{ .concat = try lits.toOwnedSlice(self.arena) };
                return node;
            }
            node.* = try self.parseEscape();
            return node;
        }
        if (c == '^') {
            node.* = .{ .anchor = if (self.multiline) .line_start_multi else .line_start };
            return node;
        }
        if (c == '$') {
            node.* = .{ .anchor = if (self.multiline) .line_end_multi else .line_end };
            return node;
        }
        if (c == '(') {
            // `(?:e)` non-capturing, `(?is:e)` scoped case-insensitive / DOTALL,
            // `(e)` capturing. Lookaround / named groups / other inline flags
            // (m/x) and the flag-only mid-pattern `(?i)` form stay NotImplemented.
            var capturing = true;
            var idx: u16 = 0;
            var fold_i = false;
            var scoped_dotall = false;
            var scoped_multi = false;
            if (self.peek() == @as(?u8, '?')) {
                _ = self.advance(); // consume '?'
                capturing = false;
                // Lookahead `(?=e)` / `(?!e)` — a zero-width assertion, NOT a
                // group. Parse the child + the closing `)`, build `Node.look`.
                if (self.peek() == @as(?u8, '=') or self.peek() == @as(?u8, '!')) {
                    const negate = self.advance().? == '!';
                    const look_child = try self.parseAlt();
                    if (self.advance() != @as(?u8, ')')) return CompileError.UnclosedGroup;
                    node.* = .{ .look = .{ .child = look_child, .negate = negate } };
                    return node;
                }
                if (self.peek() == @as(?u8, ':')) {
                    _ = self.advance();
                } else {
                    // Inline-flag group `(?ism:…)`: flags run until ':'. `i` folds
                    // the subtree case-insensitive (foldCI); `s` sets DOTALL; `m`
                    // sets MULTILINE — all reuse the leading-flag machinery,
                    // scoped to this child. x stays unsupported.
                    while (true) {
                        const f = self.advance() orelse return CompileError.NotImplemented;
                        if (f == ':') break;
                        switch (f) {
                            'i' => fold_i = true,
                            's' => scoped_dotall = true,
                            'm' => scoped_multi = true,
                            else => return CompileError.NotImplemented,
                        }
                    }
                }
            } else {
                self.group_count += 1;
                idx = self.group_count;
                if (idx >= 8) return CompileError.NotImplemented; // MAX_SLOTS_INLINE/2
            }
            // DOTALL / MULTILINE are parse-time (the `.` bitmap and `^`/`$`
            // anchor variants are built during the child parse), so set them for
            // the child and restore — scoped to this group.
            const saved_dotall = self.dotall;
            const saved_multi = self.multiline;
            if (scoped_dotall) self.dotall = true;
            if (scoped_multi) self.multiline = true;
            const child = try self.parseAlt();
            self.dotall = saved_dotall;
            self.multiline = saved_multi;
            if (self.advance() != @as(?u8, ')')) return CompileError.UnclosedGroup;
            if (fold_i) foldCI(child);
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
            // Empty class `[]` / `[^]` — unsupported. JVM treats
            // `[]` as a syntax error and `[^]` as "anything",
            // neither of which is needed.
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
                // Escaped range endpoint (e.g. `[a-\d]`) unsupported.
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
            // POSIX named classes `\p{Alpha}` / negated `\P{Alpha}` (ASCII —
            // Java's POSIX `\p{…}` set is ASCII by definition, so exact parity).
            // Routed through here so they also work inside `[…]` (parseCharClass
            // ORs the `.class` payload). Unicode category names (`\p{L}`, scripts)
            // stay NotImplemented — honest staging, not a silent ASCII fallback.
            'p' => .{ .class = try self.parsePosixClass(false) },
            'P' => .{ .class = try self.parsePosixClass(true) },
            '.', '*', '+', '?', '(', ')', '[', ']', '|', '\\', '^', '$', '{', '}', '/' => .{ .lit = c },
            else => CompileError.InvalidEscape,
        };
    }

    /// Parse the `{Name}` after `\p` / `\P` and return the matching POSIX
    /// character class (negated when `negate`). Unknown / Unicode-only names
    /// raise NotImplemented (kept unsupported rather than silently wrong).
    fn parsePosixClass(self: *Parser, negate: bool) CompileError!CharClass {
        if ((self.advance() orelse return CompileError.InvalidEscape) != '{') return CompileError.InvalidEscape;
        const start = self.pos;
        while (true) {
            const ch = self.advance() orelse return CompileError.UnexpectedToken;
            if (ch == '}') break;
        }
        const name = self.src[start .. self.pos - 1];
        const cls = posixClass(name) orelse return CompileError.NotImplemented;
        return if (negate) negateClass(cls) else cls;
    }
};

/// Build a CharClass from a list of inclusive `[lo, hi]` byte ranges.
fn classRanges(ranges: []const [2]u8) CharClass {
    var cls: CharClass = .{};
    for (ranges) |r| {
        var b: u16 = r[0];
        while (b <= r[1]) : (b += 1) cls.set(@intCast(b));
    }
    return cls;
}

/// Java `\p{Punct}` — the ASCII punctuation set (`!"#$%&'()*+,-./:;<=>?@[\]^_` +
/// "`{|}~"`), expressed as four contiguous ASCII ranges.
fn punctClass() CharClass {
    return classRanges(&.{ .{ 0x21, 0x2F }, .{ 0x3A, 0x40 }, .{ 0x5B, 0x60 }, .{ 0x7B, 0x7E } });
}

/// POSIX class name → ASCII CharClass (Java `java.util.regex` POSIX subset).
/// Returns null for unknown / Unicode-only names (e.g. `L`, `IsAlphabetic`).
fn posixClass(name: []const u8) ?CharClass {
    const eql = std.mem.eql;
    if (eql(u8, name, "Alpha")) return classRanges(&.{ .{ 'a', 'z' }, .{ 'A', 'Z' } });
    if (eql(u8, name, "Digit")) return classRanges(&.{.{ '0', '9' }});
    if (eql(u8, name, "Alnum")) return classRanges(&.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' } });
    if (eql(u8, name, "Upper")) return classRanges(&.{.{ 'A', 'Z' }});
    if (eql(u8, name, "Lower")) return classRanges(&.{.{ 'a', 'z' }});
    if (eql(u8, name, "XDigit")) return classRanges(&.{ .{ '0', '9' }, .{ 'a', 'f' }, .{ 'A', 'F' } });
    // Java `\p{Space}` = `[ \t\n\x0B\f\r]` = space + bytes 9..13.
    if (eql(u8, name, "Space")) return classRanges(&.{ .{ ' ', ' ' }, .{ 9, 13 } });
    if (eql(u8, name, "Blank")) return classRanges(&.{ .{ ' ', ' ' }, .{ '\t', '\t' } });
    if (eql(u8, name, "Cntrl")) return classRanges(&.{ .{ 0, 0x1F }, .{ 0x7F, 0x7F } });
    if (eql(u8, name, "Print")) return classRanges(&.{.{ 0x20, 0x7E }});
    if (eql(u8, name, "Graph")) return classRanges(&.{.{ 0x21, 0x7E }});
    if (eql(u8, name, "Punct")) return punctClass();
    if (eql(u8, name, "ASCII")) return classRanges(&.{.{ 0, 0x7F }});
    return null;
}

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
    cls.set(11); // vertical tab — Java `\s` is `[ \t\n\x0B\f\r]` (was omitted)
    cls.set('\r');
    cls.set(12); // form feed
    return cls;
}

fn negateClass(c: CharClass) CharClass {
    var out: CharClass = .{};
    for (0..c.bits.len) |i| out.bits[i] = ~c.bits[i];
    return out;
}

/// Atom builder: literal byte, or `.` -> character class. JVM `.` excludes the
/// line terminators `\n`/`\r` by default; `(?s)` DOTALL (`dotall=true`) makes it
/// match every byte. (Java also excludes U+0085 / U+2028 / U+2029, non-ASCII and
/// out of scope for this byte-level engine.)
fn atomFor(c: u8, dotall: bool) Node {
    if (c == '.') {
        var cls: CharClass = .{};
        for (0..256) |b| {
            if (!dotall and (b == '\n' or b == '\r')) continue;
            cls.set(@intCast(b));
        }
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
    // Compile-bomb guard (INV-1): every node's instructions flow through here
    // (children recurse, counted reps loop over emitNode), so a single check at
    // entry bounds total program size. A nested `(a{n}){m}` trips this once its
    // running expansion crosses the cap, instead of OOMing the process.
    if (list.items.len > MAX_PROGRAM_INSTS) return CompileError.PatternTooLarge;
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
        // Lookahead: compile the child to its own sub-Program (terminated by
        // `.match`, capture-free) and emit a single zero-width `look` inst.
        .look => |lk| {
            const sub = try emit(alloc, lk.child, .{}, 0);
            try list.append(alloc, .{ .look = .{ .sub = sub.insts, .negate = lk.negate } });
        },
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

test "compile \\Q.*\\E emits literal bytes, not metacharacters" {
    // Inside \Q…\E every byte is a literal: `.` and `*` become char insts,
    // not the all-set class / a quantifier loop.
    var prog = try compile(testing.allocator, "\\Q.*\\E", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, '.'), prog.insts[0].char);
    try testing.expectEqual(@as(u8, '*'), prog.insts[1].char);
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

test "posixClass builds ASCII bitmaps (Alpha/Digit/Space/Punct)" {
    const alpha = posixClass("Alpha").?;
    try testing.expect(alpha.contains('a') and alpha.contains('Z') and !alpha.contains('0'));
    const digit = posixClass("Digit").?;
    try testing.expect(digit.contains('5') and !digit.contains('a'));
    // Space includes the vertical tab (0x0B) — Java `\p{Space}` / `\s`.
    const space = posixClass("Space").?;
    try testing.expect(space.contains(' ') and space.contains(11) and space.contains('\t') and !space.contains('x'));
    const punct = posixClass("Punct").?;
    try testing.expect(punct.contains('!') and punct.contains('~') and !punct.contains('a') and !punct.contains('0'));
    // Unicode / unknown names are not POSIX → null (kept unsupported upstream).
    try testing.expect(posixClass("L") == null);
    try testing.expect(posixClass("Bogus") == null);
}

test "compile \\p{Alpha} ok; \\P negates; Unicode name → NotImplemented" {
    const alloc = testing.allocator;
    {
        var prog = try compile(alloc, "\\p{Alpha}+", .{});
        defer prog.deinit(alloc);
    }
    {
        var prog = try compile(alloc, "[\\p{Digit}_]", .{}); // works inside a class
        defer prog.deinit(alloc);
    }
    try testing.expectError(CompileError.NotImplemented, compile(alloc, "\\p{L}", .{}));
}

test "\\s whitespace class includes vertical tab (0x0B)" {
    const ws = whitespaceClass();
    try testing.expect(ws.contains(' ') and ws.contains('\t') and ws.contains('\n') and ws.contains(11) and ws.contains('\r') and ws.contains(12));
}

test "(?i:...) scoped flag folds only the subtree; surrounding stays sensitive" {
    const alloc = testing.allocator;
    // Scoped fold does NOT set the program-wide flag (only the leading form does).
    {
        var prog = try compile(alloc, "(?i:ab)c", .{});
        defer prog.deinit(alloc);
        try testing.expect(!prog.flags.case_insensitive);
    }
    // `(?:…)` (no flags) and the flag-only `(?i)` form behave as before.
    {
        var prog = try compile(alloc, "(?:ab)c", .{});
        defer prog.deinit(alloc);
    }
    // Unsupported inline flags (m/x) / mid-pattern flag-only stay NotImplemented.
    // (`(?s:…)` is now supported — see the DOTALL test below.)
    try testing.expectError(CompileError.NotImplemented, compile(alloc, "(?x:ab)", .{}));
    try testing.expectError(CompileError.NotImplemented, compile(alloc, "a(?i)b", .{}));
}

test "dot excludes newline/CR by default; (?s) DOTALL includes them" {
    const alloc = testing.allocator;
    // Default `.` class: every byte EXCEPT \n (10) and \r (13).
    {
        const dot = atomFor('.', false).class;
        try testing.expect(dot.contains('a') and dot.contains(11) and dot.contains(12));
        try testing.expect(!dot.contains('\n') and !dot.contains('\r'));
    }
    // DOTALL `.`: every byte.
    {
        const dot = atomFor('.', true).class;
        try testing.expect(dot.contains('\n') and dot.contains('\r') and dot.contains('a'));
    }
    // Leading `(?s)` and scoped `(?s:…)` both compile; `(?si)`/`(?is)` combine.
    inline for (.{ "(?s)a.b", "a(?s:.)b", "(?is:A.B)" }) |p| {
        var prog = try compile(alloc, p, .{});
        defer prog.deinit(alloc);
    }
}

test "(?m) MULTILINE builds line_*_multi anchors; default builds line_*" {
    const alloc = testing.allocator;
    // Default `^`/`$` → whole-input anchors.
    {
        var prog = try compile(alloc, "^a$", .{});
        defer prog.deinit(alloc);
        try testing.expect(prog.insts[0].anchor == .line_start);
    }
    // `(?m)` and scoped `(?m:…)` → multi anchors; `(?im)` combines with fold.
    inline for (.{ "(?m)^a$", "a(?m:^b)", "(?im)^a" }) |p| {
        var prog = try compile(alloc, p, .{});
        defer prog.deinit(alloc);
    }
    {
        var prog = try compile(alloc, "(?m)^a", .{});
        defer prog.deinit(alloc);
        try testing.expect(prog.insts[0].anchor == .line_start_multi);
    }
}

test "(?i) leading flag folds literal + class to case-insensitive" {
    const alloc = testing.allocator;
    // `(?i)Ab` → both `a/A` and `b/B` match (lit folded to a class).
    {
        var prog = try compile(alloc, "(?i)Ab", .{});
        defer prog.deinit(alloc);
        try testing.expect(prog.flags.case_insensitive);
    }
    // foldClassBits mirrors each ASCII letter's other case.
    {
        var cc: CharClass = .{};
        cc.set('a');
        cc.set('Z');
        foldClassBits(&cc);
        try testing.expect(cc.contains('A'));
        try testing.expect(cc.contains('z'));
        // a non-letter set bit is untouched, and unrelated letters stay unset.
        try testing.expect(!cc.contains('b'));
    }
    try testing.expectEqual(@as(u8, 'A'), asciiSwapCase('a'));
    try testing.expectEqual(@as(u8, 'a'), asciiSwapCase('A'));
    try testing.expectEqual(@as(u8, '5'), asciiSwapCase('5'));
}

// INV-1: nested counted repetition `(a{n}){m}` expands to n·m instructions
// inline (emitNode duplicates the child per copy). On untrusted PATTERN input
// (`(re-pattern user-string)`) this is a compile-bomb: `(a{65535}){65535}` would
// emit ~4.3e9 insts → multi-GB OOM. The matcher itself is Pike-NFA / ReDoS-immune;
// this is the pattern-compile-side resource guard. MAX_PROGRAM_INSTS caps the
// program size so an over-large pattern is a clean catchable error, not an OOM.
test "INV-1: oversized program rejected with PatternTooLarge, not OOM" {
    const alloc = testing.allocator;
    // (a{400}){400} = 160_000 insts, over the 100k cap → rejected fast + light.
    try testing.expectError(error.PatternTooLarge, compile(alloc, "(a{400}){400}", .{}));
}

test "INV-1: a large-but-under-cap pattern still compiles" {
    const alloc = testing.allocator;
    // (a{300}){300} = 90_000 insts, under the 100k cap → compiles fine (no
    // false-positive on a legitimately large bounded repetition).
    var prog = try compile(alloc, "(a{300}){300}", .{});
    defer prog.deinit(alloc);
    try testing.expect(prog.insts.len > 80_000);
}
