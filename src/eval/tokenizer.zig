//! Tokenizer — Clojure source text → token stream.
//!
//! Stateful iterator: callers loop on `next()` until they see `.eof`.
//! Tokens hold byte offsets into the source, so the source slice must
//! outlive the tokens — no copies are made.
//!
//! Phase 1 scope: delimiters, integer / float / string / symbol /
//! keyword literals, plus the reader macros `'`, `#_`, `##` (used
//! for `##Inf` / `##-Inf` / `##NaN`) and a `#!` shebang skip. Comma
//! counts as whitespace per Clojure. The richer reader macros
//! (`` ` ``, `~`, `~@`, `^`, `#()`, `#'`, `#"re"`, `#inst`, `#uuid`)
//! land in later phases.

const std = @import("std");

/// Token classification.
pub const TokenKind = enum(u8) {
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,

    integer,
    float,
    string,
    symbol,
    keyword,

    quote, // '
    discard, // #_
    symbolic, // ## (##Inf / ##-Inf / ##NaN)

    eof,
    invalid,
};

/// A single token. `start` + `len` is a slice into `source`; `line`/
/// `column` is the start position of the token (1-based line, 0-based
/// column).
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u16,
    line: u32,
    column: u16,

    pub fn text(self: Token, source: []const u8) []const u8 {
        const s: usize = self.start;
        const e: usize = s + self.len;
        return source[s..e];
    }
};

/// Stateful tokenizer.
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    column: u16 = 0,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    /// Return the next token; advances state. Idempotent at EOF.
    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) return self.makeEof();

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const ch = self.source[self.pos];

        switch (ch) {
            '(' => return self.singleChar(.lparen, start, start_line, start_col),
            ')' => return self.singleChar(.rparen, start, start_line, start_col),
            '[' => return self.singleChar(.lbracket, start, start_line, start_col),
            ']' => return self.singleChar(.rbracket, start, start_line, start_col),
            '{' => return self.singleChar(.lbrace, start, start_line, start_col),
            '}' => return self.singleChar(.rbrace, start, start_line, start_col),
            '\'' => return self.singleChar(.quote, start, start_line, start_col),
            '"' => return self.readString(start, start_line, start_col),
            ':' => return self.readKeyword(start, start_line, start_col),
            '#' => return self.readDispatch(start, start_line, start_col),
            else => {
                if (isDigit(ch)) {
                    return self.readNumber(start, start_line, start_col);
                }
                if ((ch == '+' or ch == '-') and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                    return self.readNumber(start, start_line, start_col);
                }
                if (isSymbolStart(ch)) {
                    return self.readSymbol(start, start_line, start_col);
                }
                self.advance();
                return makeTokenAt(.invalid, start, 1, start_line, start_col);
            },
        }
    }

    // --- private readers ---

    fn singleChar(self: *Tokenizer, kind: TokenKind, start: u32, start_line: u32, start_col: u16) Token {
        self.advance();
        return makeTokenAt(kind, start, 1, start_line, start_col);
    }

    fn readString(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // opening "
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance();
                return self.makeToken(.string, start, start_line, start_col);
            }
            if (c == '\\') {
                self.advance();
                if (self.pos < self.source.len) self.advance();
                continue;
            }
            self.advance();
        }
        return self.makeToken(.invalid, start, start_line, start_col); // unterminated
    }

    fn readKeyword(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // ':'
        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) {
            self.advance();
        }
        if (self.pos - start <= 1) {
            return self.makeToken(.invalid, start, start_line, start_col); // bare ':'
        }
        return self.makeToken(.keyword, start, start_line, start_col);
    }

    fn readNumber(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        var is_float = false;

        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            self.advance();
        }

        // Hex: 0x...
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
            (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.advance();
            self.advance();
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.advance();
            return self.makeToken(.integer, start, start_line, start_col);
        }

        while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.advance();

        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.advance();
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.advance();
        }

        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.advance();
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.advance();
            }
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.advance();
        }

        // Phase 1 treats the BigInt `N` and BigDecimal `M` suffixes as
        // ordinary int / float; the analyzer will round-trip them later.
        if (self.pos < self.source.len and self.source[self.pos] == 'N') {
            self.advance();
        } else if (self.pos < self.source.len and self.source[self.pos] == 'M') {
            is_float = true;
            self.advance();
        }

        return self.makeToken(if (is_float) .float else .integer, start, start_line, start_col);
    }

    fn readSymbol(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        while (self.pos < self.source.len and isSymbolChar(self.source[self.pos])) self.advance();
        // `nil` / `true` / `false` come back as plain symbol tokens;
        // the reader (next phase) re-classifies them.
        return self.makeToken(.symbol, start, start_line, start_col);
    }

    fn readDispatch(self: *Tokenizer, start: u32, start_line: u32, start_col: u16) Token {
        self.advance(); // '#'

        if (self.pos >= self.source.len) {
            return self.makeToken(.invalid, start, start_line, start_col);
        }

        switch (self.source[self.pos]) {
            '_' => {
                self.advance();
                return self.makeToken(.discard, start, start_line, start_col);
            },
            '#' => {
                self.advance();
                return self.makeToken(.symbolic, start, start_line, start_col);
            },
            '!' => {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.advance();
                return self.next(); // skip shebang line, return next real token
            },
            else => return self.makeToken(.invalid, start, start_line, start_col),
        }
    }

    // --- helpers ---

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isWhitespace(c)) {
                self.advance();
            } else if (c == ';') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.advance();
            } else break;
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
        return makeTokenAt(kind, start, @intCast(len), start_line, start_col);
    }
};

