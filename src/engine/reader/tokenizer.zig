// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Tokenizer — Converts Clojure source text into a stream of tokens.
//!
//! Design:
//!   - Stateful iterator: call next() repeatedly to get tokens
//!   - Token stores offset + length into original source (no copies)
//!   - Tracks line/column for error reporting
//!   - Comma is whitespace (Clojure convention)
//!   - Escape processing handled by Reader stage

const std = @import("std");

pub const TokenKind = enum(u8) {
    // Delimiters
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,

    // Literals
    nil,
    true_lit,
    false_lit,
    integer,
    float,
    ratio,
    string,
    character,
    keyword,
    symbol,

    // Macro characters
    quote,
    deref,
    meta,
    syntax_quote,
    unquote,
    unquote_splicing,

    // Dispatch (#)
    discard,
    var_quote,
    fn_lit,
    set_lit,
    regex,
    symbolic,
    reader_cond,
    reader_cond_splicing,
    ns_map,
    tag,

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u16,
    line: u32,
    column: u16,

    /// Return the token text as a slice of the original source.
    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    column: u16 = 0,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, 0);
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const c = self.source[self.pos];

        const kind: TokenKind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            '\'' => .quote,
            '@' => .deref,
            '^' => .meta,
            '`' => .syntax_quote,
            '~' => blk: {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '@') {
                    self.advance(); // ~
                    self.advance(); // @
                    return .{
                        .kind = .unquote_splicing,
                        .start = start,
                        .len = @intCast(self.pos - start),
                        .line = start_line,
                        .column = start_col,
                    };
                }
                break :blk .unquote;
            },
            '"' => return self.readString(),
            ':' => return self.readKeyword(),
            '\\' => return self.readCharacter(),
            '#' => return self.readDispatch(),
            '+', '-' => {
                if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                    return self.readNumber();
                }
                return self.readSymbol();
            },
            '0'...'9' => return self.readNumber(),
            else => return self.readSymbol(),
        };

        self.advance();
        return .{
            .kind = kind,
            .start = start,
            .len = @intCast(self.pos - start),
            .line = start_line,
            .column = start_col,
        };
    }

    fn readCharacter(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        self.advance(); // backslash

        if (self.pos >= self.source.len) {
            return .{ .kind = .invalid, .start = start, .len = 1, .line = start_line, .column = start_col };
        }

        // Always read at least one character after backslash (even if it's a terminator like comma)
        self.advance();

        // Continue reading for named characters (e.g. \newline, \space, \u1234)
        while (self.pos < self.source.len and !isTerminator(self.source[self.pos])) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start);
        return .{ .kind = .character, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readDispatch(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        self.advance(); // #

        if (self.pos >= self.source.len) {
            return .{ .kind = .invalid, .start = start, .len = 1, .line = start_line, .column = start_col };
        }

        const c = self.source[self.pos];
        const kind: TokenKind = switch (c) {
            '_' => blk: { self.advance(); break :blk .discard; },
            '\'' => blk: { self.advance(); break :blk .var_quote; },
            '(' => blk: { self.advance(); break :blk .fn_lit; },
            '{' => blk: { self.advance(); break :blk .set_lit; },
            '"' => return self.readRegex(start, start_line, start_col),
            '#' => blk: { self.advance(); break :blk .symbolic; },
            '?' => blk: {
                self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '@') {
                    self.advance();
                    break :blk .reader_cond_splicing;
                }
                break :blk .reader_cond;
            },
            ':' => blk: {
                self.advance(); // skip past first `:`
                // Check for auto-resolve `#::`
                if (self.pos < self.source.len and self.source[self.pos] == ':') {
                    self.advance();
                }
                // Read namespace name (symbol chars)
                while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
                    self.advance();
                }
                break :blk .ns_map;
            },
            '!' => {
                // #! shebang/comment — skip to end of line
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
                // Recurse to get next real token
                return self.next();
            },
            else => blk: {
                // Tagged literal: #inst, #uuid, etc.
                break :blk .tag;
            },
        };

        const len: u16 = @intCast(self.pos - start);
        return .{ .kind = kind, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readRegex(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // opening "

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance(); // closing "
                const len: u16 = @intCast(self.pos - start);
                return .{ .kind = .regex, .start = start, .len = len, .line = start_line, .column = start_col };
            } else if (c == '\\') {
                self.advance();
                if (self.pos < self.source.len) self.advance();
            } else {
                self.advance();
            }
        }

        // Unterminated regex — cap length to avoid u16 overflow
        const len: u16 = @intCast(@min(self.pos - start, std.math.maxInt(u16)));
        return .{ .kind = .invalid, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readKeyword(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        self.advance(); // :

        // :: (auto-resolved keyword)
        if (self.pos < self.source.len and self.source[self.pos] == ':') {
            self.advance();
        }

        // Read keyword name (allows / for namespace separator)
        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start);
        // : alone or :: alone is invalid
        if (len <= 1 or (len == 2 and self.source[start + 1] == ':')) {
            return .{ .kind = .invalid, .start = start, .len = len, .line = start_line, .column = start_col };
        }

        return .{ .kind = .keyword, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readString(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        self.advance(); // opening "

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance(); // closing "
                const len: u16 = @intCast(self.pos - start);
                return .{ .kind = .string, .start = start, .len = len, .line = start_line, .column = start_col };
            } else if (c == '\\') {
                self.advance(); // backslash
                if (self.pos < self.source.len) self.advance(); // escaped char
            } else {
                self.advance();
            }
        }

        // Unterminated string — cap length to avoid u16 overflow
        const len: u16 = @intCast(@min(self.pos - start, std.math.maxInt(u16)));
        return .{ .kind = .invalid, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readNumber(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        // Optional sign
        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            self.advance();
        }

        var has_dot = false;
        var has_exp = false;
        var has_ratio = false;

        // Handle 0x prefix
        if (self.pos < self.source.len and self.source[self.pos] == '0' and
            self.pos + 1 < self.source.len and (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.advance(); // 0
            self.advance(); // x
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                self.advance();
            }
        } else {
            // Integer part
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.advance();
            }

            // Radix: NNrXXX
            if (self.pos < self.source.len and (self.source[self.pos] == 'r' or self.source[self.pos] == 'R')) {
                self.advance();
                while (self.pos < self.source.len and isRadixDigit(self.source[self.pos])) {
                    self.advance();
                }
            } else {
                // Ratio: N/N
                if (self.pos < self.source.len and self.source[self.pos] == '/' and
                    self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))
                {
                    has_ratio = true;
                    self.advance(); // /
                    while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                        self.advance();
                    }
                }

                // Decimal part
                if (!has_ratio and self.pos < self.source.len and self.source[self.pos] == '.') {
                    has_dot = true;
                    self.advance();
                    while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                        self.advance();
                    }
                }

                // Exponent
                if (!has_ratio and self.pos < self.source.len and
                    (self.source[self.pos] == 'e' or self.source[self.pos] == 'E'))
                {
                    has_exp = true;
                    self.advance();
                    if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                        self.advance();
                    }
                    while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                        self.advance();
                    }
                }
            }
        }

        // Suffix N or M
        if (self.pos < self.source.len and (self.source[self.pos] == 'N' or self.source[self.pos] == 'M')) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start);
        const kind: TokenKind = if (has_ratio) .ratio else if (has_dot or has_exp) .float else .integer;
        return .{ .kind = kind, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn readSymbol(self: *Tokenizer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start);
        const txt = self.source[start..][0..len];

        const kind: TokenKind = if (std.mem.eql(u8, txt, "nil"))
            .nil
        else if (std.mem.eql(u8, txt, "true"))
            .true_lit
        else if (std.mem.eql(u8, txt, "false"))
            .false_lit
        else
            .symbol;

        return .{ .kind = kind, .start = start, .len = len, .line = start_line, .column = start_col };
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            if (isWhitespace(self.source[self.pos])) {
                self.advance();
            } else if (self.source[self.pos] == ';') {
                // Skip line comment
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 0;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn makeToken(self: *const Tokenizer, kind: TokenKind, len: u16) Token {
        return .{
            .kind = kind,
            .start = self.pos,
            .len = len,
            .line = self.line,
            .column = self.column,
        };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isRadixDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isTerminator(c: u8) bool {
    return isWhitespace(c) or c == '"' or c == ';' or c == '@' or c == '^' or
        c == '`' or c == '~' or c == '(' or c == ')' or c == '[' or c == ']' or
        c == '{' or c == '}' or c == '\\';
}

fn isSymbolChar(c: u8) bool {
    // # is valid inside symbols (gensym: foo#, tagged: my#tag)
    // but not at start (handled by next() dispatch).
    // : is valid inside symbols/keywords (e.g. abc:def, :abc:def:ghi).
    // Colons only start keywords at token boundaries (handled by next()).
    return !isTerminator(c);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C' or c == ',';
}

const testing = std.testing;

// === Tests ===

test "empty string returns eof" {
    var t = Tokenizer.init("");
    const tok = t.next();
    try testing.expectEqual(.eof, tok.kind);
    try testing.expectEqual(@as(u32, 0), tok.start);
    try testing.expectEqual(@as(u16, 0), tok.len);
}

test "whitespace is skipped" {
    var t = Tokenizer.init("  ( ) ");
    try testing.expectEqual(.lparen, t.next().kind);
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "semicolon comment skipped" {
    var t = Tokenizer.init("; comment\n()");
    try testing.expectEqual(.lparen, t.next().kind);
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "comma is whitespace" {
    var t = Tokenizer.init("(,)");
    try testing.expectEqual(.lparen, t.next().kind);
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "symbol" {
    var t = Tokenizer.init("foo bar+");
    const tok1 = t.next();
    try testing.expectEqual(.symbol, tok1.kind);
    try testing.expectEqualStrings("foo", tok1.text(t.source));
    const tok2 = t.next();
    try testing.expectEqual(.symbol, tok2.kind);
    try testing.expectEqualStrings("bar+", tok2.text(t.source));
}

test "string literal" {
    var t = Tokenizer.init("\"hello\" \"world\"");
    const t1 = t.next();
    try testing.expectEqual(.string, t1.kind);
    try testing.expectEqualStrings("\"hello\"", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.string, t2.kind);
    try testing.expectEqualStrings("\"world\"", t2.text(t.source));
}

test "string with escape" {
    var t = Tokenizer.init("\"he\\\"llo\"");
    const tok = t.next();
    try testing.expectEqual(.string, tok.kind);
    try testing.expectEqualStrings("\"he\\\"llo\"", tok.text(t.source));
}

test "keyword" {
    var t = Tokenizer.init(":foo :bar/baz");
    const t1 = t.next();
    try testing.expectEqual(.keyword, t1.kind);
    try testing.expectEqualStrings(":foo", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.keyword, t2.kind);
    try testing.expectEqualStrings(":bar/baz", t2.text(t.source));
}

test "macro characters" {
    var t = Tokenizer.init("'foo @bar ^meta `form ~x ~@xs");
    try testing.expectEqual(.quote, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // foo
    try testing.expectEqual(.deref, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // bar
    try testing.expectEqual(.meta, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // meta
    try testing.expectEqual(.syntax_quote, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // form
    try testing.expectEqual(.unquote, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // x
    try testing.expectEqual(.unquote_splicing, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // xs
    try testing.expectEqual(.eof, t.next().kind);
}

test "dispatch macros" {
    var t = Tokenizer.init("#_ #' #( #{ ##");
    try testing.expectEqual(.discard, t.next().kind);
    try testing.expectEqual(.var_quote, t.next().kind);
    try testing.expectEqual(.fn_lit, t.next().kind);
    try testing.expectEqual(.set_lit, t.next().kind);
    try testing.expectEqual(.symbolic, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "reader conditional" {
    var t = Tokenizer.init("#? #?@");
    try testing.expectEqual(.reader_cond, t.next().kind);
    try testing.expectEqual(.reader_cond_splicing, t.next().kind);
}

test "regex literal" {
    var t = Tokenizer.init("#\"foo.*bar\"");
    const tok = t.next();
    try testing.expectEqual(.regex, tok.kind);
    try testing.expectEqualStrings("#\"foo.*bar\"", tok.text(t.source));
}

test "character literal" {
    var t = Tokenizer.init("\\a \\newline \\space");
    const t1 = t.next();
    try testing.expectEqual(.character, t1.kind);
    try testing.expectEqualStrings("\\a", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.character, t2.kind);
    try testing.expectEqualStrings("\\newline", t2.text(t.source));
    const t3 = t.next();
    try testing.expectEqual(.character, t3.kind);
    try testing.expectEqualStrings("\\space", t3.text(t.source));
}

test "tagged literal" {
    var t = Tokenizer.init("#inst \"2024-01-01\"");
    const t1 = t.next();
    try testing.expectEqual(.tag, t1.kind);
    try testing.expectEqualStrings("#", t1.text(t.source));
    // The reader would consume 'inst' as the next token (symbol)
    const t2 = t.next();
    try testing.expectEqual(.symbol, t2.kind);
    try testing.expectEqualStrings("inst", t2.text(t.source));
}

test "line and column tracking" {
    var t = Tokenizer.init("(\n  42)");
    const t1 = t.next(); // (
    try testing.expectEqual(@as(u32, 1), t1.line);
    try testing.expectEqual(@as(u16, 0), t1.column);
    const t2 = t.next(); // 42
    try testing.expectEqual(@as(u32, 2), t2.line);
    try testing.expectEqual(@as(u16, 2), t2.column);
    const t3 = t.next(); // )
    try testing.expectEqual(@as(u32, 2), t3.line);
    try testing.expectEqual(@as(u16, 4), t3.column);
}

test "float literal" {
    var t = Tokenizer.init("3.14 1e10 2.5e-3");
    const t1 = t.next();
    try testing.expectEqual(.float, t1.kind);
    try testing.expectEqualStrings("3.14", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.float, t2.kind);
    try testing.expectEqualStrings("1e10", t2.text(t.source));
    const t3 = t.next();
    try testing.expectEqual(.float, t3.kind);
    try testing.expectEqualStrings("2.5e-3", t3.text(t.source));
}

test "ratio literal" {
    var t = Tokenizer.init("22/7 1/2");
    const t1 = t.next();
    try testing.expectEqual(.ratio, t1.kind);
    try testing.expectEqualStrings("22/7", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.ratio, t2.kind);
    try testing.expectEqualStrings("1/2", t2.text(t.source));
}

test "hex literal" {
    var t = Tokenizer.init("0xFF 0x2A");
    const t1 = t.next();
    try testing.expectEqual(.integer, t1.kind);
    try testing.expectEqualStrings("0xFF", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.integer, t2.kind);
    try testing.expectEqualStrings("0x2A", t2.text(t.source));
}

test "radix literal" {
    var t = Tokenizer.init("2r101010 8r52 36rZZ");
    const t1 = t.next();
    try testing.expectEqual(.integer, t1.kind);
    try testing.expectEqualStrings("2r101010", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.integer, t2.kind);
    try testing.expectEqualStrings("8r52", t2.text(t.source));
    const t3 = t.next();
    try testing.expectEqual(.integer, t3.kind);
    try testing.expectEqualStrings("36rZZ", t3.text(t.source));
}

test "bigint and bigdecimal suffix" {
    var t = Tokenizer.init("42N 3.14M");
    const t1 = t.next();
    try testing.expectEqual(.integer, t1.kind);
    try testing.expectEqualStrings("42N", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.float, t2.kind);
    try testing.expectEqualStrings("3.14M", t2.text(t.source));
}

test "complete expression: (defn f [x] (+ x 1))" {
    var t = Tokenizer.init("(defn f [x] (+ x 1))");
    try testing.expectEqual(.lparen, t.next().kind);
    const defn_tok = t.next();
    try testing.expectEqual(.symbol, defn_tok.kind);
    try testing.expectEqualStrings("defn", defn_tok.text(t.source));
    try testing.expectEqual(.symbol, t.next().kind); // f
    try testing.expectEqual(.lbracket, t.next().kind);
    try testing.expectEqual(.symbol, t.next().kind); // x
    try testing.expectEqual(.rbracket, t.next().kind);
    try testing.expectEqual(.lparen, t.next().kind);
    const plus = t.next();
    try testing.expectEqual(.symbol, plus.kind);
    try testing.expectEqualStrings("+", plus.text(t.source));
    try testing.expectEqual(.symbol, t.next().kind); // x
    try testing.expectEqual(.integer, t.next().kind); // 1
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "namespaced symbol" {
    var t = Tokenizer.init("clojure.core/map");
    const tok = t.next();
    try testing.expectEqual(.symbol, tok.kind);
    try testing.expectEqualStrings("clojure.core/map", tok.text(t.source));
}

test "shebang comment" {
    var t = Tokenizer.init("#!/usr/bin/env clj\n42");
    // # dispatches, then ! triggers shebang skip
    const tok = t.next();
    try testing.expectEqual(.integer, tok.kind);
    try testing.expectEqualStrings("42", tok.text(t.source));
}

test "ns-map dispatch" {
    var t = Tokenizer.init("#:foo{:a 1}");
    const tok = t.next();
    try testing.expectEqual(.ns_map, tok.kind);
    try testing.expectEqualStrings("#:foo", tok.text(t.source));
    // auto-resolve variant
    var t2 = Tokenizer.init("#::bar{:a 1}");
    const tok2 = t2.next();
    try testing.expectEqual(.ns_map, tok2.kind);
    try testing.expectEqualStrings("#::bar", tok2.text(t2.source));
}

test "multiple eof calls are safe" {
    var t = Tokenizer.init("");
    try testing.expectEqual(.eof, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "whitespace-only input" {
    var t = Tokenizer.init("   \n\t  ");
    try testing.expectEqual(.eof, t.next().kind);
}

test "symbol with special chars" {
    var t = Tokenizer.init("swap! foo# *bar* -baz>");
    try testing.expectEqualStrings("swap!", t.next().text(t.source));
    try testing.expectEqualStrings("foo#", t.next().text(t.source));
    try testing.expectEqualStrings("*bar*", t.next().text(t.source));
    try testing.expectEqualStrings("-baz>", t.next().text(t.source));
}

test "auto-resolved keyword" {
    var t = Tokenizer.init("::foo");
    const t1 = t.next();
    try testing.expectEqual(.keyword, t1.kind);
    try testing.expectEqualStrings("::foo", t1.text(t.source));
}

test "unterminated string" {
    var t = Tokenizer.init("\"oops");
    const tok = t.next();
    try testing.expectEqual(.invalid, tok.kind);
}

test "integer literals" {
    var t = Tokenizer.init("42 -17 +5 0");
    const t1 = t.next();
    try testing.expectEqual(.integer, t1.kind);
    try testing.expectEqualStrings("42", t1.text(t.source));
    const t2 = t.next();
    try testing.expectEqual(.integer, t2.kind);
    try testing.expectEqualStrings("-17", t2.text(t.source));
    const t3 = t.next();
    try testing.expectEqual(.integer, t3.kind);
    try testing.expectEqualStrings("+5", t3.text(t.source));
    const t4 = t.next();
    try testing.expectEqual(.integer, t4.kind);
    try testing.expectEqualStrings("0", t4.text(t.source));
}

test "nil true false literals" {
    var t = Tokenizer.init("nil true false");
    try testing.expectEqual(.nil, t.next().kind);
    try testing.expectEqual(.true_lit, t.next().kind);
    try testing.expectEqual(.false_lit, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}

test "single-char delimiters" {
    var t = Tokenizer.init("()[]{}");
    try testing.expectEqual(.lparen, t.next().kind);
    try testing.expectEqual(.rparen, t.next().kind);
    try testing.expectEqual(.lbracket, t.next().kind);
    try testing.expectEqual(.rbracket, t.next().kind);
    try testing.expectEqual(.lbrace, t.next().kind);
    try testing.expectEqual(.rbrace, t.next().kind);
    try testing.expectEqual(.eof, t.next().kind);
}
