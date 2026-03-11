//! Tokenizer — converts Clojure source text into a token stream.
//!
//! Stateful iterator: call next() repeatedly to get tokens.
//! Tokens store byte offsets into the source; no copies are made.
//! Phase 1 scope: basic literals, delimiters, quote, #_, ##, #! shebang.

const std = @import("std");

/// Token classification.
pub const TokenKind = enum(u8) {
    // Delimiters
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,

    // Literals
    integer,
    float,
    string,
    symbol,
    keyword,

    // Reader macros (Phase 1 subset)
    quote, // '
    discard, // #_
    symbolic, // ## (for ##Inf, ##-Inf, ##NaN)

    // Special
    eof,
    invalid,
};

/// A single token with location info.
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u16,
    line: u32, // 1-based
    column: u16, // 0-based

    /// Extract the token text from the source.
    pub fn text(self: Token, source: []const u8) []const u8 {
        const s: usize = self.start;
        const e: usize = s + self.len;
        return source[s..e];
    }
};

/// Stateful tokenizer over Clojure source text.
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    column: u16 = 0,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    /// Return the next token, advancing the internal state.
    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return self.makeEof();
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const ch = self.source[self.pos];

        switch (ch) {
            '(' => {
                self.advance();
                return .{ .kind = .lparen, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            ')' => {
                self.advance();
                return .{ .kind = .rparen, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            '[' => {
                self.advance();
                return .{ .kind = .lbracket, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            ']' => {
                self.advance();
                return .{ .kind = .rbracket, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            '{' => {
                self.advance();
                return .{ .kind = .lbrace, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            '}' => {
                self.advance();
                return .{ .kind = .rbrace, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            '\'' => {
                self.advance();
                return .{ .kind = .quote, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
            '"' => return self.readString(start, start_line, start_col),
            ':' => return self.readKeyword(start, start_line, start_col),
            '#' => return self.readDispatch(start, start_line, start_col),
            else => {
                // Number or symbol
                if (isDigit(ch)) {
                    return self.readNumber(start, start_line, start_col);
                }
                // +N or -N where N is a digit
                if ((ch == '+' or ch == '-') and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                    return self.readNumber(start, start_line, start_col);
                }
                if (isSymbolStart(ch)) {
                    return self.readSymbol(start, start_line, start_col);
                }
                // Unknown character
                self.advance();
                return .{ .kind = .invalid, .start = start, .len = 1, .line = start_line, .column = start_col };
            },
        }
    }

    // --- Private readers ---

    fn readString(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // skip opening "
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance(); // skip closing "
                return self.makeToken(.string, start, start_line, start_col);
            }
            if (c == '\\') {
                self.advance(); // skip backslash
                if (self.pos < self.source.len) {
                    self.advance(); // skip escaped char
                }
                continue;
            }
            self.advance();
        }
        // Unterminated string
        return self.makeToken(.invalid, start, start_line, start_col);
    }

    fn readKeyword(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // skip ':'
        // Read symbol chars after ':'
        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
            self.advance();
        }
        // Bare ':' with no name is invalid
        if (self.pos - start <= 1) {
            return self.makeToken(.invalid, start, start_line, start_col);
        }
        return self.makeToken(.keyword, start, start_line, start_col);
    }

    fn readNumber(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        var is_float = false;

        // Optional sign
        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            self.advance();
        }

        // Hex: 0x...
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
            (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.advance(); // '0'
            self.advance(); // 'x'
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                self.advance();
            }
            return self.makeToken(.integer, start, start_line, start_col);
        }

        // Digits
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.advance();
        }

        // Decimal point
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.advance();
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.advance();
            }
        }

        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.advance();
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.advance();
            }
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.advance();
            }
        }

        // BigInt suffix N or BigDecimal suffix M (treat as int/float for Phase 1)
        if (self.pos < self.source.len and (self.source[self.pos] == 'N')) {
            self.advance();
        } else if (self.pos < self.source.len and (self.source[self.pos] == 'M')) {
            is_float = true;
            self.advance();
        }

        return self.makeToken(if (is_float) .float else .integer, start, start_line, start_col);
    }

    fn readSymbol(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
            self.advance();
        }
        // Check for special symbol names
        const txt = self.source[start..self.pos];
        if (std.mem.eql(u8, txt, "nil") or std.mem.eql(u8, txt, "true") or std.mem.eql(u8, txt, "false")) {
            return self.makeToken(.symbol, start, start_line, start_col);
        }
        return self.makeToken(.symbol, start, start_line, start_col);
    }

    fn readDispatch(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // skip '#'

        if (self.pos >= self.source.len) {
            return self.makeToken(.invalid, start, start_line, start_col);
        }

        const c = self.source[self.pos];
        switch (c) {
            '_' => {
                self.advance();
                return self.makeToken(.discard, start, start_line, start_col);
            },
            '#' => {
                self.advance();
                return self.makeToken(.symbolic, start, start_line, start_col);
            },
            '!' => {
                // Shebang: skip to end of line, then return next token
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
                return self.next(); // recurse to get next real token
            },
            else => {
                return self.makeToken(.invalid, start, start_line, start_col);
            },
        }
    }

    // --- Helpers ---

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isWhitespace(c)) {
                self.advance();
            } else if (c == ';') {
                // Line comment: skip to end of line
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

    fn makeEof(self: *Tokenizer) Token {
        return .{ .kind = .eof, .start = self.pos, .len = 0, .line = self.line, .column = self.column };
    }

    fn makeToken(self: *Tokenizer, kind: TokenKind, start: u32, start_line: u32, start_col: u16) Token {
        const len = self.pos - start;
        return .{ .kind = kind, .start = start, .len = @intCast(len), .line = start_line, .column = start_col };
    }
};

