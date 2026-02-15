// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Backtracking regex matcher.
//! Walks compiled RegexNode AST directly for matching.
//! Same backtracking approach as Java/Python/Ruby.

const std = @import("std");
const regex_mod = @import("regex.zig");
const RegexNode = regex_mod.RegexNode;
const CompiledRegex = regex_mod.CompiledRegex;
const Flags = regex_mod.Flags;
const Predefined = regex_mod.Predefined;
const CharClass = regex_mod.CharClass;
const CharRange = regex_mod.CharRange;

/// Match result
pub const MatchResult = struct {
    start: usize,
    end: usize,
    /// Capture groups: groups[0] = whole match, groups[1..] = each group
    groups: []const ?Span,
};

/// Span
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn text(self: Span, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

/// Max recursion depth
const MAX_RECURSION_DEPTH: usize = 10000;

/// Matcher
pub const Matcher = struct {
    compiled: *const CompiledRegex,
    input: []const u8,
    /// Capture group slots (mutable working area)
    captures: []?Span,
    /// Recursion depth counter
    depth: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, compiled: *const CompiledRegex, input: []const u8) !Matcher {
        const cap_count: usize = @as(usize, compiled.group_count) + 1;
        const captures = try allocator.alloc(?Span, cap_count);
        @memset(captures, null);
        return .{
            .compiled = compiled,
            .input = input,
            .captures = captures,
            .depth = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.allocator.free(self.captures);
    }

    /// Partial match search: find first position that matches
    pub fn find(self: *Matcher, start_pos: usize) !?MatchResult {
        var pos = start_pos;
        while (pos <= self.input.len) {
            @memset(self.captures, null);
            self.depth = 0;

            if (try self.tryMatchNodes(self.compiled.nodes, pos)) |end_pos| {
                self.captures[0] = .{ .start = pos, .end = end_pos };
                const groups = try self.allocator.dupe(?Span, self.captures);
                return .{
                    .start = pos,
                    .end = end_pos,
                    .groups = groups,
                };
            }

            pos += 1;
        }
        return null;
    }

    /// Full match: entire input must match pattern
    pub fn fullMatch(self: *Matcher) !?MatchResult {
        @memset(self.captures, null);
        self.depth = 0;

        if (try self.tryMatchNodes(self.compiled.nodes, 0)) |end_pos| {
            if (end_pos == self.input.len) {
                self.captures[0] = .{ .start = 0, .end = end_pos };
                const groups = try self.allocator.dupe(?Span, self.captures);
                return .{
                    .start = 0,
                    .end = end_pos,
                    .groups = groups,
                };
            }
        }
        return null;
    }

    const MatchError = error{OutOfMemory};

    /// Match a sequence of nodes
    fn tryMatchNodes(self: *Matcher, nodes: []const RegexNode, pos: usize) MatchError!?usize {
        self.depth += 1;
        defer self.depth -= 1;

        if (self.depth > MAX_RECURSION_DEPTH) return null;

        return self.tryMatchNodesAt(nodes, 0, pos);
    }

    /// Match nodes starting at index idx
    fn tryMatchNodesAt(self: *Matcher, nodes: []const RegexNode, idx: usize, pos: usize) MatchError!?usize {
        if (idx >= nodes.len) return pos;

        const node = nodes[idx];
        const rest = nodes[idx + 1 ..];

        // Quantifiers need integration with subsequent nodes for backtracking
        if (node == .quantifier) {
            if (node.quantifier.greedy) {
                return self.matchQuantifierGreedyWithRest(node.quantifier, rest, pos);
            } else {
                return self.matchQuantifierLazyWithRest(node.quantifier, rest, pos);
            }
        }

        // Groups (capturing/non-capturing): pass outer rest so inner quantifiers
        // can backtrack correctly (e.g., (.*)a, (\S+)=)
        if (node == .group) {
            const g = node.group;
            if (g.kind == .capturing or g.kind == .non_capturing) {
                return self.matchGroupWithRest(g, rest, pos);
            }
        }

        if (try self.tryMatchNode(node, pos)) |new_pos| {
            return self.tryMatchNodesAt(nodes, idx + 1, new_pos);
        }
        return null;
    }

    /// Match a single node
    fn tryMatchNode(self: *Matcher, node: RegexNode, pos: usize) MatchError!?usize {
        return switch (node) {
            .literal => |c| self.matchLiteral(c, pos),
            .dot => self.matchDot(pos),
            .char_class => |cc| self.matchCharClass(cc, pos),
            .predefined => |p| self.matchPredefined(p, pos),
            .anchor => |a| self.matchAnchor(a, pos),
            .group => |g| self.matchGroup(g, pos),
            .alternation => |alt| self.matchAlternation(alt, pos),
            .quantifier => |q| self.matchQuantifier(q, pos),
            .backreference => |idx| self.matchBackreference(idx, pos),
            .sequence => |seq| self.tryMatchNodes(seq, pos),
        };
    }

    fn matchLiteral(self: *const Matcher, c: u8, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        const ch = self.input[pos];
        if (self.compiled.flags.case_insensitive) {
            if (toLower(ch) == toLower(c)) return pos + 1;
        } else {
            if (ch == c) return pos + 1;
        }
        return null;
    }

    fn matchDot(self: *const Matcher, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        if (!self.compiled.flags.dotall and self.input[pos] == '\n') return null;
        return pos + 1;
    }

    fn matchCharClass(self: *const Matcher, cc: CharClass, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        const ch = self.input[pos];
        var in_class = false;

        for (cc.ranges) |range| {
            const c = if (self.compiled.flags.case_insensitive) toLower(ch) else ch;
            const start = if (self.compiled.flags.case_insensitive) toLower(range.start) else range.start;
            const end = if (self.compiled.flags.case_insensitive) toLower(range.end) else range.end;
            if (c >= start and c <= end) {
                in_class = true;
                break;
            }
        }

        if (!in_class) {
            for (cc.singles) |s| {
                const c = if (self.compiled.flags.case_insensitive) toLower(ch) else ch;
                const single = if (self.compiled.flags.case_insensitive) toLower(s) else s;
                if (c == single) {
                    in_class = true;
                    break;
                }
            }
        }

        const matches = if (cc.negated) !in_class else in_class;
        return if (matches) pos + 1 else null;
    }

    fn matchPredefined(self: *const Matcher, p: Predefined, pos: usize) ?usize {
        if (pos >= self.input.len) return null;
        const ch = self.input[pos];
        const matches = switch (p) {
            .digit => ch >= '0' and ch <= '9',
            .non_digit => !(ch >= '0' and ch <= '9'),
            .word => (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_',
            .non_word => !((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_'),
            .whitespace => ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0C',
            .non_whitespace => !(ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0C'),
        };
        return if (matches) pos + 1 else null;
    }

    fn matchAnchor(self: *const Matcher, a: regex_mod.Anchor, pos: usize) ?usize {
        const matches = switch (a) {
            .start => blk: {
                if (self.compiled.flags.multiline) {
                    break :blk pos == 0 or (pos > 0 and self.input[pos - 1] == '\n');
                } else {
                    break :blk pos == 0;
                }
            },
            .end => blk: {
                if (self.compiled.flags.multiline) {
                    break :blk pos == self.input.len or (pos < self.input.len and self.input[pos] == '\n');
                } else {
                    break :blk pos == self.input.len;
                }
            },
            .word_boundary => isWordBoundary(self.input, pos),
            .non_word_boundary => !isWordBoundary(self.input, pos),
        };
        return if (matches) pos else null; // anchors don't consume input
    }

    /// Match a group with outer rest integration for backtracking.
    /// This allows quantifiers inside groups (e.g., (.*)X, (\S+)=) to
    /// backtrack based on whether the outer rest matches.
    fn matchGroupWithRest(self: *Matcher, g: regex_mod.Group, outer_rest: []const RegexNode, pos: usize) MatchError!?usize {
        const children = g.children;

        // Find the last quantifier in the group's children (common pattern: (.+), (\S+), etc.)
        // For groups ending with a quantifier, integrate the quantifier with
        // a combined rest = remaining_group_children ++ outer_rest.
        const last_quant_idx = blk: {
            if (children.len == 0) break :blk null;
            var i = children.len;
            while (i > 0) {
                i -= 1;
                if (children[i] == .quantifier) break :blk i;
                break; // only check the last child
            }
            break :blk null;
        };

        if (last_quant_idx) |qi| {
            const q = children[qi].quantifier;
            const group_prefix = children[0..qi];
            const group_suffix = children[qi + 1 ..]; // usually empty

            // Match the prefix (non-quantifier nodes before the quantifier)
            const prefix_end = if (group_prefix.len > 0)
                try self.tryMatchNodes(group_prefix, pos)
            else
                pos;

            if (prefix_end) |quant_start| {
                // Build combined rest: group_suffix ++ GroupEndMarker(implicit) ++ outer_rest
                // Since we can't inject a capture marker, we handle capture separately.
                // Strategy: for each quantifier backtrack position, set capture and try rest.
                const saved = try self.allocator.dupe(?Span, self.captures);
                defer self.allocator.free(saved);

                if (q.greedy) {
                    // Greedy: accumulate positions, backtrack from max
                    var positions: std.ArrayList(usize) = .empty;
                    defer positions.deinit(self.allocator);
                    positions.append(self.allocator, quant_start) catch return null;

                    var current = quant_start;
                    var count: u32 = 0;
                    const max_count = q.max orelse std.math.maxInt(u32);

                    while (count < max_count) {
                        if (try self.tryMatchNode(q.child.*, current)) |new_pos| {
                            if (new_pos == current) break;
                            current = new_pos;
                            count += 1;
                            positions.append(self.allocator, current) catch return null;
                        } else break;
                    }

                    while (positions.items.len > 0) {
                        const try_pos = positions.pop().?;
                        const matched_count = positions.items.len;
                        if (matched_count >= q.min) {
                            // Set group capture tentatively
                            if (g.capture_index > 0 and g.capture_index < self.captures.len) {
                                self.captures[g.capture_index] = .{ .start = pos, .end = try_pos };
                            }
                            // Try group suffix + outer rest
                            const suffix_ok = if (group_suffix.len > 0)
                                try self.tryMatchNodes(group_suffix, try_pos)
                            else
                                try_pos;

                            if (suffix_ok) |after_suffix| {
                                if (try self.tryMatchNodesAt(outer_rest, 0, after_suffix)) |end_pos| {
                                    return end_pos;
                                }
                            }
                            @memcpy(self.captures, saved);
                        }
                    }
                } else {
                    // Lazy: expand from min
                    var current = quant_start;
                    var count: u32 = 0;
                    const max_count = q.max orelse std.math.maxInt(u32);

                    while (count < q.min) {
                        if (try self.tryMatchNode(q.child.*, current)) |new_pos| {
                            if (new_pos == current) break;
                            current = new_pos;
                            count += 1;
                        } else return null;
                    }

                    while (count <= max_count) {
                        // Set group capture tentatively
                        if (g.capture_index > 0 and g.capture_index < self.captures.len) {
                            self.captures[g.capture_index] = .{ .start = pos, .end = current };
                        }
                        // Try group suffix + outer rest
                        const suffix_ok = if (group_suffix.len > 0)
                            try self.tryMatchNodes(group_suffix, current)
                        else
                            current;

                        if (suffix_ok) |after_suffix| {
                            if (try self.tryMatchNodesAt(outer_rest, 0, after_suffix)) |end_pos| {
                                return end_pos;
                            }
                        }
                        @memcpy(self.captures, saved);

                        if (try self.tryMatchNode(q.child.*, current)) |new_pos| {
                            if (new_pos == current) break;
                            current = new_pos;
                            count += 1;
                        } else break;
                    }
                }
                return null;
            }
            return null;
        }

        // No quantifier in group: use standard matching then try outer rest
        switch (g.kind) {
            .capturing => {
                const result = try self.tryMatchNodes(children, pos);
                if (result) |end_pos| {
                    if (g.capture_index > 0 and g.capture_index < self.captures.len) {
                        self.captures[g.capture_index] = .{ .start = pos, .end = end_pos };
                    }
                    return self.tryMatchNodesAt(outer_rest, 0, end_pos);
                }
                return null;
            },
            .non_capturing => {
                const result = try self.tryMatchNodes(children, pos);
                if (result) |end_pos| {
                    return self.tryMatchNodesAt(outer_rest, 0, end_pos);
                }
                return null;
            },
            else => unreachable, // lookahead handled by tryMatchNodesAt
        }
    }

    fn matchGroup(self: *Matcher, g: regex_mod.Group, pos: usize) MatchError!?usize {
        switch (g.kind) {
            .capturing => {
                const result = try self.tryMatchNodes(g.children, pos);
                if (result) |end_pos| {
                    if (g.capture_index > 0 and g.capture_index < self.captures.len) {
                        self.captures[g.capture_index] = .{ .start = pos, .end = end_pos };
                    }
                    return end_pos;
                }
                return null;
            },
            .non_capturing => return self.tryMatchNodes(g.children, pos),
            .lookahead => {
                const result = try self.tryMatchNodes(g.children, pos);
                return if (result != null) pos else null;
            },
            .negative_lookahead => {
                const result = try self.tryMatchNodes(g.children, pos);
                return if (result == null) pos else null;
            },
            .flag_group => {
                return pos;
            },
        }
    }

    fn matchAlternation(self: *Matcher, alt: regex_mod.Alternation, pos: usize) MatchError!?usize {
        const saved = try self.allocator.dupe(?Span, self.captures);
        defer self.allocator.free(saved);

        for (alt.alternatives) |alternative| {
            if (try self.tryMatchNodes(alternative, pos)) |end_pos| {
                return end_pos;
            }
            @memcpy(self.captures, saved);
        }
        return null;
    }

    fn matchQuantifier(self: *Matcher, q: regex_mod.Quantifier, pos: usize) MatchError!?usize {
        // Standalone quantifier (called from tryMatchNode, no rest context).
        // Use greedy-with-rest with empty rest.
        return self.matchQuantifierGreedyWithRest(q, &.{}, pos);
    }

    fn matchQuantifierGreedyWithRest(self: *Matcher, q: regex_mod.Quantifier, rest: []const RegexNode, pos: usize) MatchError!?usize {
        var positions: std.ArrayList(usize) = .empty;
        defer positions.deinit(self.allocator);
        positions.append(self.allocator, pos) catch return null;

        var current_pos = pos;
        var count: u32 = 0;
        const max_count = q.max orelse std.math.maxInt(u32);

        // Greedily match as many as possible
        while (count < max_count) {
            if (try self.tryMatchNode(q.child.*, current_pos)) |new_pos| {
                if (new_pos == current_pos) break; // infinite loop prevention
                current_pos = new_pos;
                count += 1;
                positions.append(self.allocator, current_pos) catch return null;
            } else {
                break;
            }
        }

        // Backtrack from max to min, trying rest at each position
        const saved = try self.allocator.dupe(?Span, self.captures);
        defer self.allocator.free(saved);

        while (positions.items.len > 0) {
            const try_pos = positions.pop().?;
            const matched_count = positions.items.len;
            if (matched_count >= q.min) {
                if (try self.tryMatchNodesAt(rest, 0, try_pos)) |end_pos| {
                    return end_pos;
                }
                // Restore captures on backtrack
                @memcpy(self.captures, saved);
            }
        }

        return null;
    }

    fn matchQuantifierLazyWithRest(self: *Matcher, q: regex_mod.Quantifier, rest: []const RegexNode, pos: usize) MatchError!?usize {
        var current_pos = pos;
        var count: u32 = 0;
        const max_count = q.max orelse std.math.maxInt(u32);

        // Match minimum required times
        while (count < q.min) {
            if (try self.tryMatchNode(q.child.*, current_pos)) |new_pos| {
                if (new_pos == current_pos) break;
                current_pos = new_pos;
                count += 1;
            } else {
                return null;
            }
        }

        // Try from min to max, preferring fewer matches
        while (count <= max_count) {
            if (try self.tryMatchNodesAt(rest, 0, current_pos)) |end_pos| {
                return end_pos;
            }

            if (try self.tryMatchNode(q.child.*, current_pos)) |new_pos| {
                if (new_pos == current_pos) break;
                current_pos = new_pos;
                count += 1;
            } else {
                break;
            }
        }

        return null;
    }

    fn matchBackreference(self: *const Matcher, idx: u16, pos: usize) ?usize {
        if (idx >= self.captures.len) return null;
        const span = self.captures[idx] orelse return null;
        const ref_text = span.text(self.input);

        if (pos + ref_text.len > self.input.len) return null;

        if (self.compiled.flags.case_insensitive) {
            for (self.input[pos..][0..ref_text.len], ref_text) |a, b| {
                if (toLower(a) != toLower(b)) return null;
            }
        } else {
            if (!std.mem.eql(u8, self.input[pos..][0..ref_text.len], ref_text)) return null;
        }

        return pos + ref_text.len;
    }
};

// === Helper functions ===

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isWordBoundary(input: []const u8, pos: usize) bool {
    const before = if (pos > 0) isWordChar(input[pos - 1]) else false;
    const after = if (pos < input.len) isWordChar(input[pos]) else false;
    return before != after;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// === Convenience functions ===

/// Compile a pattern string
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !CompiledRegex {
    var parser = regex_mod.Parser.init(allocator, pattern);
    return parser.parse() catch |e| {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidRegex,
        };
    };
}

pub const CompileError = error{
    OutOfMemory,
    InvalidRegex,
};

/// Compile + find first match
pub fn findFirst(allocator: std.mem.Allocator, compiled: *const CompiledRegex, input: []const u8) !?MatchResult {
    var m = try Matcher.init(allocator, compiled, input);
    defer m.deinit();
    return m.find(0);
}

/// Compile + full match check
pub fn isFullMatch(allocator: std.mem.Allocator, compiled: *const CompiledRegex, input: []const u8) !bool {
    var m = try Matcher.init(allocator, compiled, input);
    defer m.deinit();
    return (try m.fullMatch()) != null;
}

// === Tests ===

test "literal match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "abc");
    const result = try findFirst(allocator, &compiled, "xabcy");

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.start);
    try std.testing.expectEqual(@as(usize, 4), result.?.end);
}

test "literal no match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "xyz");
    const result = try findFirst(allocator, &compiled, "abcdef");
    try std.testing.expect(result == null);
}

test "dot match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "a.c");
    try std.testing.expect((try findFirst(allocator, &compiled, "abc")) != null);
    try std.testing.expect((try findFirst(allocator, &compiled, "axc")) != null);
    try std.testing.expect((try findFirst(allocator, &compiled, "ac")) == null);
}

test "\\d+ match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "\\d+");
    const result = try findFirst(allocator, &compiled, "abc123def");

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("123", "abc123def"[result.?.start..result.?.end]);
}

