//! Reader — converts a token stream into a Form AST.
//!
//! Three-phase pipeline: Source text → Tokenizer → Reader → Form tree.
//! Phase 1 scope: nil, bool, int, float, string, keyword, symbol,
//! list, vector, map, quote, ##, #_, #! shebang.

const std = @import("std");
const Form = @import("form.zig").Form;
const FormData = @import("form.zig").FormData;
const SymbolRef = @import("form.zig").SymbolRef;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const TokenKind = @import("tokenizer.zig").TokenKind;

pub const ReadError = error{
    SyntaxError,
    NumberError,
    StringError,
    OutOfMemory,
};

pub const Reader = struct {
    tokenizer: Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,
    peeked: ?Token = null,
    depth: u32 = 0,
    max_depth: u32 = 1024,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
        };
    }

    /// Read a single form. Returns null on EOF.
    pub fn read(self: *Reader) ReadError!?Form {
        const tok = self.nextToken();
        if (tok.kind == .eof) return null;
        return try self.readForm(tok);
    }

    /// Read all forms until EOF.
    pub fn readAll(self: *Reader) ReadError![]Form {
        var forms: std.ArrayList(Form) = .empty;
        errdefer forms.deinit(self.allocator);
        while (true) {
            const form = try self.read() orelse break;
            forms.append(self.allocator, form) catch return error.OutOfMemory;
        }
        return forms.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // --- Core dispatch ---

    fn readForm(self: *Reader, tok: Token) ReadError!Form {
        return switch (tok.kind) {
            .symbol => self.readSymbol(tok),
            .integer => self.readInteger(tok),
            .float => self.readFloat(tok),
            .string => self.readString(tok),
            .keyword => self.readKeyword(tok),
            .lparen => self.readList(tok),
            .lbracket => self.readVector(tok),
            .lbrace => self.readMap(tok),
            .quote => self.readQuote(tok),
            .symbolic => self.readSymbolic(tok),
            .discard => self.readDiscard(tok),
            .rparen, .rbracket, .rbrace => error.SyntaxError,
            .eof => error.SyntaxError,
            .invalid => error.SyntaxError,
        };
    }

    // --- Literals ---

    fn readSymbol(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        if (std.mem.eql(u8, txt, "nil")) {
            return Form{ .data = .nil, .line = tok.line, .column = tok.column };
        }
        if (std.mem.eql(u8, txt, "true")) {
            return Form{ .data = .{ .boolean = true }, .line = tok.line, .column = tok.column };
        }
        if (std.mem.eql(u8, txt, "false")) {
            return Form{ .data = .{ .boolean = false }, .line = tok.line, .column = tok.column };
        }
        const sym = parseSymbolRef(txt);
        return Form{ .data = .{ .symbol = sym }, .line = tok.line, .column = tok.column };
    }

    fn readInteger(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        // Strip N suffix (BigInt marker, not supported in Phase 1 but accepted)
        var s = txt;
        if (s.len > 0 and s[s.len - 1] == 'N') {
            s = s[0 .. s.len - 1];
        }
        const val = std.fmt.parseInt(i64, s, 0) catch return error.NumberError;
        return Form{ .data = .{ .integer = val }, .line = tok.line, .column = tok.column };
    }

    fn readFloat(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        var s = txt;
        if (s.len > 0 and s[s.len - 1] == 'M') {
            s = s[0 .. s.len - 1];
        }
        const val = std.fmt.parseFloat(f64, s) catch return error.NumberError;
        return Form{ .data = .{ .float = val }, .line = tok.line, .column = tok.column };
    }

    fn readString(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        // Strip surrounding quotes
        if (txt.len < 2) return error.StringError;
        const content = txt[1 .. txt.len - 1];
        const unescaped = self.unescapeString(content) catch return error.StringError;
        return Form{ .data = .{ .string = unescaped }, .line = tok.line, .column = tok.column };
    }

    fn readKeyword(self: *Reader, tok: Token) ReadError!Form {
        var txt = tok.text(self.source);
        // Strip leading ':'
        txt = txt[1..];
        const sym = parseSymbolRef(txt);
        return Form{ .data = .{ .keyword = sym }, .line = tok.line, .column = tok.column };
    }

    // --- Collections ---

    fn readList(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rparen, tok);
        return Form{ .data = .{ .list = items }, .line = tok.line, .column = tok.column };
    }

    fn readVector(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rbracket, tok);
        return Form{ .data = .{ .vector = items }, .line = tok.line, .column = tok.column };
    }

    fn readMap(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rbrace, tok);
        if (items.len % 2 != 0) return error.SyntaxError;
        return Form{ .data = .{ .map = items }, .line = tok.line, .column = tok.column };
    }

    fn readDelimited(self: *Reader, closing: TokenKind, open_tok: Token) ReadError![]const Form {
        _ = open_tok;
        self.depth += 1;
        if (self.depth > self.max_depth) return error.SyntaxError;
        defer self.depth -= 1;

        var items: std.ArrayList(Form) = .empty;
        errdefer items.deinit(self.allocator);

        while (true) {
            const tok = self.nextToken();
            if (tok.kind == .eof) return error.SyntaxError;
            if (tok.kind == closing) break;
            const form = try self.readForm(tok);
            items.append(self.allocator, form) catch return error.OutOfMemory;
        }
        return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // --- Reader macros ---

    fn readQuote(self: *Reader, tok: Token) ReadError!Form {
        self.depth += 1;
        if (self.depth > self.max_depth) return error.SyntaxError;
        defer self.depth -= 1;

        const next = self.nextToken();
        if (next.kind == .eof) return error.SyntaxError;
        const inner = try self.readForm(next);

        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .name = "quote" } }, .line = tok.line, .column = tok.column };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .line = tok.line, .column = tok.column };
    }

    fn readSymbolic(self: *Reader, tok: Token) ReadError!Form {
        const next = self.nextToken();
        if (next.kind == .eof) return error.SyntaxError;
        const txt = next.text(self.source);
        if (std.mem.eql(u8, txt, "Inf")) {
            return Form{ .data = .{ .float = std.math.inf(f64) }, .line = tok.line, .column = tok.column };
        }
        if (std.mem.eql(u8, txt, "-Inf")) {
            return Form{ .data = .{ .float = -std.math.inf(f64) }, .line = tok.line, .column = tok.column };
        }
        if (std.mem.eql(u8, txt, "NaN")) {
            return Form{ .data = .{ .float = std.math.nan(f64) }, .line = tok.line, .column = tok.column };
        }
        return error.SyntaxError;
    }

    fn readDiscard(self: *Reader, tok: Token) ReadError!Form {
        _ = tok;
        // Read and discard the next form
        const next = self.nextToken();
        if (next.kind == .eof) return error.SyntaxError;
        _ = try self.readForm(next);
        // Return the following form (or signal EOF)
        return try self.read() orelse error.SyntaxError;
    }

    // --- String unescaping ---

    fn unescapeString(self: *Reader, s: []const u8) ![]const u8 {
        // Fast path: no escapes
        if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\') {
                i += 1;
                if (i >= s.len) return error.StringError;
                switch (s[i]) {
                    'n' => try buf.append(self.allocator, '\n'),
                    't' => try buf.append(self.allocator, '\t'),
                    'r' => try buf.append(self.allocator, '\r'),
                    '\\' => try buf.append(self.allocator, '\\'),
                    '"' => try buf.append(self.allocator, '"'),
                    'b' => try buf.append(self.allocator, 0x08),
                    'f' => try buf.append(self.allocator, 0x0C),
                    'u' => {
                        // \uXXXX
                        if (i + 4 >= s.len) return error.StringError;
                        const hex = s[i + 1 .. i + 5];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return error.StringError;
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return error.StringError;
                        for (utf8_buf[0..len]) |b| {
                            try buf.append(self.allocator, b);
                        }
                        i += 4;
                    },
                    else => return error.StringError,
                }
                i += 1;
            } else {
                try buf.append(self.allocator, s[i]);
                i += 1;
            }
        }
        return buf.toOwnedSlice(self.allocator);
    }

    // --- Token helpers ---

    fn nextToken(self: *Reader) Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.tokenizer.next();
    }

    fn peekToken(self: *Reader) Token {
        if (self.peeked == null) {
            self.peeked = self.tokenizer.next();
        }
        return self.peeked.?;
    }
};

