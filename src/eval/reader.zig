//! Reader — token stream → Form AST.
//!
//! Phase-1 scope: nil / boolean / integer / float / string / symbol /
//! keyword / list / vector / map, plus the reader macros `'`, `##`,
//! `#_`, and `#!` shebang. Syntax-quote / unquote / unquote-splicing /
//! metadata / regex / `#()` / `#'` / `#inst` / `#uuid` ship in later
//! phases.
//!
//! Allocations land in the caller-supplied allocator. Tests pin one
//! arena per test so leaks are impossible by construction; production
//! callers will hand in `Runtime.node_arena` once Phase 2 lands.

const std = @import("std");
const form_mod = @import("form.zig");
const Form = form_mod.Form;
const SymbolRef = form_mod.SymbolRef;
const tok_mod = @import("tokenizer.zig");
const Tokenizer = tok_mod.Tokenizer;
const Token = tok_mod.Token;
const TokenKind = tok_mod.TokenKind;
const SourceLocation = @import("../runtime/error.zig").SourceLocation;

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
    /// One-token lookahead buffer.
    peeked: ?Token = null,
    /// Tracks nesting so accidental input like `(((((((...` doesn't
    /// blow the stack via `readForm` recursion.
    depth: u32 = 0,
    max_depth: u32 = 1024,
    /// Optional file name; embedded into every emitted Form's location.
    file_name: []const u8 = "unknown",

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
        };
    }

    /// Read one Form. Returns `null` on clean EOF.
    pub fn read(self: *Reader) ReadError!?Form {
        const tok = self.nextToken();
        if (tok.kind == .eof) return null;
        return try self.readForm(tok);
    }

    /// Read until EOF, returning a slice owned by `self.allocator`.
    pub fn readAll(self: *Reader) ReadError![]Form {
        var forms: std.ArrayList(Form) = .empty;
        errdefer forms.deinit(self.allocator);
        while (true) {
            const f = try self.read() orelse break;
            forms.append(self.allocator, f) catch return error.OutOfMemory;
        }
        return forms.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn locOf(self: *const Reader, tok: Token) SourceLocation {
        return .{ .file = self.file_name, .line = tok.line, .column = tok.column };
    }

    // --- core dispatch ---

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
            .rparen, .rbracket, .rbrace, .eof, .invalid => error.SyntaxError,
        };
    }

    // --- atoms ---

    fn readSymbol(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const loc = self.locOf(tok);
        if (std.mem.eql(u8, txt, "nil")) return Form{ .data = .nil, .location = loc };
        if (std.mem.eql(u8, txt, "true")) return Form{ .data = .{ .boolean = true }, .location = loc };
        if (std.mem.eql(u8, txt, "false")) return Form{ .data = .{ .boolean = false }, .location = loc };
        return Form{ .data = .{ .symbol = parseSymbolRef(txt) }, .location = loc };
    }

    fn readInteger(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        var s = txt;
        // Phase 1 accepts the BigInt `N` suffix syntactically without
        // preserving precision — strip it before std.fmt parses.
        if (s.len > 0 and s[s.len - 1] == 'N') s = s[0 .. s.len - 1];
        const val = std.fmt.parseInt(i64, s, 0) catch return error.NumberError;
        return Form{ .data = .{ .integer = val }, .location = self.locOf(tok) };
    }

    fn readFloat(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        var s = txt;
        if (s.len > 0 and s[s.len - 1] == 'M') s = s[0 .. s.len - 1];
        const val = std.fmt.parseFloat(f64, s) catch return error.NumberError;
        return Form{ .data = .{ .float = val }, .location = self.locOf(tok) };
    }

    fn readString(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        if (txt.len < 2) return error.StringError;
        const content = txt[1 .. txt.len - 1];
        const unescaped = self.unescapeString(content) catch return error.StringError;
        return Form{ .data = .{ .string = unescaped }, .location = self.locOf(tok) };
    }

    fn readKeyword(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source)[1..]; // drop leading ':'
        return Form{ .data = .{ .keyword = parseSymbolRef(txt) }, .location = self.locOf(tok) };
    }

    // --- collections ---

    fn readList(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rparen);
        return Form{ .data = .{ .list = items }, .location = self.locOf(tok) };
    }

    fn readVector(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rbracket);
        return Form{ .data = .{ .vector = items }, .location = self.locOf(tok) };
    }

    fn readMap(self: *Reader, tok: Token) ReadError!Form {
        const items = try self.readDelimited(.rbrace);
        // Maps must have an even number of elements at read time so the
        // analyzer can iterate `[k0 v0 k1 v1 ...]` without re-checking.
        if (items.len % 2 != 0) return error.SyntaxError;
        return Form{ .data = .{ .map = items }, .location = self.locOf(tok) };
    }

    fn readDelimited(self: *Reader, closing: TokenKind) ReadError![]const Form {
        self.depth += 1;
        if (self.depth > self.max_depth) return error.SyntaxError;
        defer self.depth -= 1;

        var items: std.ArrayList(Form) = .empty;
        errdefer items.deinit(self.allocator);

        while (true) {
            const tok = self.nextToken();
            if (tok.kind == .eof) return error.SyntaxError;
            if (tok.kind == closing) break;
            const f = try self.readForm(tok);
            items.append(self.allocator, f) catch return error.OutOfMemory;
        }
        return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // --- reader macros ---

    fn readQuote(self: *Reader, tok: Token) ReadError!Form {
        self.depth += 1;
        if (self.depth > self.max_depth) return error.SyntaxError;
        defer self.depth -= 1;

        const next_tok = self.nextToken();
        if (next_tok.kind == .eof) return error.SyntaxError;
        const inner = try self.readForm(next_tok);

        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        const loc = self.locOf(tok);
        items[0] = Form{ .data = .{ .symbol = .{ .name = "quote" } }, .location = loc };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .location = loc };
    }

    fn readSymbolic(self: *Reader, tok: Token) ReadError!Form {
        const next_tok = self.nextToken();
        if (next_tok.kind == .eof) return error.SyntaxError;
        const txt = next_tok.text(self.source);
        const loc = self.locOf(tok);
        if (std.mem.eql(u8, txt, "Inf")) return Form{ .data = .{ .float = std.math.inf(f64) }, .location = loc };
        if (std.mem.eql(u8, txt, "-Inf")) return Form{ .data = .{ .float = -std.math.inf(f64) }, .location = loc };
        if (std.mem.eql(u8, txt, "NaN")) return Form{ .data = .{ .float = std.math.nan(f64) }, .location = loc };
        return error.SyntaxError;
    }

    fn readDiscard(self: *Reader, tok: Token) ReadError!Form {
        _ = tok;
        const next_tok = self.nextToken();
        if (next_tok.kind == .eof) return error.SyntaxError;
        _ = try self.readForm(next_tok);
        return try self.read() orelse error.SyntaxError;
    }

    // --- string unescaping ---

    fn unescapeString(self: *Reader, s: []const u8) ![]const u8 {
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
                        if (i + 4 >= s.len) return error.StringError;
                        const hex = s[i + 1 .. i + 5];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return error.StringError;
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return error.StringError;
                        for (utf8_buf[0..len]) |b| try buf.append(self.allocator, b);
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

    // --- token helpers ---

    fn nextToken(self: *Reader) Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.tokenizer.next();
    }
};