// --- Character classification ---

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '\x0C', ',' => true, // comma is whitespace in Clojure
        else => false,
    };
}

fn isTerminator(c: u8) bool {
    return isWhitespace(c) or switch (c) {
        '"', ';', '(', ')', '[', ']', '{', '}', '\\', '#' => true,
        else => false,
    };
}

fn isSymbolChar(c: u8) bool {
    return !isTerminator(c) and c > ' ';
}

fn isSymbolStart(c: u8) bool {
    return isSymbolChar(c) and !isDigit(c);
}

// --- Tests ---

const testing = std.testing;

test "empty input" {
    var t = Tokenizer.init("");
    const tok = t.next();
    try testing.expectEqual(TokenKind.eof, tok.kind);
}

test "whitespace only" {
    var t = Tokenizer.init("  \t\n  ");
    const tok = t.next();
    try testing.expectEqual(TokenKind.eof, tok.kind);
}

test "delimiters" {
    var t = Tokenizer.init("()[]{}");
    try testing.expectEqual(TokenKind.lparen, t.next().kind);
    try testing.expectEqual(TokenKind.rparen, t.next().kind);
    try testing.expectEqual(TokenKind.lbracket, t.next().kind);
    try testing.expectEqual(TokenKind.rbracket, t.next().kind);
    try testing.expectEqual(TokenKind.lbrace, t.next().kind);
    try testing.expectEqual(TokenKind.rbrace, t.next().kind);
    try testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "integer" {
    var t = Tokenizer.init("42");
    const tok = t.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("42", tok.text(t.source));
}

test "negative integer" {
    var t = Tokenizer.init("-7");
    const tok = t.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("-7", tok.text(t.source));
}

test "hex integer" {
    var t = Tokenizer.init("0xFF");
    const tok = t.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("0xFF", tok.text(t.source));
}

test "float" {
    var t = Tokenizer.init("3.14");
    const tok = t.next();
    try testing.expectEqual(TokenKind.float, tok.kind);
    try testing.expectEqualStrings("3.14", tok.text(t.source));
}

test "float with exponent" {
    var t = Tokenizer.init("1e10");
    const tok = t.next();
    try testing.expectEqual(TokenKind.float, tok.kind);
    try testing.expectEqualStrings("1e10", tok.text(t.source));
}

test "string" {
    var t = Tokenizer.init("\"hello\"");
    const tok = t.next();
    try testing.expectEqual(TokenKind.string, tok.kind);
    try testing.expectEqualStrings("\"hello\"", tok.text(t.source));
}

test "string with escapes" {
    var t = Tokenizer.init("\"hello\\nworld\"");
    const tok = t.next();
    try testing.expectEqual(TokenKind.string, tok.kind);
    try testing.expectEqualStrings("\"hello\\nworld\"", tok.text(t.source));
}

test "unterminated string" {
    var t = Tokenizer.init("\"hello");
    const tok = t.next();
    try testing.expectEqual(TokenKind.invalid, tok.kind);
}

test "symbol" {
    var t = Tokenizer.init("foo");
    const tok = t.next();
    try testing.expectEqual(TokenKind.symbol, tok.kind);
    try testing.expectEqualStrings("foo", tok.text(t.source));
}

test "qualified symbol" {
    var t = Tokenizer.init("clojure.core/map");
    const tok = t.next();
    try testing.expectEqual(TokenKind.symbol, tok.kind);
    try testing.expectEqualStrings("clojure.core/map", tok.text(t.source));
}

test "nil true false as symbols" {
    var t = Tokenizer.init("nil true false");
    try testing.expectEqualStrings("nil", t.next().text(t.source));
    try testing.expectEqualStrings("true", t.next().text(t.source));
    try testing.expectEqualStrings("false", t.next().text(t.source));
}

test "keyword" {
    var t = Tokenizer.init(":foo");
    const tok = t.next();
    try testing.expectEqual(TokenKind.keyword, tok.kind);
    try testing.expectEqualStrings(":foo", tok.text(t.source));
}

test "qualified keyword" {
    var t = Tokenizer.init(":my.ns/bar");
    const tok = t.next();
    try testing.expectEqual(TokenKind.keyword, tok.kind);
    try testing.expectEqualStrings(":my.ns/bar", tok.text(t.source));
}

test "bare colon is invalid" {
    var t = Tokenizer.init(": ");
    const tok = t.next();
    try testing.expectEqual(TokenKind.invalid, tok.kind);
}

test "quote" {
    var t = Tokenizer.init("'foo");
    const tok = t.next();
    try testing.expectEqual(TokenKind.quote, tok.kind);
    try testing.expectEqualStrings("'", tok.text(t.source));
}

test "discard" {
    var t = Tokenizer.init("#_foo");
    const tok = t.next();
    try testing.expectEqual(TokenKind.discard, tok.kind);
    try testing.expectEqualStrings("#_", tok.text(t.source));
}

test "symbolic" {
    var t = Tokenizer.init("##Inf");
    const tok = t.next();
    try testing.expectEqual(TokenKind.symbolic, tok.kind);
    try testing.expectEqualStrings("##", tok.text(t.source));
}

test "shebang skipped" {
    var t = Tokenizer.init("#!/usr/bin/env clojure\n42");
    const tok = t.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("42", tok.text(t.source));
}

test "comment skipped" {
    var t = Tokenizer.init("; this is a comment\n42");
    const tok = t.next();
    try testing.expectEqual(TokenKind.integer, tok.kind);
    try testing.expectEqualStrings("42", tok.text(t.source));
}

test "comma is whitespace" {
    var t = Tokenizer.init("1,2,3");
    try testing.expectEqualStrings("1", t.next().text(t.source));
    try testing.expectEqualStrings("2", t.next().text(t.source));
    try testing.expectEqualStrings("3", t.next().text(t.source));
}

test "source location tracking" {
    var t = Tokenizer.init("(\n  42)");
    const lparen = t.next();
    try testing.expectEqual(@as(u32, 1), lparen.line);
    try testing.expectEqual(@as(u16, 0), lparen.column);

    const num = t.next();
    try testing.expectEqual(@as(u32, 2), num.line);
    try testing.expectEqual(@as(u16, 2), num.column);

    const rparen = t.next();
    try testing.expectEqual(@as(u32, 2), rparen.line);
    try testing.expectEqual(@as(u16, 4), rparen.column);
}

test "complex expression (+ 1 2)" {
    var t = Tokenizer.init("(+ 1 2)");
    try testing.expectEqual(TokenKind.lparen, t.next().kind);
    const plus = t.next();
    try testing.expectEqual(TokenKind.symbol, plus.kind);
    try testing.expectEqualStrings("+", plus.text(t.source));
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.rparen, t.next().kind);
    try testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "mixed types [1 :a \"b\"]" {
    var t = Tokenizer.init("[1 :a \"b\"]");
    try testing.expectEqual(TokenKind.lbracket, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.keyword, t.next().kind);
    try testing.expectEqual(TokenKind.string, t.next().kind);
    try testing.expectEqual(TokenKind.rbracket, t.next().kind);
    try testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "map {:k v}" {
    var t = Tokenizer.init("{:k v}");
    try testing.expectEqual(TokenKind.lbrace, t.next().kind);
    try testing.expectEqual(TokenKind.keyword, t.next().kind);
    try testing.expectEqual(TokenKind.symbol, t.next().kind);
    try testing.expectEqual(TokenKind.rbrace, t.next().kind);
}

test "special symbols + - are symbols" {
    var t = Tokenizer.init("+ -");
    const plus = t.next();
    try testing.expectEqual(TokenKind.symbol, plus.kind);
    try testing.expectEqualStrings("+", plus.text(t.source));
    const minus = t.next();
    try testing.expectEqual(TokenKind.symbol, minus.kind);
    try testing.expectEqualStrings("-", minus.text(t.source));
}

test "quoted list '(1 2)" {
    var t = Tokenizer.init("'(1 2)");
    try testing.expectEqual(TokenKind.quote, t.next().kind);
    try testing.expectEqual(TokenKind.lparen, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.rparen, t.next().kind);
}