test "capture group" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "(\\d+)-(\\d+)");
    const result = try findFirst(allocator, &compiled, "x12-34y");

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("12-34", "x12-34y"[result.?.start..result.?.end]);
    try std.testing.expectEqualStrings("12", result.?.groups[1].?.text("x12-34y"));
    try std.testing.expectEqualStrings("34", result.?.groups[2].?.text("x12-34y"));
}

test "full match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "\\d+");
    try std.testing.expect(try isFullMatch(allocator, &compiled, "123"));
    try std.testing.expect(!try isFullMatch(allocator, &compiled, "abc123"));
}

test "non-greedy .*?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "a.*?b");
    const result = try findFirst(allocator, &compiled, "aXbYb");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("aXb", "aXbYb"[result.?.start..result.?.end]);
}

test "consecutive find" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiled = try compile(allocator, "\\d+");
    const input = "a1b22c333";
    var m = try Matcher.init(allocator, &compiled, input);
    defer m.deinit();

    const r1 = try m.find(0);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("1", input[r1.?.start..r1.?.end]);

    const r2 = try m.find(r1.?.end);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("22", input[r2.?.start..r2.?.end]);

    const r3 = try m.find(r2.?.end);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings("333", input[r3.?.start..r3.?.end]);

    const r4 = try m.find(r3.?.end);
    try std.testing.expect(r4 == null);
}
