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
//! Status: Phase 6.6 cycle 1 SKELETON — types declared, parser
//! and IR emission land in the next commits of this cycle. Per
//! `no_op_stub_forbidden`, `compile(...)` raises an explicit
//! error rather than silently dropping semantics.

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
    /// Phase 6.6 cycle 1 skeleton — body lands in the next
    /// commit. Per `no_op_stub_forbidden`, this is an explicit
    /// "not implemented" rather than a silent drop.
    NotImplemented,

    /// Reserved for parser errors once the parser lands.
    UnexpectedToken,
    UnclosedGroup,
    UnclosedClass,
    InvalidQuantifier,
    InvalidEscape,
} || std.mem.Allocator.Error;

/// Compile a regex pattern source into a `Program`. Caller owns
/// the resulting `Program` and must call `Program.deinit` to
/// free the IR slice.
///
/// Status: skeleton — `compile` calls `parsePattern` then
/// `emit`; both still return `CompileError.NotImplemented` until
/// the recursive-descent parser + IR walker land.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Program {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const node = try parsePattern(arena.allocator(), pattern, flags);
    return try emit(alloc, node, flags);
}

/// Parser entry point: recursive-descent over the regex source,
/// emits a `Node` tree into the supplied arena allocator.
///
/// Cycle-1 step 2: ASCII literal sequence (concatenation).
/// Metacharacters (`.`, `*`, `+`, `?`, `(`, `)`, `[`, `]`,
/// `|`, `\\`, `^`, `$`, `{`, `}`) and the empty pattern all
/// raise `NotImplemented`. Alternation / quantifiers /
/// character classes / anchors are subsequent commits.
pub fn parsePattern(arena: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!*const Node {
    _ = flags;
    if (pattern.len == 0) return CompileError.NotImplemented;
    for (pattern) |c| {
        if (isMetaChar(c)) return CompileError.NotImplemented;
    }
    if (pattern.len == 1) {
        const node = try arena.create(Node);
        node.* = .{ .lit = pattern[0] };
        return node;
    }
    const children = try arena.alloc(Node, pattern.len);
    for (pattern, 0..) |c, i| children[i] = .{ .lit = c };
    const root = try arena.create(Node);
    root.* = .{ .concat = children };
    return root;
}

fn isMetaChar(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '(', ')', '[', ']', '|', '\\', '^', '$', '{', '}' => true,
        else => false,
    };
}

/// IR emitter: walks the AST and emits Pike-VM instructions
/// into a flat `Inst` slice. Cycle-1 first cell: `.lit` only.
fn emit(alloc: std.mem.Allocator, node: *const Node, flags: Flags) CompileError!Program {
    var list: std.ArrayList(Inst) = .empty;
    errdefer list.deinit(alloc);
    try emitNode(&list, alloc, node);
    try list.append(alloc, .{ .match = {} });
    return Program{
        .insts = try list.toOwnedSlice(alloc),
        .capture_count = 0,
        .flags = flags,
    };
}

fn emitNode(list: *std.ArrayList(Inst), alloc: std.mem.Allocator, node: *const Node) CompileError!void {
    switch (node.*) {
        .lit => |c| try list.append(alloc, .{ .char = c }),
        .concat => |children| {
            for (children) |*ch| try emitNode(list, alloc, ch);
        },
        else => return CompileError.NotImplemented,
    }
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

test "compile rejects metacharacter / empty (NotImplemented)" {
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, ".", .{}));
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, "*", .{}));
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, "", .{}));
    try testing.expectError(CompileError.NotImplemented, compile(testing.allocator, "a*", .{}));
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
