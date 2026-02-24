// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! WIT (WebAssembly Interface Types) parser.
//!
//! Parses a subset of WIT sufficient for function signatures:
//!   interface name { func-name: func(params...) -> result; }
//!
//! Supported types: u8-u64, s8-s64, f32, f64, bool, char, string.
//! list<T>, option<T>, result<T,E> are recognized but stored as opaque names.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// Types
// ============================================================

/// A parsed WIT type.
pub const WitType = enum {
    u8,
    u16,
    u32,
    u64,
    s8,
    s16,
    s32,
    s64,
    f32,
    f64,
    bool,
    char,
    string,
    /// Composite or unknown type (list<T>, option<T>, result<T,E>, etc.)
    other,

    /// Map WIT type to the number of core Wasm i32 parameters it maps to.
    /// string -> 2 (ptr, len), primitives -> 1.
    pub fn coreParamCount(self: WitType) u32 {
        return switch (self) {
            .string => 2,
            else => 1,
        };
    }
};

/// A function parameter with name and type.
pub const WitParam = struct {
    name: []const u8,
    type_: WitType,
};

/// A parsed function definition.
pub const WitFunc = struct {
    name: []const u8,
    params: []const WitParam,
    /// null means no return type (void function).
    result: ?WitType,
};

/// A parsed WIT interface.
pub const WitInterface = struct {
    name: []const u8,
    funcs: []const WitFunc,
};

// ============================================================
// Tokenizer
// ============================================================

const TokenTag = enum {
    ident,
    colon,
    semicolon,
    comma,
    lparen,
    rparen,
    lbrace,
    rbrace,
    langle,
    rangle,
    arrow, // ->
    eof,
};

const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.src.len) return .{ .tag = .eof, .text = "" };

        const c = self.src[self.pos];

        // Single-char tokens
        const single: ?TokenTag = switch (c) {
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '<' => .langle,
            '>' => .rangle,
            else => null,
        };
        if (single) |tag| {
            self.pos += 1;
            return .{ .tag = tag, .text = self.src[self.pos - 1 .. self.pos] };
        }

        // Arrow ->
        if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .tag = .arrow, .text = "->" };
        }

        // Identifier: [a-zA-Z_][a-zA-Z0-9_-]*
        if (isIdentStart(c)) {
            const start = self.pos;
            self.pos += 1;
            while (self.pos < self.src.len and isIdentCont(self.src[self.pos]))
                self.pos += 1;
            return .{ .tag = .ident, .text = self.src[start..self.pos] };
        }

        // Unknown char — skip
        self.pos += 1;
        return self.next();
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            // Line comment: // ...
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n')
                    self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '%';
    }

    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
    }
};

// ============================================================
// Parser
// ============================================================

pub const ParseError = error{
    WitParseError,
    OutOfMemory,
};