// --- helpers ---

fn parseSymbolRef(txt: []const u8) SymbolRef {
    if (std.mem.indexOfScalar(u8, txt, '/')) |idx| {
        // `/` alone is the division symbol — keep it as a bare name.
        if (idx == 0 and txt.len == 1) return .{ .name = txt };
        return .{ .ns = txt[0..idx], .name = txt[idx + 1 ..] };
    }
    return .{ .name = txt };
}

/// Convenience: read a single form from source text.
pub fn readOne(allocator: std.mem.Allocator, source: []const u8) ReadError!?Form {
    var reader = Reader.init(allocator, source);
    return reader.read();
}

/// Convenience: read all forms from source text.
pub fn readAll(allocator: std.mem.Allocator, source: []const u8) ReadError![]Form {
    var reader = Reader.init(allocator, source);
    return reader.readAll();
}

// --- tests ---

const testing = std.testing;

const TestCtx = struct {
    arena: std.heap.ArenaAllocator,

    fn init() TestCtx {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
    fn deinit(self: *TestCtx) void {
        self.arena.deinit();
    }
    fn read(self: *TestCtx, source: []const u8) ReadError!Form {
        var r = Reader.init(self.arena.allocator(), source);
        return try r.read() orelse error.SyntaxError;
    }
    fn pr(self: *TestCtx, f: Form) ![]u8 {
        return f.toString(self.arena.allocator());
    }
};

test "atoms: nil / true / false / int / float / string / symbol / keyword" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqualStrings("nil", (try ctx.read("nil")).typeName());
    try testing.expect((try ctx.read("true")).isTruthy());
    try testing.expect(!(try ctx.read("false")).isTruthy());

    try testing.expectEqual(@as(i64, 42), (try ctx.read("42")).data.integer);
    try testing.expectEqual(@as(i64, -7), (try ctx.read("-7")).data.integer);
    try testing.expectEqual(@as(i64, 255), (try ctx.read("0xFF")).data.integer);

    try testing.expectApproxEqAbs(@as(f64, 3.14), (try ctx.read("3.14")).data.float, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1e10), (try ctx.read("1e10")).data.float, 1.0);

    try testing.expectEqualStrings("hello", (try ctx.read("\"hello\"")).data.string);

    const sym = try ctx.read("foo");
    try testing.expectEqualStrings("foo", sym.data.symbol.name);
    try testing.expect(sym.data.symbol.ns == null);

    const qsym = try ctx.read("clojure.core/map");
    try testing.expectEqualStrings("clojure.core", qsym.data.symbol.ns.?);
    try testing.expectEqualStrings("map", qsym.data.symbol.name);

    try testing.expectEqualStrings("foo", (try ctx.read(":foo")).data.keyword.name);
    const qkw = try ctx.read(":my.ns/bar");
    try testing.expectEqualStrings("my.ns", qkw.data.keyword.ns.?);
    try testing.expectEqualStrings("bar", qkw.data.keyword.name);
}