// --- Symbol parsing helper ---

fn parseSymbolRef(txt: []const u8) SymbolRef {
    if (std.mem.indexOfScalar(u8, txt, '/')) |idx| {
        // "/" alone is a valid symbol
        if (idx == 0 and txt.len == 1) {
            return .{ .name = txt };
        }
        return .{ .ns = txt[0..idx], .name = txt[idx + 1 ..] };
    }
    return .{ .name = txt };
}

/// Convenience: read a single form from source text.
pub fn readString(allocator: std.mem.Allocator, source: []const u8) ReadError!?Form {
    var reader = Reader.init(allocator, source);
    return reader.read();
}

/// Convenience: read all forms from source text.
pub fn readAllForms(allocator: std.mem.Allocator, source: []const u8) ReadError![]Form {
    var reader = Reader.init(allocator, source);
    return reader.readAll();
}

// --- Tests ---

const testing = std.testing;

/// Test helper: arena-backed reader for leak-free tests.
const TestCtx = struct {
    arena: std.heap.ArenaAllocator,

    fn init() TestCtx {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
    fn deinit(self: *TestCtx) void {
        self.arena.deinit();
    }
    fn readOne(self: *TestCtx, source: []const u8) ReadError!Form {
        var reader = Reader.init(self.arena.allocator(), source);
        return try reader.read() orelse error.SyntaxError;
    }
    fn readOneErr(self: *TestCtx, source: []const u8) ReadError!Form {
        return self.readOne(source);
    }
    fn formToStr(self: *TestCtx, form: Form) ![]u8 {
        return form.toString(self.arena.allocator());
    }
};

test "read nil" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("nil");
    try testing.expectEqualStrings("nil", f.typeName());
}