/// Parse a WIT source string into a list of interfaces.
pub fn parse(allocator: Allocator, src: []const u8) ParseError![]const WitInterface {
    var tokenizer = Tokenizer.init(src);
    var interfaces: std.ArrayList(WitInterface) = .empty;
    errdefer interfaces.deinit(allocator);

    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .ident) continue;

        if (std.mem.eql(u8, tok.text, "interface")) {
            const iface = try parseInterface(allocator, &tokenizer);
            interfaces.append(allocator, iface) catch return error.OutOfMemory;
        }
        // Skip `package`, `world`, `use`, etc.
    }

    return interfaces.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseInterface(allocator: Allocator, tok: *Tokenizer) ParseError!WitInterface {
    const name_tok = tok.next();
    if (name_tok.tag != .ident) return error.WitParseError;

    const lbrace = tok.next();
    if (lbrace.tag != .lbrace) return error.WitParseError;

    var funcs: std.ArrayList(WitFunc) = .empty;
    errdefer funcs.deinit(allocator);

    while (true) {
        const t = tok.next();
        if (t.tag == .rbrace or t.tag == .eof) break;
        if (t.tag != .ident) continue;

        // func-name: func(...)
        const func_name = t.text;
        const colon = tok.next();
        if (colon.tag != .colon) continue;

        const func_kw = tok.next();
        if (func_kw.tag != .ident or !std.mem.eql(u8, func_kw.text, "func")) continue;

        const f = try parseFunc(allocator, tok, func_name);
        funcs.append(allocator, f) catch return error.OutOfMemory;
    }

    return .{
        .name = name_tok.text,
        .funcs = funcs.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

fn parseFunc(allocator: Allocator, tok: *Tokenizer, name: []const u8) ParseError!WitFunc {
    // Expect '('
    const lparen = tok.next();
    if (lparen.tag != .lparen) return error.WitParseError;

    var params: std.ArrayList(WitParam) = .empty;
    errdefer params.deinit(allocator);

    // Parse params until ')'
    while (true) {
        const t = tok.next();
        if (t.tag == .rparen) break;
        if (t.tag == .eof) return error.WitParseError;
        if (t.tag == .comma) continue;
        if (t.tag != .ident) return error.WitParseError;

        // param-name: type
        const param_name = t.text;
        const colon = tok.next();
        if (colon.tag != .colon) return error.WitParseError;

        const type_ = try parseType(tok);
        params.append(allocator, .{ .name = param_name, .type_ = type_ }) catch return error.OutOfMemory;
    }

    // Optional -> result
    var result: ?WitType = null;
    const maybe_arrow = tok.next();
    if (maybe_arrow.tag == .arrow) {
        result = try parseType(tok);
        // Consume trailing semicolon if present
        const semi = tok.next();
        if (semi.tag != .semicolon) {
            // Not a semicolon — let the caller handle it (push back not supported, but
            // since we're in a `{...}` block, this might be `}` which is fine)
        }
    }
    // If no arrow, maybe_arrow is the semicolon or something else

    return .{
        .name = name,
        .params = params.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .result = result,
    };
}

fn parseType(tok: *Tokenizer) ParseError!WitType {
    const t = tok.next();
    if (t.tag != .ident) return error.WitParseError;

    const type_ = resolveType(t.text);

    // Handle generic types: list<T>, option<T>, result<T, E>
    if (type_ == .other) {
        // Check for < ... >
        const maybe_angle = tok.next();
        if (maybe_angle.tag == .langle) {
            skipUntilClosingAngle(tok);
        }
        // If not <, we consumed one token too many — but since we only look for
        // simple cases this is acceptable for the subset we support.
    }

    return type_;
}

fn skipUntilClosingAngle(tok: *Tokenizer) void {
    var depth: usize = 1;
    while (depth > 0) {
        const t = tok.next();
        if (t.tag == .langle) depth += 1;
        if (t.tag == .rangle) depth -= 1;
        if (t.tag == .eof) break;
    }
}

fn resolveType(name: []const u8) WitType {
    const map = .{
        .{ "u8", WitType.u8 },
        .{ "u16", WitType.u16 },
        .{ "u32", WitType.u32 },
        .{ "u64", WitType.u64 },
        .{ "s8", WitType.s8 },
        .{ "s16", WitType.s16 },
        .{ "s32", WitType.s32 },
        .{ "s64", WitType.s64 },
        .{ "f32", WitType.f32 },
        .{ "f64", WitType.f64 },
        .{ "float32", WitType.f32 },
        .{ "float64", WitType.f64 },
        .{ "bool", WitType.bool },
        .{ "char", WitType.char },
        .{ "string", WitType.string },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .other;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "tokenizer — basic tokens" {
    var tok = Tokenizer.init("greet: func(name: string) -> string;");
    try testing.expectEqual(TokenTag.ident, tok.next().tag); // greet
    try testing.expectEqual(TokenTag.colon, tok.next().tag);
    try testing.expectEqual(TokenTag.ident, tok.next().tag); // func
    try testing.expectEqual(TokenTag.lparen, tok.next().tag);
    try testing.expectEqual(TokenTag.ident, tok.next().tag); // name
    try testing.expectEqual(TokenTag.colon, tok.next().tag);
    try testing.expectEqual(TokenTag.ident, tok.next().tag); // string
    try testing.expectEqual(TokenTag.rparen, tok.next().tag);
    try testing.expectEqual(TokenTag.arrow, tok.next().tag);
    try testing.expectEqual(TokenTag.ident, tok.next().tag); // string
    try testing.expectEqual(TokenTag.semicolon, tok.next().tag);
    try testing.expectEqual(TokenTag.eof, tok.next().tag);
}

test "tokenizer — comments skipped" {
    var tok = Tokenizer.init("// comment\nfoo");
    const t = tok.next();
    try testing.expectEqual(TokenTag.ident, t.tag);
    try testing.expectEqualStrings("foo", t.text);
}

test "tokenizer — hyphenated identifiers" {
    var tok = Tokenizer.init("is-even");
    const t = tok.next();
    try testing.expectEqual(TokenTag.ident, t.tag);
    try testing.expectEqualStrings("is-even", t.text);
}

test "parse — greet interface" {
    const src = @embedFile("testdata/10_greet.wit");
    const ifaces = try parse(testing.allocator, src);
    defer testing.allocator.free(ifaces);
    defer for (ifaces) |iface| {
        for (iface.funcs) |f| testing.allocator.free(f.params);
        testing.allocator.free(iface.funcs);
    };

    try testing.expectEqual(@as(usize, 1), ifaces.len);
    try testing.expectEqualStrings("greet", ifaces[0].name);
    try testing.expectEqual(@as(usize, 1), ifaces[0].funcs.len);

    const f = ifaces[0].funcs[0];
    try testing.expectEqualStrings("greet", f.name);
    try testing.expectEqual(@as(usize, 1), f.params.len);
    try testing.expectEqualStrings("name", f.params[0].name);
    try testing.expectEqual(WitType.string, f.params[0].type_);
    try testing.expectEqual(WitType.string, f.result.?);
}

test "parse — math interface with multiple functions" {
    const src = @embedFile("testdata/11_math.wit");
    const ifaces = try parse(testing.allocator, src);
    defer testing.allocator.free(ifaces);
    defer for (ifaces) |iface| {
        for (iface.funcs) |f| testing.allocator.free(f.params);
        testing.allocator.free(iface.funcs);
    };

    try testing.expectEqual(@as(usize, 1), ifaces.len);
    const iface = ifaces[0];
    try testing.expectEqualStrings("math", iface.name);
    try testing.expectEqual(@as(usize, 5), iface.funcs.len);

    // add: func(a: s32, b: s32) -> s32
    const add = iface.funcs[0];
    try testing.expectEqualStrings("add", add.name);
    try testing.expectEqual(@as(usize, 2), add.params.len);
    try testing.expectEqual(WitType.s32, add.params[0].type_);
    try testing.expectEqual(WitType.s32, add.result.?);

    // multiply: func(x: f64, y: f64) -> f64
    const mul = iface.funcs[1];
    try testing.expectEqualStrings("multiply", mul.name);
    try testing.expectEqual(WitType.f64, mul.params[0].type_);
    try testing.expectEqual(WitType.f64, mul.result.?);

    // is-even: func(n: u32) -> bool
    const even = iface.funcs[2];
    try testing.expectEqualStrings("is-even", even.name);
    try testing.expectEqual(WitType.u32, even.params[0].type_);
    try testing.expectEqual(WitType.bool, even.result.?);

    // no-return: func(msg: string)
    const noret = iface.funcs[4];
    try testing.expectEqualStrings("no-return", noret.name);
    try testing.expectEqual(WitType.string, noret.params[0].type_);
    try testing.expect(noret.result == null);
}

test "resolveType — all primitives" {
    try testing.expectEqual(WitType.u8, resolveType("u8"));
    try testing.expectEqual(WitType.s64, resolveType("s64"));
    try testing.expectEqual(WitType.f32, resolveType("f32"));
    try testing.expectEqual(WitType.f64, resolveType("f64"));
    try testing.expectEqual(WitType.bool, resolveType("bool"));
    try testing.expectEqual(WitType.char, resolveType("char"));
    try testing.expectEqual(WitType.string, resolveType("string"));
    try testing.expectEqual(WitType.f32, resolveType("float32"));
    try testing.expectEqual(WitType.other, resolveType("unknown"));
}

test "WitType.coreParamCount" {
    try testing.expectEqual(@as(u32, 1), WitType.s32.coreParamCount());
    try testing.expectEqual(@as(u32, 2), WitType.string.coreParamCount());
    try testing.expectEqual(@as(u32, 1), WitType.bool.coreParamCount());
}