fn makeTokenAt(kind: TokenKind, start: u32, len: u16, line: u32, column: u16) Token {
    return .{ .kind = kind, .start = start, .len = len, .line = line, .column = column };
}

// --- character classes ---

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

// --- tests ---

const testing = std.testing;

test "empty input emits eof" {
    var t = Tokenizer.init("");
    try testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "whitespace only emits eof" {
    var t = Tokenizer.init("  \t\n  ");
    try testing.expectEqual(TokenKind.eof, t.next().kind);
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

test "integers (decimal, signed, hex)" {
    var t = Tokenizer.init("42 -7 0xFF");
    const a = t.next();
    try testing.expectEqual(TokenKind.integer, a.kind);
    try testing.expectEqualStrings("42", a.text(t.source));

    const b = t.next();
    try testing.expectEqual(TokenKind.integer, b.kind);
    try testing.expectEqualStrings("-7", b.text(t.source));

    const c = t.next();
    try testing.expectEqual(TokenKind.integer, c.kind);
    try testing.expectEqualStrings("0xFF", c.text(t.source));
}

test "floats (decimal and exponent)" {
    var t = Tokenizer.init("3.14 1e10");
    const a = t.next();
    try testing.expectEqual(TokenKind.float, a.kind);
    try testing.expectEqualStrings("3.14", a.text(t.source));

    const b = t.next();
    try testing.expectEqual(TokenKind.float, b.kind);
    try testing.expectEqualStrings("1e10", b.text(t.source));
}

test "strings (plain and escaped); unterminated is invalid" {
    var t = Tokenizer.init("\"hello\" \"hello\\nworld\"");
    const a = t.next();
    try testing.expectEqual(TokenKind.string, a.kind);
    try testing.expectEqualStrings("\"hello\"", a.text(t.source));

    const b = t.next();
    try testing.expectEqual(TokenKind.string, b.kind);
    try testing.expectEqualStrings("\"hello\\nworld\"", b.text(t.source));

    var u = Tokenizer.init("\"hello");
    try testing.expectEqual(TokenKind.invalid, u.next().kind);
}

test "symbols include nil/true/false; qualified names" {
    var t = Tokenizer.init("foo clojure.core/map nil true false + -");
    try testing.expectEqualStrings("foo", t.next().text(t.source));
    try testing.expectEqualStrings("clojure.core/map", t.next().text(t.source));
    try testing.expectEqualStrings("nil", t.next().text(t.source));
    try testing.expectEqualStrings("true", t.next().text(t.source));
    try testing.expectEqualStrings("false", t.next().text(t.source));
    try testing.expectEqualStrings("+", t.next().text(t.source));
    try testing.expectEqualStrings("-", t.next().text(t.source));
}

test "keywords (bare and qualified); bare ':' is invalid" {
    var t = Tokenizer.init(":foo :my.ns/bar");
    const a = t.next();
    try testing.expectEqual(TokenKind.keyword, a.kind);
    try testing.expectEqualStrings(":foo", a.text(t.source));
    const b = t.next();
    try testing.expectEqual(TokenKind.keyword, b.kind);
    try testing.expectEqualStrings(":my.ns/bar", b.text(t.source));

    var u = Tokenizer.init(": ");
    try testing.expectEqual(TokenKind.invalid, u.next().kind);
}

test "reader macros: quote / discard / symbolic" {
    var t = Tokenizer.init("'foo #_skip ##Inf");
    try testing.expectEqual(TokenKind.quote, t.next().kind);
    try testing.expectEqual(TokenKind.symbol, t.next().kind);
    try testing.expectEqual(TokenKind.discard, t.next().kind);
    try testing.expectEqual(TokenKind.symbol, t.next().kind);
    try testing.expectEqual(TokenKind.symbolic, t.next().kind);
    try testing.expectEqual(TokenKind.symbol, t.next().kind);
}

test "comments and shebangs are skipped; commas count as whitespace" {
    var t = Tokenizer.init("#!/usr/bin/env clojure\n; this is a comment\n42 1,2,3");
    try testing.expectEqualStrings("42", t.next().text(t.source));
    try testing.expectEqualStrings("1", t.next().text(t.source));
    try testing.expectEqualStrings("2", t.next().text(t.source));
    try testing.expectEqualStrings("3", t.next().text(t.source));
}

test "source location tracks line/column across newlines" {
    var t = Tokenizer.init("(\n  42)");
    const lp = t.next();
    try testing.expectEqual(@as(u32, 1), lp.line);
    try testing.expectEqual(@as(u16, 0), lp.column);

    const num = t.next();
    try testing.expectEqual(@as(u32, 2), num.line);
    try testing.expectEqual(@as(u16, 2), num.column);

    const rp = t.next();
    try testing.expectEqual(@as(u32, 2), rp.line);
    try testing.expectEqual(@as(u16, 4), rp.column);
}

test "(+ 1 2) tokenises in order" {
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

test "[1 :a \"b\"] mixes types" {
    var t = Tokenizer.init("[1 :a \"b\"]");
    try testing.expectEqual(TokenKind.lbracket, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.keyword, t.next().kind);
    try testing.expectEqual(TokenKind.string, t.next().kind);
    try testing.expectEqual(TokenKind.rbracket, t.next().kind);
    try testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "{:k v} maps tokenise" {
    var t = Tokenizer.init("{:k v}");
    try testing.expectEqual(TokenKind.lbrace, t.next().kind);
    try testing.expectEqual(TokenKind.keyword, t.next().kind);
    try testing.expectEqual(TokenKind.symbol, t.next().kind);
    try testing.expectEqual(TokenKind.rbrace, t.next().kind);
}

test "'(1 2) emits quote then list" {
    var t = Tokenizer.init("'(1 2)");
    try testing.expectEqual(TokenKind.quote, t.next().kind);
    try testing.expectEqual(TokenKind.lparen, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.integer, t.next().kind);
    try testing.expectEqual(TokenKind.rparen, t.next().kind);
}
