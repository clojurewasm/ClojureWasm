// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Regex parser — parses regex pattern strings into RegexNode AST.
// Java regex compatible syntax (ASCII based).
//
// Grammar:
//   regex      := alternation
//   alternation := sequence ('|' sequence)*
//   sequence   := quantified*
//   quantified := atom quantifier?
//   atom       := literal | '.' | char_class | group | escape | anchor
//   quantifier := ('*'|'+'|'?'|'{n}'|'{n,}'|'{n,m}') '?'?
//   char_class := '[' '^'? (range | char)+ ']'
//   group      := '(' ('?:' | '?=' | '?!' | '?i' | '?m' | '?s')? regex ')'
//   escape     := '\' (d|D|w|W|s|S|b|B|digit|metachar)

const std = @import("std");

/// Compiled regular expression
pub const CompiledRegex = struct {
    nodes: []const RegexNode,
    group_count: u16,
    flags: Flags,
    source: []const u8,
};

/// Regex flags
pub const Flags = struct {
    case_insensitive: bool = false, // (?i)
    multiline: bool = false, // (?m): ^ $ match line boundaries
    dotall: bool = false, // (?s): . matches \n

    pub const empty: Flags = .{};
};

/// Character range
pub const CharRange = struct {
    start: u8,
    end: u8,
};

/// Character class
pub const CharClass = struct {
    ranges: []const CharRange,
    singles: []const u8,
    negated: bool,
};

/// Predefined character class
pub const Predefined = enum {
    digit, // \d = [0-9]
    non_digit, // \D = [^0-9]
    word, // \w = [a-zA-Z0-9_]
    non_word, // \W = [^a-zA-Z0-9_]
    whitespace, // \s = [ \t\n\r\f]
    non_whitespace, // \S = [^ \t\n\r\f]
};

/// Anchor type
pub const Anchor = enum {
    start, // ^
    end, // $
    word_boundary, // \b
    non_word_boundary, // \B
};

/// Group kind
pub const GroupKind = enum {
    capturing, // (...)
    non_capturing, // (?:...)
    lookahead, // (?=...)
    negative_lookahead, // (?!...)
    flag_group, // (?i), (?m), (?s) — flag setting only
};

/// Group
pub const Group = struct {
    kind: GroupKind,
    children: []const RegexNode,
    capture_index: u16, // capturing group index (0 = unused)
    flags: ?Flags, // set for flag_group
};

/// Alternation
pub const Alternation = struct {
    alternatives: []const []const RegexNode,
};

/// Quantifier
pub const Quantifier = struct {
    child: *const RegexNode,
    min: u32,
    max: ?u32, // null = unbounded
    greedy: bool,
};

/// Regex AST node
pub const RegexNode = union(enum) {
    literal: u8, // 'a'
    dot, // .
    char_class: CharClass, // [abc], [a-z], [^abc]
    predefined: Predefined, // \d, \D, \w, \W, \s, \S
    anchor: Anchor, // ^, $, \b, \B
    group: Group, // (...), (?:...)
    alternation: Alternation, // a|b
    quantifier: Quantifier, // *, +, ?, {n,m}
    backreference: u16, // \1, \2
    sequence: []const RegexNode, // concatenation
};

/// Parser error
pub const ParseError = error{
    InvalidEscape,
    UnterminatedCharClass,
    UnterminatedGroup,
    InvalidQuantifier,
    InvalidBackreference,
    EmptyPattern,
    OutOfMemory,
    NothingToRepeat,
    InvalidFlag,
    UnterminatedRepetition,
};