test "read true" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("true");
    try testing.expect(f.isTruthy());
    const s = try ctx.formToStr(f);
    try testing.expectEqualStrings("true", s);
}

test "read false" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("false");
    try testing.expect(!f.isTruthy());
}

test "read integer" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("42");
    try testing.expectEqual(@as(i64, 42), f.data.integer);
}

test "read negative integer" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("-7");
    try testing.expectEqual(@as(i64, -7), f.data.integer);
}

test "read hex integer" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("0xFF");
    try testing.expectEqual(@as(i64, 255), f.data.integer);
}

test "read float" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("3.14");
    try testing.expectApproxEqAbs(@as(f64, 3.14), f.data.float, 1e-10);
}

test "read float exponent" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("1e10");
    try testing.expectApproxEqAbs(@as(f64, 1e10), f.data.float, 1.0);
}

test "read string" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("\"hello\"");
    try testing.expectEqualStrings("hello", f.data.string);
}

test "read string with escapes" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("\"hello\\nworld\"");
    try testing.expectEqualStrings("hello\nworld", f.data.string);
}

test "read string with unicode escape" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("\"\\u0041\"");
    try testing.expectEqualStrings("A", f.data.string);
}

test "read symbol" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("foo");
    try testing.expectEqualStrings("foo", f.data.symbol.name);
    try testing.expectEqual(@as(?[]const u8, null), f.data.symbol.ns);
}

test "read qualified symbol" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("clojure.core/map");
    try testing.expectEqualStrings("clojure.core", f.data.symbol.ns.?);
    try testing.expectEqualStrings("map", f.data.symbol.name);
}

test "read keyword" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne(":foo");
    try testing.expectEqualStrings("foo", f.data.keyword.name);
}