test "string escape sequences and unicode" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqualStrings("hello\nworld", (try ctx.read("\"hello\\nworld\"")).data.string);
    try testing.expectEqualStrings("A", (try ctx.read("\"\\u0041\"")).data.string);
}

test "collections: list / vector / map" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const empty = try ctx.read("()");
    try testing.expectEqual(@as(usize, 0), empty.data.list.len);

    const lst = try ctx.read("(+ 1 2)");
    try testing.expectEqual(@as(usize, 3), lst.data.list.len);
    try testing.expectEqualStrings("+", lst.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), lst.data.list[1].data.integer);
    try testing.expectEqual(@as(i64, 2), lst.data.list[2].data.integer);

    try testing.expectEqual(@as(usize, 3), (try ctx.read("[1 2 3]")).data.vector.len);
    try testing.expectEqual(@as(usize, 4), (try ctx.read("{:a 1 :b 2}")).data.map.len);

    try testing.expectError(error.SyntaxError, ctx.read("{:a 1 :b}"));
}

test "nested defn round-trips structurally" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.read("(defn f [x] (+ x 1))");
    try testing.expectEqual(@as(usize, 4), f.data.list.len);
    try testing.expectEqual(@as(usize, 1), f.data.list[2].data.vector.len);
    try testing.expectEqual(@as(usize, 3), f.data.list[3].data.list.len);
}

test "reader macros: quote / ##Inf / ##-Inf / ##NaN / #_" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const q = try ctx.read("'foo");
    try testing.expectEqual(@as(usize, 2), q.data.list.len);
    try testing.expectEqualStrings("quote", q.data.list[0].data.symbol.name);
    try testing.expectEqualStrings("foo", q.data.list[1].data.symbol.name);

    try testing.expect(std.math.isPositiveInf((try ctx.read("##Inf")).data.float));
    try testing.expect(std.math.isNegativeInf((try ctx.read("##-Inf")).data.float));
    try testing.expect(std.math.isNan((try ctx.read("##NaN")).data.float));

    try testing.expectEqual(@as(i64, 42), (try ctx.read("#_foo 42")).data.integer);
}

test "readAll yields multiple top-level forms" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    var r = Reader.init(ctx.arena.allocator(), "1 2 3");
    const forms = try r.readAll();
    try testing.expectEqual(@as(usize, 3), forms.len);
}

test "round-trip: print(read(s)) == s for canonical inputs" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqualStrings("(+ 1 2)", try ctx.pr(try ctx.read("(+ 1 2)")));
    try testing.expectEqualStrings("[1 :a \"b\"]", try ctx.pr(try ctx.read("[1 :a \"b\"]")));
    try testing.expectEqualStrings("{:k 1}", try ctx.pr(try ctx.read("{:k 1}")));
}

test "syntax errors: stray `)`, unterminated `(`, and ungrouped EOF" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    try testing.expectError(error.SyntaxError, ctx.read(")"));
    try testing.expectError(error.SyntaxError, ctx.read("(1 2"));
}

test "source location is preserved" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const f = try ctx.read("  42");
    try testing.expectEqual(@as(u32, 1), f.location.line);
    try testing.expectEqual(@as(u16, 2), f.location.column);
}

test "comments and commas don't disrupt reading" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    try testing.expectEqual(@as(i64, 42), (try ctx.read("; comment\n42")).data.integer);
    try testing.expectEqual(@as(usize, 3), (try ctx.read("[1, 2, 3]")).data.vector.len);
}

test "bare `/` is a symbol; `+` and `-` are symbols" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    try testing.expectEqualStrings("/", (try ctx.read("/")).data.symbol.name);
    try testing.expectEqualStrings("+", (try ctx.read("+")).data.symbol.name);
    try testing.expectEqualStrings("-", (try ctx.read("-")).data.symbol.name);
}