/// Regex parser (recursive descent)
pub const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    group_count: u16,
    flags: Flags,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
            .group_count = 0,
            .flags = .{},
        };
    }

    /// Parse and return a compiled regex
    pub fn parse(self: *Parser) ParseError!CompiledRegex {
        const nodes = try self.parseAlternation();
        return .{
            .nodes = nodes,
            .group_count = self.group_count,
            .flags = self.flags,
            .source = self.source,
        };
    }

    // === Recursive descent parser ===

    /// alternation := sequence ('|' sequence)*
    fn parseAlternation(self: *Parser) ParseError![]const RegexNode {
        const first = try self.parseSequence();

        if (!self.isEof() and self.peek() == '|') {
            var alts: std.ArrayList([]const RegexNode) = .empty;
            alts.append(self.allocator, first) catch return error.OutOfMemory;

            while (!self.isEof() and self.peek() == '|') {
                self.advance();
                const alt = try self.parseSequence();
                alts.append(self.allocator, alt) catch return error.OutOfMemory;
            }

            const node = self.allocator.create(RegexNode) catch return error.OutOfMemory;
            node.* = .{ .alternation = .{
                .alternatives = alts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } };

            const result = self.allocator.alloc(RegexNode, 1) catch return error.OutOfMemory;
            result[0] = node.*;
            return result;
        }

        return first;
    }

    /// sequence := quantified*
    fn parseSequence(self: *Parser) ParseError![]const RegexNode {
        var nodes: std.ArrayList(RegexNode) = .empty;

        while (!self.isEof()) {
            const c = self.peek();
            if (c == ')' or c == '|') break;

            const node = try self.parseQuantified();
            nodes.append(self.allocator, node) catch return error.OutOfMemory;
        }

        return nodes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// quantified := atom quantifier?
    fn parseQuantified(self: *Parser) ParseError!RegexNode {
        var atom = try self.parseAtom();

        if (!self.isEof()) {
            const c = self.peek();
            if (c == '*' or c == '+' or c == '?' or c == '{') {
                atom = try self.parseQuantifier(atom);
            }
        }

        return atom;
    }

    /// Parse quantifier
    fn parseQuantifier(self: *Parser, child_node: RegexNode) ParseError!RegexNode {
        const c = self.peek();
        self.advance();

        var min: u32 = 0;
        var max: ?u32 = null;

        switch (c) {
            '*' => {
                min = 0;
                max = null;
            },
            '+' => {
                min = 1;
                max = null;
            },
            '?' => {
                min = 0;
                max = 1;
            },
            '{' => {
                const result = try self.parseRepetition();
                min = result.min;
                max = result.max;
            },
            else => unreachable,
        }

        // Non-greedy '?'
        var greedy = true;
        if (!self.isEof() and self.peek() == '?') {
            greedy = false;
            self.advance();
        }

        const child = self.allocator.create(RegexNode) catch return error.OutOfMemory;
        child.* = child_node;

        return .{ .quantifier = .{
            .child = child,
            .min = min,
            .max = max,
            .greedy = greedy,
        } };
    }

    /// Parse {n}, {n,}, {n,m}
    fn parseRepetition(self: *Parser) ParseError!struct { min: u32, max: ?u32 } {
        var min: u32 = 0;
        var max: ?u32 = null;

        min = try self.parseRepNumber();

        if (self.isEof()) return error.UnterminatedRepetition;

        if (self.peek() == '}') {
            self.advance();
            max = min;
            return .{ .min = min, .max = max };
        }

        if (self.peek() != ',') return error.InvalidQuantifier;
        self.advance();

        if (self.isEof()) return error.UnterminatedRepetition;

        if (self.peek() == '}') {
            self.advance();
            max = null;
            return .{ .min = min, .max = max };
        }

        max = try self.parseRepNumber();
        if (self.isEof() or self.peek() != '}') return error.UnterminatedRepetition;
        self.advance();

        return .{ .min = min, .max = max };
    }

    /// Parse repetition count number
    fn parseRepNumber(self: *Parser) ParseError!u32 {
        var n: u32 = 0;
        var found = false;
        while (!self.isEof() and self.peek() >= '0' and self.peek() <= '9') {
            n = n * 10 + @as(u32, self.peek() - '0');
            self.advance();
            found = true;
        }
        if (!found) return error.InvalidQuantifier;
        return n;
    }

    /// Parse atom
    fn parseAtom(self: *Parser) ParseError!RegexNode {
        if (self.isEof()) return error.EmptyPattern;

        const c = self.peek();
        switch (c) {
            '.' => {
                self.advance();
                return .dot;
            },
            '^' => {
                self.advance();
                return .{ .anchor = .start };
            },
            '$' => {
                self.advance();
                return .{ .anchor = .end };
            },
            '[' => return self.parseCharClass(),
            '(' => return self.parseGroup(),
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.NothingToRepeat,
            else => {
                self.advance();
                return .{ .literal = c };
            },
        }
    }

    /// Parse character class [...]
    fn parseCharClass(self: *Parser) ParseError!RegexNode {
        self.advance(); // skip '['

        var negated = false;
        if (!self.isEof() and self.peek() == '^') {
            negated = true;
            self.advance();
        }

        var ranges: std.ArrayList(CharRange) = .empty;
        var singles: std.ArrayList(u8) = .empty;

        // First ']' is treated as literal
        var first = true;

        while (!self.isEof()) {
            const c = self.peek();

            if (c == ']' and !first) {
                self.advance();
                return .{ .char_class = .{
                    .ranges = ranges.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .singles = singles.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .negated = negated,
                } };
            }

            first = false;

            if (c == '\\') {
                self.advance();
                if (self.isEof()) return error.UnterminatedCharClass;
                const esc = try self.parseCharClassEscape();
                switch (esc) {
                    .single => |s| singles.append(self.allocator, s) catch return error.OutOfMemory,
                    .predefined => |p| {
                        expandPredefined(p, &ranges, &singles, self.allocator) catch return error.OutOfMemory;
                    },
                }
            } else {
                self.advance();
                // Range check: a-z
                if (!self.isEof() and self.peek() == '-') {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] != ']') {
                        self.advance(); // '-'
                        if (self.isEof()) return error.UnterminatedCharClass;
                        const end = self.peek();
                        self.advance();
                        ranges.append(self.allocator, .{ .start = c, .end = end }) catch return error.OutOfMemory;
                        continue;
                    }
                }
                singles.append(self.allocator, c) catch return error.OutOfMemory;
            }
        }

        return error.UnterminatedCharClass;
    }

    /// Character class escape result
    const CharClassEscapeResult = union(enum) {
        single: u8,
        predefined: Predefined,
    };

    fn parseCharClassEscape(self: *Parser) ParseError!CharClassEscapeResult {
        const c = self.peek();
        self.advance();
        return switch (c) {
            'd' => .{ .predefined = .digit },
            'D' => .{ .predefined = .non_digit },
            'w' => .{ .predefined = .word },
            'W' => .{ .predefined = .non_word },
            's' => .{ .predefined = .whitespace },
            'S' => .{ .predefined = .non_whitespace },
            'n' => .{ .single = '\n' },
            't' => .{ .single = '\t' },
            'r' => .{ .single = '\r' },
            'f' => .{ .single = '\x0C' },
            else => .{ .single = c }, // metachar escape
        };
    }

    /// Parse group (...)
    fn parseGroup(self: *Parser) ParseError!RegexNode {
        self.advance(); // skip '('

        var kind: GroupKind = .capturing;
        var group_flags: ?Flags = null;
        var capture_idx: u16 = 0;

        // Check group kind
        if (!self.isEof() and self.peek() == '?') {
            self.advance();
            if (self.isEof()) return error.UnterminatedGroup;

            const c = self.peek();
            switch (c) {
                ':' => {
                    kind = .non_capturing;
                    self.advance();
                },
                '=' => {
                    kind = .lookahead;
                    self.advance();
                },
                '!' => {
                    kind = .negative_lookahead;
                    self.advance();
                },
                'i', 'm', 's' => {
                    // Inline flags (?i), (?m), (?s)
                    var f = self.flags;
                    while (!self.isEof() and self.peek() != ')' and self.peek() != ':') {
                        switch (self.peek()) {
                            'i' => f.case_insensitive = true,
                            'm' => f.multiline = true,
                            's' => f.dotall = true,
                            else => return error.InvalidFlag,
                        }
                        self.advance();
                    }

                    if (!self.isEof() and self.peek() == ')') {
                        // (?i) — flags only, no group content
                        self.advance();
                        self.flags = f;
                        kind = .flag_group;
                        return .{ .group = .{
                            .kind = kind,
                            .children = &[_]RegexNode{},
                            .capture_index = 0,
                            .flags = f,
                        } };
                    }

                    // (?i:...) — flagged non-capturing group
                    if (!self.isEof() and self.peek() == ':') {
                        self.advance();
                    }
                    kind = .non_capturing;
                    group_flags = f;
                    self.flags = f;
                },
                else => return error.InvalidFlag,
            }
        }

        if (kind == .capturing) {
            self.group_count += 1;
            capture_idx = self.group_count;
        }

        // Parse group content
        const children = try self.parseAlternation();

        if (self.isEof() or self.peek() != ')') {
            return error.UnterminatedGroup;
        }
        self.advance(); // skip ')'

        return .{ .group = .{
            .kind = kind,
            .children = children,
            .capture_index = capture_idx,
            .flags = group_flags,
        } };
    }

    /// Parse escape sequence
    fn parseEscape(self: *Parser) ParseError!RegexNode {
        self.advance(); // skip '\'
        if (self.isEof()) return error.InvalidEscape;

        const c = self.peek();
        self.advance();

        return switch (c) {
            // Predefined classes
            'd' => .{ .predefined = .digit },
            'D' => .{ .predefined = .non_digit },
            'w' => .{ .predefined = .word },
            'W' => .{ .predefined = .non_word },
            's' => .{ .predefined = .whitespace },
            'S' => .{ .predefined = .non_whitespace },
            // Anchors
            'b' => .{ .anchor = .word_boundary },
            'B' => .{ .anchor = .non_word_boundary },
            // Escape chars
            'n' => .{ .literal = '\n' },
            't' => .{ .literal = '\t' },
            'r' => .{ .literal = '\r' },
            'f' => .{ .literal = '\x0C' },
            // Backreference
            '1'...'9' => .{ .backreference = @as(u16, c - '0') },
            // Metachar escape
            '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '\\' => .{ .literal = c },
            else => .{ .literal = c },
        };
    }

    // === Helpers ===

    fn isEof(self: *const Parser) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }
};