test "read qualified keyword" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne(":my.ns/bar");
    try testing.expectEqualStrings("my.ns", f.data.keyword.ns.?);
    try testing.expectEqualStrings("bar", f.data.keyword.name);
}

test "read empty list" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("()");
    try testing.expectEqual(@as(usize, 0), f.data.list.len);
}

test "read list (+ 1 2)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("(+ 1 2)");
    try testing.expectEqual(@as(usize, 3), f.data.list.len);
    try testing.expectEqualStrings("+", f.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), f.data.list[1].data.integer);
    try testing.expectEqual(@as(i64, 2), f.data.list[2].data.integer);
}

test "read vector" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("[1 2 3]");
    try testing.expectEqual(@as(usize, 3), f.data.vector.len);
}

test "read map" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("{:a 1 :b 2}");
    try testing.expectEqual(@as(usize, 4), f.data.map.len);
}

test "read odd map elements is error" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const result = ctx.readOne("{:a 1 :b}");
    try testing.expectError(error.SyntaxError, result);
}

test "read nested structure" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("(defn f [x] (+ x 1))");
    try testing.expectEqual(@as(usize, 4), f.data.list.len);
    try testing.expectEqual(@as(usize, 1), f.data.list[2].data.vector.len);
    try testing.expectEqual(@as(usize, 3), f.data.list[3].data.list.len);
}

test "read quote" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("'foo");
    try testing.expectEqual(@as(usize, 2), f.data.list.len);
    try testing.expectEqualStrings("quote", f.data.list[0].data.symbol.name);
    try testing.expectEqualStrings("foo", f.data.list[1].data.symbol.name);
}

test "read ##Inf" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("##Inf");
    try testing.expect(std.math.isPositiveInf(f.data.float));
}

test "read ##-Inf" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("##-Inf");
    try testing.expect(std.math.isNegativeInf(f.data.float));
}

test "read ##NaN" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("##NaN");
    try testing.expect(std.math.isNan(f.data.float));
}

test "read discard" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("#_foo 42");
    try testing.expectEqual(@as(i64, 42), f.data.integer);
}

test "read multiple forms" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    var reader = Reader.init(ctx.arena.allocator(), "1 2 3");
    const forms = try reader.readAll();
    try testing.expectEqual(@as(usize, 3), forms.len);
}

test "round-trip (+ 1 2)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("(+ 1 2)");
    const s = try ctx.formToStr(f);
    try testing.expectEqualStrings("(+ 1 2)", s);
}

test "round-trip [1 :a \"b\"]" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("[1 :a \"b\"]");
    const s = try ctx.formToStr(f);
    try testing.expectEqualStrings("[1 :a \"b\"]", s);
}

test "round-trip {:k 1}" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("{:k 1}");
    const s = try ctx.formToStr(f);
    try testing.expectEqualStrings("{:k 1}", s);
}

test "unmatched rparen is error" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const result = ctx.readOne(")");
    try testing.expectError(error.SyntaxError, result);
}

test "unterminated list is error" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const result = ctx.readOne("(1 2");
    try testing.expectError(error.SyntaxError, result);
}

test "source location preserved" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("  42");
    try testing.expectEqual(@as(u32, 1), f.line);
    try testing.expectEqual(@as(u16, 2), f.column);
}

test "comment skipped" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("; comment\n42");
    try testing.expectEqual(@as(i64, 42), f.data.integer);
}

test "comma separated" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("[1, 2, 3]");
    try testing.expectEqual(@as(usize, 3), f.data.vector.len);
}

test "read / symbol" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.readOne("/");
    try testing.expectEqualStrings("/", f.data.symbol.name);
    try testing.expectEqual(@as(?[]const u8, null), f.data.symbol.ns);
}

test "read + - symbols" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    {
        const f = try ctx.readOne("+");
        try testing.expectEqualStrings("+", f.data.symbol.name);
    }
    {
        const f = try ctx.readOne("-");
        try testing.expectEqualStrings("-", f.data.symbol.name);
    }
}