/// Expand predefined class into CharRange/singles
fn expandPredefined(
    p: Predefined,
    ranges: *std.ArrayList(CharRange),
    singles: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    switch (p) {
        .digit => try ranges.append(allocator, .{ .start = '0', .end = '9' }),
        .non_digit => {
            try ranges.append(allocator, .{ .start = 0, .end = '0' - 1 });
            try ranges.append(allocator, .{ .start = '9' + 1, .end = 127 });
        },
        .word => {
            try ranges.append(allocator, .{ .start = 'a', .end = 'z' });
            try ranges.append(allocator, .{ .start = 'A', .end = 'Z' });
            try ranges.append(allocator, .{ .start = '0', .end = '9' });
            try singles.append(allocator, '_');
        },
        .non_word => {
            try ranges.append(allocator, .{ .start = 0, .end = '0' - 1 });
            try ranges.append(allocator, .{ .start = '9' + 1, .end = 'A' - 1 });
            try ranges.append(allocator, .{ .start = 'Z' + 1, .end = '_' - 1 });
            try ranges.append(allocator, .{ .start = '_' + 1, .end = 'a' - 1 });
            try ranges.append(allocator, .{ .start = 'z' + 1, .end = 127 });
        },
        .whitespace => {
            try singles.append(allocator, ' ');
            try singles.append(allocator, '\t');
            try singles.append(allocator, '\n');
            try singles.append(allocator, '\r');
            try singles.append(allocator, '\x0C');
        },
        .non_whitespace => {
            try ranges.append(allocator, .{ .start = '!', .end = '~' });
            try ranges.append(allocator, .{ .start = 0, .end = 8 });
            try ranges.append(allocator, .{ .start = 14, .end = 31 });
        },
    }
}

// === Tests ===

test "literal parse" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "abc");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].literal);
    try std.testing.expectEqual(@as(u8, 'b'), result.nodes[1].literal);
    try std.testing.expectEqual(@as(u8, 'c'), result.nodes[2].literal);
}

test "dot parse" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a.b");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].literal);
    try std.testing.expect(result.nodes[1] == .dot);
    try std.testing.expectEqual(@as(u8, 'b'), result.nodes[2].literal);
}

test "quantifier parse" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a*b+c?");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .quantifier);
    try std.testing.expectEqual(@as(u32, 0), result.nodes[0].quantifier.min);
    try std.testing.expect(result.nodes[0].quantifier.max == null);
    try std.testing.expect(result.nodes[0].quantifier.greedy);
    try std.testing.expect(result.nodes[1] == .quantifier);
    try std.testing.expectEqual(@as(u32, 1), result.nodes[1].quantifier.min);
    try std.testing.expect(result.nodes[1].quantifier.max == null);
    try std.testing.expect(result.nodes[2] == .quantifier);
    try std.testing.expectEqual(@as(u32, 0), result.nodes[2].quantifier.min);
    try std.testing.expectEqual(@as(u32, 1), result.nodes[2].quantifier.max.?);
}

test "non-greedy quantifier" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a*?b+?");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 2), result.nodes.len);
    try std.testing.expect(!result.nodes[0].quantifier.greedy);
    try std.testing.expect(!result.nodes[1].quantifier.greedy);
}

test "character class" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[abc]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .char_class);
    try std.testing.expect(!result.nodes[0].char_class.negated);
    try std.testing.expectEqual(@as(usize, 3), result.nodes[0].char_class.singles.len);
}

test "negated character class" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[^abc]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0].char_class.negated);
}

test "character range" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[a-z0-9]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), result.nodes[0].char_class.ranges.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].char_class.ranges[0].start);
    try std.testing.expectEqual(@as(u8, 'z'), result.nodes[0].char_class.ranges[0].end);
}

test "alternation" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a|b|c");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .alternation);
    try std.testing.expectEqual(@as(usize, 3), result.nodes[0].alternation.alternatives.len);
}

test "capturing group" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "(abc)");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .group);
    try std.testing.expect(result.nodes[0].group.kind == .capturing);
    try std.testing.expectEqual(@as(u16, 1), result.nodes[0].group.capture_index);
    try std.testing.expectEqual(@as(u16, 1), result.group_count);
}

test "empty pattern" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "");
    const result = try p.parse();
    try std.testing.expectEqual(@as(usize, 0), result.nodes.len);
}
