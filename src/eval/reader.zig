//! Reader — token stream → Form AST.
//!
//! Scope: nil / boolean / integer / float / string / symbol / keyword /
//! list / vector / map, plus the reader macros `'`, `##`, `#_`, the
//! `#!` shebang, syntax-quote / unquote / unquote-splicing, metadata
//! `^`, regex `#"re"`, `#()` fn literals, `#'` var-quote, and tagged
//! literals `#inst` / `#uuid` (via `readTagged`).
//!
//! Allocations land in the caller-supplied allocator. Tests pin one
//! arena per test so leaks are impossible by construction; production
//! callers hand in `Runtime.node_arena`.

const std = @import("std");
const form_mod = @import("form.zig");
const Form = form_mod.Form;
const SymbolRef = form_mod.SymbolRef;
const tok_mod = @import("tokenizer.zig");
const Tokenizer = tok_mod.Tokenizer;
const Token = tok_mod.Token;
const TokenKind = tok_mod.TokenKind;
const error_mod = @import("../runtime/error/info.zig");
const error_catalog = @import("../runtime/error/catalog.zig");
const string_escape = @import("../runtime/string_escape.zig");
const SourceLocation = error_mod.SourceLocation;

/// Reader error surface. Aliases `error_mod.ClojureWasmError` so that
/// the `error_catalog.raise(.code, loc, args)` rendezvous (which
/// returns the full `ClojureWasmError` enum) is type-compatible.
/// Callers continue to match on the specific tags `SyntaxError` /
/// `NumberError` / `StringError` / `OutOfMemory` — the wider set
/// just admits future kinds without churning every signature.
pub const ReadError = error_mod.ClojureWasmError;

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
    /// True while reading a `#(...)` body, so a nested `#(` is rejected
    /// (JVM-compatible — `%` would be ambiguous across levels). D-146.
    in_fn_lit: bool = false,
    /// Whether `#?`/`#?@` reader conditionals are permitted (D-457(3)). Default
    /// TRUE = source-loading context (require/load/eval of a .clj(c) file allows
    /// `#?`, clj-faithful). The DATA-read path (`read-string`) flips this FALSE so
    /// `#?` is rejected with "Conditional read not allowed" unless the caller opts
    /// in via `:read-cond :allow` — matching clj, which disallows `#?` in plain
    /// `read`/`read-string`. Defaulting TRUE keeps every existing source-load
    /// Reader.init site unchanged (no risk of breaking .cljc load).
    allow_reader_cond: bool = true,
    /// Set by reader macros that contribute NO value (`#_` discard, a
    /// non-matching `#?`). `readValue` observes it to skip the slot and
    /// keep reading, rather than the macro recursing into the next form
    /// (which broke at a trailing closing delimiter — `[1 #_2]`).
    skip: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
        };
    }

    /// Read one Form. Returns `null` on clean EOF.
    pub fn read(self: *Reader) ReadError!?Form {
        if (try self.readValue()) |f| return f;
        // readValue stopped at a boundary token (left in the peek buffer):
        // clean EOF → null; a stray closing delimiter at top level → error.
        const tok = self.nextToken();
        if (tok.kind == .eof) return null;
        return error_catalog.raise(.delimiter_unexpected, self.locOf(tok), .{ .delim = tok.text(self.source) });
    }

    /// Read the next value, transparently skipping reader macros that
    /// contribute no value (`#_` discard, a non-matching `#?`). Returns
    /// `null` when the next significant token is a closing delimiter or
    /// EOF; that boundary token is left in the peek buffer for the caller
    /// to classify (break a collection, end the stream, or error). This is
    /// the single "read a form" primitive — every site that needs one form
    /// routes through here so `#_`/`#?` skip uniformly, including before a
    /// trailing closer (`[1 #_2]` → `[1]`).
    fn readValue(self: *Reader) ReadError!?Form {
        while (true) {
            const tok = self.peekToken();
            switch (tok.kind) {
                .eof, .rparen, .rbracket, .rbrace => return null,
                else => {},
            }
            _ = self.nextToken(); // consume the peeked token
            const f = try self.readForm(tok);
            if (self.skip) {
                self.skip = false;
                continue;
            }
            return f;
        }
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
            .big_int_literal => self.readBigIntLiteral(tok),
            .big_decimal_literal => self.readBigDecimalLiteral(tok),
            .ratio_literal => self.readRatioLiteral(tok),
            .string => self.readString(tok),
            .char_lit => self.readCharLiteral(tok),
            .regex_literal => self.readRegexLiteral(tok),
            .keyword => self.readKeyword(tok),
            .lparen => self.readList(tok),
            .lbracket => self.readVector(tok),
            .lbrace => self.readMap(tok),
            .set_open => self.readSet(tok),
            .fn_lit => self.readFnLit(tok),
            .quote => self.readQuote(tok),
            .deref => self.readDeref(tok),
            .var_quote => self.readVarQuote(tok),
            .tagged => self.readTagged(tok),
            .ns_map => self.readNsMap(tok),
            .syntax_quote => self.readWrapped(tok, .syntax_quote),
            .unquote => self.readWrapped(tok, .unquote),
            .unquote_splicing => self.readWrapped(tok, .unquote_splicing),
            .meta_caret => self.readMeta(tok),
            .symbolic => self.readSymbolic(tok),
            .discard => self.readDiscard(tok),
            .reader_cond => self.readReaderConditional(tok),
            // A splice reached here means it is NOT inside a collection
            // (readDelimited intercepts the in-collection case) — top level or
            // a reader-macro position, which clj rejects.
            .reader_cond_splice => error_catalog.raise(.reader_cond_splice_top_level, self.locOf(tok), .{}),
            .rparen, .rbracket, .rbrace => error_catalog.raise(.delimiter_unexpected, self.locOf(tok), .{ .delim = tok.text(self.source) }),
            .eof => error_catalog.raise(.eof_unexpected, self.locOf(tok), .{}),
            .invalid => error_catalog.raise(.token_invalid, self.locOf(tok), .{ .token = tok.text(self.source) }),
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
        // Radix literal `[+-]?<base>[rR]<mantissa>` (base 2..36, digits
        // 0-9a-zA-Z), e.g. 2r1010=10, 16rFF=255, 36rZ=35, -16rFF=-255. The
        // `0x`/`0o`/`0b` prefixed forms never contain `r`, so a present `r`/`R`
        // unambiguously marks the radix form.
        if (radixSepIndex(txt)) |_| return self.readRadixInteger(tok);
        // Octal literal `[+-]?0<octal-digits>` (clj/Java: a leading `0` followed
        // by more digits is base 8 — `017`=15, `-010`=-8; an `8`/`9` digit is a
        // NumberFormatException). `0x…` hex and a bare `0` stay on the parseInt
        // base-0 path below; floats (`0.5`) never reach readInteger.
        if (octalDigits(txt)) |oct|
            return self.readOctalInteger(tok, oct.neg, oct.digits);
        const val = std.fmt.parseInt(i64, txt, 0) catch |e| {
            // A literal that overflows i64 auto-promotes to BigInt (Clojure: an
            // integer literal too large for Long reads as clojure.lang.BigInt).
            // Decimal: parseBase10 over the digit text. Hex (D-297): clj reads a
            // `0x…` literal as its unsigned MAGNITUDE (`0xffffffffffffffff` →
            // 18446744073709551615N, NOT -1), so promote via the base-16
            // mul/add path — needed by hashing/RNG libs (test.check splitmix).
            if (e == error.Overflow) {
                if (isPlainDecimal(txt))
                    return Form{ .data = .{ .big_int_literal = txt }, .location = self.locOf(tok) };
                if (hexDigits(txt)) |hx|
                    return self.radixBigIntForm(self.locOf(tok), hx.digits, 16, hx.neg);
            }
            return error_catalog.raise(.integer_literal_invalid, self.locOf(tok), .{ .text = txt });
        };
        return Form{ .data = .{ .integer = val }, .location = self.locOf(tok) };
    }

    /// Classify `txt` as a hex literal `[+-]?0[xX]<hex-digits>` for the
    /// overflow→BigInt path (D-297). Returns the sign + the post-`0x` digit run.
    fn hexDigits(txt: []const u8) ?struct { neg: bool, digits: []const u8 } {
        var t = txt;
        var neg = false;
        if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
            neg = t[0] == '-';
            t = t[1..];
        }
        if (t.len < 3 or t[0] != '0' or (t[1] != 'x' and t[1] != 'X')) return null;
        return .{ .neg = neg, .digits = t[2..] };
    }

    /// Classify `txt` as an octal literal `[+-]?0<digits>` (≥ 1 digit after the
    /// leading `0`, and not a `0x`/`0X` hex prefix). Returns the sign + the
    /// post-`0` digit run (which may include an out-of-range 8/9 that
    /// `readOctalInteger` then rejects). `null` for `0` alone, `0x…`, or any
    /// non-`0`-led integer.
    fn octalDigits(txt: []const u8) ?struct { neg: bool, digits: []const u8 } {
        var t = txt;
        var neg = false;
        if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
            neg = t[0] == '-';
            t = t[1..];
        }
        if (t.len < 2 or t[0] != '0') return null;
        if (t[1] == 'x' or t[1] == 'X') return null; // hex, not octal
        return .{ .neg = neg, .digits = t[1..] };
    }

    /// Parse a leading-`0` octal literal into an `.integer` (or `.big_int_literal`
    /// past i64). A digit ≥ 8 is a clj NumberFormatException (`integer_literal_invalid`).
    fn readOctalInteger(self: *Reader, tok: Token, neg: bool, digits: []const u8) ReadError!Form {
        const loc = self.locOf(tok);
        for (digits) |c| {
            if (c < '0' or c > '7')
                return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = tok.text(self.source) });
        }
        const val = std.fmt.parseInt(i64, digits, 8) catch |e| {
            if (e == error.Overflow) return self.radixBigIntForm(loc, digits, 8, neg);
            return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = tok.text(self.source) });
        };
        return Form{ .data = .{ .integer = if (neg) -val else val }, .location = loc };
    }

    /// Byte index of the `r`/`R` separator in a radix literal
    /// `[+-]?<decimal-base>[rR]…`, or null if `txt` is not that shape.
    fn radixSepIndex(txt: []const u8) ?usize {
        var i: usize = 0;
        if (i < txt.len and (txt[i] == '-' or txt[i] == '+')) i += 1;
        const base_start = i;
        while (i < txt.len and txt[i] >= '0' and txt[i] <= '9') i += 1;
        if (i == base_start) return null; // no base digits
        if (i < txt.len and (txt[i] == 'r' or txt[i] == 'R')) return i;
        return null;
    }

    /// Parse a validated radix literal into an `.integer` (i48/i64) Form, or a
    /// `.big_int_literal` Form when the value exceeds i64.
    fn readRadixInteger(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const loc = self.locOf(tok);
        var body = txt;
        var neg = false;
        if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
            neg = body[0] == '-';
            body = body[1..];
        }
        var ri: usize = 0;
        while (ri < body.len and body[ri] >= '0' and body[ri] <= '9') ri += 1;
        const base = std.fmt.parseInt(u8, body[0..ri], 10) catch
            return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = txt });
        const mantissa = body[ri + 1 ..];
        if (base < 2 or base > 36 or mantissa.len == 0)
            return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = txt });

        const val = std.fmt.parseInt(i64, mantissa, base) catch |e| {
            if (e == error.Overflow)
                return self.radixBigIntForm(loc, mantissa, base, neg);
            return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = txt });
        };
        return Form{ .data = .{ .integer = if (neg) -val else val }, .location = loc };
    }

    /// A radix literal whose value exceeds i64 promotes to BigInt. Convert the
    /// base-N mantissa to a decimal digit string (platform-safe mul/add, not
    /// `setString` — D-047) so the analyzer's base-10 BigInt path parses it.
    fn radixBigIntForm(self: *Reader, loc: error_mod.SourceLocation, mantissa: []const u8, base: u8, neg: bool) ReadError!Form {
        var acc = std.math.big.int.Managed.initSet(self.allocator, 0) catch return error.OutOfMemory;
        defer acc.deinit();
        var b = std.math.big.int.Managed.initSet(self.allocator, base) catch return error.OutOfMemory;
        defer b.deinit();
        var scratch = std.math.big.int.Managed.init(self.allocator) catch return error.OutOfMemory;
        defer scratch.deinit();
        for (mantissa) |c| {
            const d = std.fmt.charToDigit(c, base) catch
                return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = mantissa });
            scratch.mul(&acc, &b) catch return error.OutOfMemory;
            acc.addScalar(&scratch, d) catch return error.OutOfMemory;
        }
        const dec = acc.toString(self.allocator, 10, .lower) catch return error.OutOfMemory;
        const digits = if (neg)
            std.fmt.allocPrint(self.allocator, "-{s}", .{dec}) catch return error.OutOfMemory
        else
            dec;
        return Form{ .data = .{ .big_int_literal = digits }, .location = loc };
    }

    /// True when `txt` is an optionally-signed run of base-10 digits
    /// (no `0x`/`0o`/`0b` radix prefix) — the shape `parseBase10` accepts.
    fn isPlainDecimal(txt: []const u8) bool {
        var t = txt;
        if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t = t[1..];
        if (t.len == 0) return false;
        for (t) |c| if (c < '0' or c > '9') return false;
        return true;
    }

    fn readFloat(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const val = std.fmt.parseFloat(f64, txt) catch
            return error_catalog.raise(.float_literal_invalid, self.locOf(tok), .{ .text = txt });
        return Form{ .data = .{ .float = val }, .location = self.locOf(tok) };
    }

    /// `42N` — keep the digit string without the trailing `N`. The
    /// analyzer parses it into a BigInt via Managed.setString.
    fn readBigIntLiteral(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        // Strip the trailing `N` (tokenizer guarantees it's there).
        const digits = txt[0 .. txt.len - 1];
        return Form{ .data = .{ .big_int_literal = digits }, .location = self.locOf(tok) };
    }

    /// `1.5M` — keep the decimal string without the trailing `M`.
    fn readBigDecimalLiteral(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const digits = txt[0 .. txt.len - 1];
        return Form{ .data = .{ .big_decimal_literal = digits }, .location = self.locOf(tok) };
    }

    /// `1/3` — keep the full `num/den` digit pair; analyzer splits.
    fn readRatioLiteral(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        return Form{ .data = .{ .ratio_literal = txt }, .location = self.locOf(tok) };
    }

    fn readString(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const loc = self.locOf(tok);
        if (txt.len < 2)
            return error_catalog.raise(.string_unterminated, loc, .{});
        const content = txt[1 .. txt.len - 1];
        const unescaped = self.unescapeString(content, loc) catch |err| {
            // unescapeString already populated last_error for StringError.
            return err;
        };
        return Form{ .data = .{ .string = unescaped }, .location = loc };
    }

    /// Decode a `\<body>` character-literal token into a `.char` Form. The
    /// body (token text minus the leading `\`) is one of: a single codepoint
    /// (`\a`, `\(`, `\λ`); a named char (`\newline`/`\space`/`\tab`/`\return`/
    /// `\backspace`/`\formfeed`); `\uXXXX` (4 hex); or `\oNNN` (octal).
    fn readCharLiteral(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const loc = self.locOf(tok);
        if (txt.len < 2)
            return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
        const body = txt[1..];
        const cp: u21 = blk: {
            // A single UTF-8 codepoint that spans the whole body is a
            // single-char literal (covers `\a`, `\(`, `\,`, `\λ`).
            const first_len = std.unicode.utf8ByteSequenceLength(body[0]) catch 1;
            if (first_len == body.len)
                break :blk switch (body.len) {
                    2 => std.unicode.utf8Decode2(body[0..2].*) catch body[0],
                    3 => std.unicode.utf8Decode3(body[0..3].*) catch body[0],
                    4 => std.unicode.utf8Decode4(body[0..4].*) catch body[0],
                    else => body[0], // length 1 (ASCII)
                };
            if (std.mem.eql(u8, body, "newline")) break :blk '\n';
            if (std.mem.eql(u8, body, "space")) break :blk ' ';
            if (std.mem.eql(u8, body, "tab")) break :blk '\t';
            if (std.mem.eql(u8, body, "return")) break :blk '\r';
            if (std.mem.eql(u8, body, "backspace")) break :blk 8;
            if (std.mem.eql(u8, body, "formfeed")) break :blk 12;
            if (body[0] == 'u' and body.len == 5) {
                const u = std.fmt.parseInt(u21, body[1..], 16) catch
                    return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
                // Reject UTF-16 surrogates (U+D800..U+DFFF): not valid Unicode
                // scalar values (clj rejects `\uD83D`), and a surrogate would
                // also break the later UTF-8 encode of the char.
                if (u >= 0xD800 and u <= 0xDFFF)
                    return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
                break :blk u;
            }
            if (body[0] == 'o' and body.len >= 2 and body.len <= 4) {
                const o = std.fmt.parseInt(u21, body[1..], 8) catch
                    return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
                // clj caps an octal char at \o377 (255); a larger value is a
                // reader error, not a wider codepoint.
                if (o > 0o377)
                    return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
                break :blk o;
            }
            return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
        };
        return Form{ .data = .{ .char = cp }, .location = loc };
    }

    fn readKeyword(self: *Reader, tok: Token) ReadError!Form {
        var txt = tok.text(self.source)[1..]; // drop leading ':'
        // `::name` / `::alias/name` — auto-resolved against the current ns at
        // analyze time (the reader is namespace-unaware). Drop the second ':'
        // and flag it; parseSymbolRef then splits an `alias/name`.
        var auto = false;
        if (txt.len > 0 and txt[0] == ':') {
            auto = true;
            txt = txt[1..];
        }
        var sref = parseSymbolRef(txt);
        sref.auto_resolve = auto;
        return Form{ .data = .{ .keyword = sref }, .location = self.locOf(tok) };
    }

    /// `#"..."` token text includes the leading `#` + bracketing
    /// quotes. Strip the 2-byte prefix `#"` and the trailing `"`
    /// to recover the raw pattern source (no escape decoding —
    /// see Form.regex_literal docstring + JVM Clojure behaviour).
    fn readRegexLiteral(self: *Reader, tok: Token) ReadError!Form {
        const txt = tok.text(self.source);
        const loc = self.locOf(tok);
        if (txt.len < 3) {
            // `#"` with no closing — tokenizer would have flagged
            // as .invalid; defensive guard.
            return error_catalog.raise(.string_unterminated, loc, .{});
        }
        const body = txt[2 .. txt.len - 1];
        return Form{ .data = .{ .regex_literal = body }, .location = loc };
    }

    // --- collections ---

    fn readList(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        const items = try self.readDelimited(.rparen, loc);
        return Form{ .data = .{ .list = items }, .location = loc };
    }

    fn readVector(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        const items = try self.readDelimited(.rbracket, loc);
        return Form{ .data = .{ .vector = items }, .location = loc };
    }

    fn readMap(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        const items = try self.readDelimited(.rbrace, loc);
        // Maps must have an even number of elements at read time so the
        // analyzer can iterate `[k0 v0 k1 v1 ...]` without re-checking.
        if (items.len % 2 != 0)
            return error_catalog.raise(.map_literal_arity_odd, loc, .{});
        return Form{ .data = .{ .map = items }, .location = loc };
    }

    /// `#{...}` set literal. Mirror of readVector; the closing
    /// delimiter is `}` (the `#` is consumed by the tokenizer's
    /// readDispatch as part of the `set_open` token).
    fn readSet(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        const items = try self.readDelimited(.rbrace, loc);
        return Form{ .data = .{ .set = items }, .location = loc };
    }

    /// Accumulator for the `#()` body walk: the highest positional `%N`
    /// seen (`%` counts as `%1`) and whether `%&` (rest) was used.
    const FnLitCtx = struct { max_positional: usize = 0, rest: bool = false };

    /// `#(body...)` anonymous fn → `(fn* [%1 … & %&] (body...))`. The
    /// `#(` was consumed by the tokenizer (`.fn_lit`); read the
    /// `)`-delimited body, canonicalise bare `%` → `%1` while collecting
    /// the arity, and synthesise the fn* form. Nested `#()` is rejected
    /// (JVM-compatible). The params are the literal `%1`…`%N`/`%&`
    /// symbols the body references — no gensym needed since nesting is
    /// forbidden (D-146).
    fn readFnLit(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        if (self.in_fn_lit)
            return error_catalog.raise(.fn_lit_nested, loc, .{});
        self.in_fn_lit = true;
        defer self.in_fn_lit = false;

        const raw_body = try self.readDelimited(.rparen, loc);

        var ctx: FnLitCtx = .{};
        const body_items = self.allocator.alloc(Form, raw_body.len) catch return error.OutOfMemory;
        for (raw_body, 0..) |f, i| body_items[i] = try self.transformFnLit(f, &ctx);
        const body = Form{ .data = .{ .list = body_items }, .location = loc };

        const n = ctx.max_positional;
        const param_count = n + (if (ctx.rest) @as(usize, 2) else 0); // `&` + `%&`
        const params = self.allocator.alloc(Form, param_count) catch return error.OutOfMemory;
        var k: usize = 1;
        while (k <= n) : (k += 1)
            params[k - 1] = Form{ .data = .{ .symbol = .{ .name = try pctName(self.allocator, k) } }, .location = loc };
        if (ctx.rest) {
            params[n] = Form{ .data = .{ .symbol = .{ .name = "&" } }, .location = loc };
            params[n + 1] = Form{ .data = .{ .symbol = .{ .name = "%&" } }, .location = loc };
        }
        const params_vec = Form{ .data = .{ .vector = params }, .location = loc };

        const fn_items = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        fn_items[0] = Form{ .data = .{ .symbol = .{ .name = "fn*" } }, .location = loc };
        fn_items[1] = params_vec;
        fn_items[2] = body;
        return Form{ .data = .{ .list = fn_items }, .location = loc };
    }

    /// Recursively copy a `#()` body Form, rewriting bare `%` → `%1` and
    /// recording `%N`/`%&` usage into `ctx`. Scalars pass through; only
    /// `%`-symbols are rewritten, so the copy is shallow where possible.
    fn transformFnLit(self: *Reader, f: Form, ctx: *FnLitCtx) ReadError!Form {
        switch (f.data) {
            .symbol => |s| {
                if (s.ns == null and s.name.len >= 1 and s.name[0] == '%') {
                    if (s.name.len == 1) { // bare `%` ≡ `%1`
                        if (ctx.max_positional < 1) ctx.max_positional = 1;
                        return Form{ .data = .{ .symbol = .{ .name = "%1" } }, .location = f.location };
                    }
                    if (std.mem.eql(u8, s.name, "%&")) {
                        ctx.rest = true;
                        return f;
                    }
                    if (std.fmt.parseInt(usize, s.name[1..], 10) catch null) |nn| {
                        if (ctx.max_positional < nn) ctx.max_positional = nn;
                    }
                }
                return f;
            },
            .list => |items| return Form{ .data = .{ .list = try self.mapFnLit(items, ctx) }, .location = f.location },
            .vector => |items| return Form{ .data = .{ .vector = try self.mapFnLit(items, ctx) }, .location = f.location },
            .map => |items| return Form{ .data = .{ .map = try self.mapFnLit(items, ctx) }, .location = f.location },
            .set => |items| return Form{ .data = .{ .set = try self.mapFnLit(items, ctx) }, .location = f.location },
            else => return f,
        }
    }

    fn mapFnLit(self: *Reader, items: []const Form, ctx: *FnLitCtx) ReadError![]const Form {
        const out = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
        for (items, 0..) |c, i| out[i] = try self.transformFnLit(c, ctx);
        return out;
    }

    fn pctName(alloc: std.mem.Allocator, n: usize) ReadError![]const u8 {
        return std.fmt.allocPrint(alloc, "%{d}", .{n}) catch return error.OutOfMemory;
    }

    fn readDelimited(self: *Reader, closing: TokenKind, opener_loc: SourceLocation) ReadError![]const Form {
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, opener_loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        var items: std.ArrayList(Form) = .empty;
        errdefer items.deinit(self.allocator);

        while (true) {
            // `#?@(:clj […])` splice: only valid inside a collection — the
            // selected branch's sequence elements are spliced in, not nested.
            if (self.peekToken().kind == .reader_cond_splice) {
                const stok = self.nextToken();
                const spliced = try self.readReaderConditionalSplice(stok);
                items.appendSlice(self.allocator, spliced) catch return error.OutOfMemory;
                continue;
            }
            if (try self.readValue()) |f| {
                items.append(self.allocator, f) catch return error.OutOfMemory;
                continue;
            }
            // Boundary token (closer / EOF) is in the peek buffer.
            const tok = self.nextToken();
            if (tok.kind == .eof)
                return error_catalog.raise(.delimiter_unmatched_at_eof, opener_loc, .{ .delim = closingText(closing) });
            if (tok.kind == closing) break;
            // A different closing delimiter than ours (`(... ]`) — mismatched.
            return error_catalog.raise(.delimiter_unexpected, self.locOf(tok), .{ .delim = tok.text(self.source) });
        }
        return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // --- reader macros ---

    fn readQuote(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        const inner = (try self.readValue()) orelse
            return error_catalog.raise(.quote_reader_macro_incomplete, loc, .{});

        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .name = "quote" } }, .location = loc };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .location = loc };
    }

    /// `@x` reader macro → `(rt/deref x)` (mirrors `readQuote`). The `deref`
    /// symbol is NS-QUALIFIED so a local `deref` binding cannot capture it:
    /// `(let [deref f] @a)` derefs `a`, not calls `f` (clj hygiene, which uses
    /// `clojure.core/deref`). cljw qualifies to the `rt` primitive ns — the
    /// canonical home of core fns (`#'rt/inc`) and the only one resolvable in a
    /// core.clj-less env (the dual-backend diff fixture), unlike `clojure.core`.
    fn readDeref(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        const inner = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});

        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = "rt", .name = "deref" } }, .location = loc };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .location = loc };
    }

    /// `#'x` reader macro → `(var x)` (mirrors `readDeref`).
    fn readVarQuote(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        const inner = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});

        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .name = "var" } }, .location = loc };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .location = loc };
    }

    /// `#tag form` tagged literal (ADR-0073). The `#tag` marker consumed
    /// only the `#`; read the tag symbol token, then the value form. The
    /// data-reader lookup/application is deferred to `formToValue` time
    /// (against `*data-readers*`), so the reader only builds the `.tagged`
    /// Form — it stays namespace-unaware and eval-free.
    fn readTagged(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        const tag_tok = self.nextToken();
        if (tag_tok.kind == .eof)
            return error_catalog.raise(.eof_unexpected, loc, .{});
        if (tag_tok.kind != .symbol)
            return error_catalog.raise(.token_invalid, self.locOf(tag_tok), .{ .token = tag_tok.text(self.source) });
        const tag = parseSymbolRef(tag_tok.text(self.source));

        const inner = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});

        const form_ptr = self.allocator.create(Form) catch return error.OutOfMemory;
        form_ptr.* = inner;
        return Form{ .data = .{ .tagged = .{ .tag = tag, .form = form_ptr } }, .location = loc };
    }

    /// `#:ns{…}` / `#::{…}` / `#::alias{…}` namespaced map (D-219). The token
    /// text is the prefix (`#:foo` / `#::` / `#::alias`); read the following
    /// `{…}` map and qualify each unqualified keyword/symbol KEY with the ns.
    /// `:_/x` keys strip to `:x`; already-qualified keys keep their ns. `#::`/
    /// `#::alias` set `auto_resolve` so the analyzer resolves at analyze time.
    fn readNsMap(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        // Token text is `#:<spec>`; strip the 2-byte `#:` prefix.
        const txt = tok.text(self.source);
        const spec = txt[2..];
        var ns: ?[]const u8 = null;
        var auto = false;
        if (spec.len > 0 and spec[0] == ':') {
            // `#::` (current ns) or `#::alias`.
            auto = true;
            const alias = spec[1..];
            ns = if (alias.len == 0) null else alias;
        } else {
            if (spec.len == 0)
                return error_catalog.raise(.token_invalid, loc, .{ .token = txt });
            ns = spec;
        }

        const map_tok = self.nextToken();
        if (map_tok.kind == .eof) return error_catalog.raise(.eof_unexpected, loc, .{});
        if (map_tok.kind != .lbrace)
            return error_catalog.raise(.token_invalid, self.locOf(map_tok), .{ .token = map_tok.text(self.source) });
        const map_form = try self.readMap(map_tok);

        const items = map_form.data.map;
        const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
        for (items, 0..) |it, idx| {
            new_items[idx] = qualifyKey(it, ns, auto, idx % 2 == 0);
        }
        return Form{ .data = .{ .map = new_items }, .location = loc };
    }

    /// Qualify a namespaced-map KEY Form with the map's namespace (D-219).
    /// Only unqualified keyword/symbol keys (at even index `is_key`) are
    /// rewritten; values + non-symbolic keys pass through. `:_/x` strips to
    /// `:x`; already-qualified keys keep their own ns; `#::`/`#::alias` set
    /// `auto_resolve` so the analyzer resolves at analyze time.
    fn qualifyKey(key: Form, ns: ?[]const u8, auto: bool, is_key: bool) Form {
        if (!is_key) return key;
        return switch (key.data) {
            .keyword => |sref| Form{ .data = .{ .keyword = qualifySref(sref, ns, auto) }, .location = key.location },
            .symbol => |sref| Form{ .data = .{ .symbol = qualifySref(sref, ns, auto) }, .location = key.location },
            else => key,
        };
    }

    fn qualifySref(sref: SymbolRef, ns: ?[]const u8, auto: bool) SymbolRef {
        if (sref.auto_resolve) return sref;
        if (sref.ns) |existing| {
            if (std.mem.eql(u8, existing, "_")) return .{ .ns = null, .name = sref.name, .auto_resolve = false };
            return sref;
        }
        return .{ .ns = ns, .name = sref.name, .auto_resolve = auto };
    }

    /// `` `form `` / `~form` / `~@form` (ADR-0082): box the next form in a
    /// `.syntax_quote`/`.unquote`/`.unquote_splicing` node. The reader only
    /// wraps — the analyzer expands the syntax_quote tree.
    const WrapKind = enum { syntax_quote, unquote, unquote_splicing };
    fn readWrapped(self: *Reader, tok: Token, comptime kind: WrapKind) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;
        const inner = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});
        const p = self.allocator.create(Form) catch return error.OutOfMemory;
        p.* = inner;
        return Form{ .data = switch (kind) {
            .syntax_quote => .{ .syntax_quote = p },
            .unquote => .{ .unquote = p },
            .unquote_splicing => .{ .unquote_splicing = p },
        }, .location = loc };
    }

    /// `^meta target` reader macro → `target` with `meta` attached to
    /// its `Form.meta` side-channel (D-183 part b). `meta` is normalised
    /// to a map Form: `^{m}` keeps the map, `^:kw`→`{:kw true}`,
    /// `^Sym`/`^"s"`→`{:tag <x>}`. Stacked metas (`^:a ^:b x`) merge,
    /// outer winning on duplicate keys (placed last for last-wins).
    fn readMeta(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        self.depth += 1;
        if (self.depth > self.max_depth)
            return error_catalog.raise(.form_nesting_too_deep, loc, .{ .max = self.max_depth });
        defer self.depth -= 1;

        const meta_raw = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});

        var target = (try self.readValue()) orelse
            return error_catalog.raise(.eof_unexpected, loc, .{});

        const norm = try self.normalizeMeta(meta_raw, loc);
        const final_meta = if (target.meta) |inner|
            try self.mergeMetaMaps(inner.*, norm, loc)
        else
            norm;
        const meta_ptr = self.allocator.create(Form) catch return error.OutOfMemory;
        meta_ptr.* = final_meta;
        target.meta = meta_ptr;
        return target;
    }

    /// Normalise a reader metadata form into a map Form. Mirrors JVM's
    /// reader: keyword → `{:kw true}`, symbol/string → `{:tag <x>}`,
    /// map → itself. Anything else is a read error.
    fn normalizeMeta(self: *Reader, meta_raw: Form, loc: SourceLocation) ReadError!Form {
        switch (meta_raw.data) {
            .map => return meta_raw,
            .keyword => {
                const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                items[0] = meta_raw;
                items[1] = Form{ .data = .{ .boolean = true }, .location = loc };
                return Form{ .data = .{ .map = items }, .location = loc };
            },
            .symbol, .string => {
                const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                items[0] = Form{ .data = .{ .keyword = .{ .name = "tag" } }, .location = loc };
                items[1] = meta_raw;
                return Form{ .data = .{ .map = items }, .location = loc };
            },
            else => return error_catalog.raise(.metadata_value_invalid, loc, .{}),
        }
    }

    /// Concatenate two map Forms' flat k/v pairs; `outer` is appended
    /// last so a duplicate key resolves to the outer meta (last-wins at
    /// `mapFormToValue`), matching JVM's `^:a ^:b x` precedence.
    fn mergeMetaMaps(self: *Reader, inner: Form, outer: Form, loc: SourceLocation) ReadError!Form {
        const ipairs = inner.data.map;
        const opairs = outer.data.map;
        const merged = self.allocator.alloc(Form, ipairs.len + opairs.len) catch return error.OutOfMemory;
        @memcpy(merged[0..ipairs.len], ipairs);
        @memcpy(merged[ipairs.len..], opairs);
        return Form{ .data = .{ .map = merged }, .location = loc };
    }

    fn readSymbolic(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        const next_tok = self.nextToken();
        if (next_tok.kind == .eof)
            return error_catalog.raise(.symbolic_value_incomplete, loc, .{});
        const txt = next_tok.text(self.source);
        if (std.mem.eql(u8, txt, "Inf")) return Form{ .data = .{ .float = std.math.inf(f64) }, .location = loc };
        if (std.mem.eql(u8, txt, "-Inf")) return Form{ .data = .{ .float = -std.math.inf(f64) }, .location = loc };
        if (std.mem.eql(u8, txt, "NaN")) return Form{ .data = .{ .float = std.math.nan(f64) }, .location = loc };
        return error_catalog.raise(.symbolic_value_unknown, self.locOf(next_tok), .{ .name = txt });
    }

    fn readDiscard(self: *Reader, tok: Token) ReadError!Form {
        const discard_loc = self.locOf(tok);
        // Consume the discard target (a real form; readValue skips any nested
        // no-value macros). A boundary before a target is incomplete (`[#_]`).
        _ = (try self.readValue()) orelse
            return error_catalog.raise(.discard_reader_macro_incomplete, discard_loc, .{});
        // `#_` itself contributes nothing: signal skip + return a placeholder
        // the caller (readValue) discards.
        self.skip = true;
        return Form{ .data = .nil, .location = discard_loc };
    }

    /// `#?(:clj a :cljs b :default c)` reader conditional. cljw's platform
    /// feature set is `{:clj, :default}` (it implements Clojure semantics, not
    /// ClojureScript), so the FIRST branch whose key is `:clj` or `:default`
    /// (scanned left-to-right, clj-faithful) is read; a non-matching `#?` reads
    /// as nothing (like `#_` — the next form is returned).
    fn readReaderConditional(self: *Reader, tok: Token) ReadError!Form {
        const loc = self.locOf(tok);
        // D-457(3): `#?` is rejected in a data-read (`read-string`) unless opted in
        // (clj: "Conditional read not allowed"); allowed when source-loading.
        if (!self.allow_reader_cond)
            return error_catalog.raise(.reader_cond_not_allowed, loc, .{});
        const list_tok = self.nextToken();
        if (list_tok.kind != .lparen)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "#? must be followed by a (…) list of feature/form pairs" });
        const list_form = try self.readForm(list_tok);
        const items = list_form.data.list;
        var i: usize = 0;
        while (i + 1 < items.len) : (i += 2) {
            if (items[i].data == .keyword and items[i].data.keyword.ns == null) {
                const k = items[i].data.keyword.name;
                if (std.mem.eql(u8, k, "clj") or std.mem.eql(u8, k, "default"))
                    return items[i + 1];
            }
        }
        // No matching branch: contributes no value (like `#_`). Signal skip
        // + return a placeholder readValue discards. This works uniformly
        // before a trailing closer (`[1 #?(:cljs 2)]` → `[1]`) and at the
        // tail of a form list (`(ns x #?(:cljs ...))`).
        self.skip = true;
        return Form{ .data = .nil, .location = loc };
    }

    /// `#?@(:clj […] :cljs […])` splicing reader conditional. Like `#?`, but the
    /// selected branch's form must be a sequence (list/vector) whose ELEMENTS
    /// are spliced into the enclosing collection (`[1 #?@(:clj [2 3]) 4]` →
    /// `[1 2 3 4]`). Only meaningful inside a collection — `readDelimited` calls
    /// this directly; a top-level `#?@` reaches `readForm`'s arm and errors.
    /// Returns the elements to splice (empty when no branch matches).
    fn readReaderConditionalSplice(self: *Reader, tok: Token) ReadError![]const Form {
        const loc = self.locOf(tok);
        // D-457(3): same data-read gate as `#?` (see readReaderConditional).
        if (!self.allow_reader_cond)
            return error_catalog.raise(.reader_cond_not_allowed, loc, .{});
        const list_tok = self.nextToken();
        if (list_tok.kind != .lparen)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "#?@ must be followed by a (…) list of feature/form pairs" });
        const list_form = try self.readForm(list_tok);
        const items = list_form.data.list;
        var i: usize = 0;
        while (i + 1 < items.len) : (i += 2) {
            if (items[i].data == .keyword and items[i].data.keyword.ns == null) {
                const k = items[i].data.keyword.name;
                if (std.mem.eql(u8, k, "clj") or std.mem.eql(u8, k, "default")) {
                    return switch (items[i + 1].data) {
                        .list => |l| l,
                        .vector => |v| v,
                        else => error_catalog.raise(.reader_cond_splice_not_sequential, items[i + 1].location, .{}),
                    };
                }
            }
        }
        return &.{}; // no matching branch → splice nothing
    }

    // --- string unescaping ---

    fn unescapeString(self: *Reader, s: []const u8, loc: SourceLocation) ReadError![]const u8 {
        // Shared with the `LispReader$StringReader` host shim (D-414); the decode
        // table lives in `runtime/string_escape.zig` so both layers reach it.
        return string_escape.unescape(self.allocator, s, loc);
    }

    // --- token helpers ---

    fn nextToken(self: *Reader) Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.tokenizer.next();
    }

    fn peekToken(self: *Reader) Token {
        if (self.peeked == null) self.peeked = self.tokenizer.next();
        return self.peeked.?;
    }
};

// --- helpers ---

fn closingText(kind: TokenKind) []const u8 {
    return switch (kind) {
        .rparen => ")",
        .rbracket => "]",
        .rbrace => "}",
        else => "?",
    };
}

fn parseSymbolRef(txt: []const u8) SymbolRef {
    if (std.mem.findScalar(u8, txt, '/')) |idx| {
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

test "radix integer literals `<base>r<digits>`" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(i64, 10), (try ctx.read("2r1010")).data.integer);
    try testing.expectEqual(@as(i64, 13), (try ctx.read("8r15")).data.integer);
    try testing.expectEqual(@as(i64, 255), (try ctx.read("16rFF")).data.integer);
    try testing.expectEqual(@as(i64, 255), (try ctx.read("16rff")).data.integer); // case-insensitive
    try testing.expectEqual(@as(i64, 35), (try ctx.read("36rZ")).data.integer);
    try testing.expectEqual(@as(i64, -255), (try ctx.read("-16rFF")).data.integer);
    try testing.expectEqual(@as(i64, 255), (try ctx.read("+16rFF")).data.integer);

    // Out-of-range base and digit-not-less-than-base are rejected.
    try testing.expectError(error.NumberError, ctx.read("1r0"));
    try testing.expectError(error.NumberError, ctx.read("37rA"));
    try testing.expectError(error.NumberError, ctx.read("2r12")); // 2 is not a base-2 digit
}

test "char literal `\\uXXXX` rejects UTF-16 surrogates" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u21, 'A'), (try ctx.read("\\u0041")).data.char);
    try testing.expectEqual(@as(u21, 0x00e9), (try ctx.read("\\u00e9")).data.char); // é
    // A lone surrogate (U+D800..U+DFFF) is not a valid scalar — clj rejects it.
    try testing.expectError(error.SyntaxError, ctx.read("\\uD83D"));
    try testing.expectError(error.SyntaxError, ctx.read("\\uDFFF"));
    try testing.expectError(error.SyntaxError, ctx.read("\\uD800"));
}

test "octal char literal `\\oNNN` caps at \\o377 (255)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u21, 65), (try ctx.read("\\o101")).data.char);
    try testing.expectEqual(@as(u21, 255), (try ctx.read("\\o377")).data.char);
    // clj rejects an octal char value past 0377 (= 255).
    try testing.expectError(error.SyntaxError, ctx.read("\\o400"));
    try testing.expectError(error.SyntaxError, ctx.read("\\o777"));
}

test "octal integer literals `0<digits>`" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(i64, 15), (try ctx.read("017")).data.integer);
    try testing.expectEqual(@as(i64, 511), (try ctx.read("0777")).data.integer);
    try testing.expectEqual(@as(i64, 8), (try ctx.read("010")).data.integer);
    try testing.expectEqual(@as(i64, -15), (try ctx.read("-017")).data.integer);
    try testing.expectEqual(@as(i64, 0), (try ctx.read("00")).data.integer);
    try testing.expectEqual(@as(i64, 0), (try ctx.read("0")).data.integer);
    // `0x` hex must still work (not octal).
    try testing.expectEqual(@as(i64, 255), (try ctx.read("0xff")).data.integer);
    // A non-octal digit (8 / 9) after a leading 0 is rejected (clj parity).
    try testing.expectError(error.NumberError, ctx.read("08"));
    try testing.expectError(error.NumberError, ctx.read("019"));
}

test "big_int_literal `42N` keeps digits without the suffix" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const f = try ctx.read("42N");
    try testing.expectEqualStrings("big_int_literal", f.typeName());
    try testing.expectEqualStrings("42", f.data.big_int_literal);
}

test "big_decimal_literal `1.5M` keeps digits without the suffix" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const f = try ctx.read("1.5M");
    try testing.expectEqualStrings("big_decimal_literal", f.typeName());
    try testing.expectEqualStrings("1.5", f.data.big_decimal_literal);
}

test "big_int_literal accepts values beyond i64 range (2^65)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const f = try ctx.read("36893488147419103232N"); // 2^65
    try testing.expectEqualStrings("big_int_literal", f.typeName());
    try testing.expectEqualStrings("36893488147419103232", f.data.big_int_literal);
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

test "regex literal: #\"\\d+\" reads as Form.regex_literal carrying the raw body" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const form = try ctx.read("#\"\\d+\"");
    try testing.expectEqualStrings("\\d+", form.data.regex_literal);
}

test "regex literal: prints back with the #\"...\" envelope" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const form = try ctx.read("#\"a|b\"");
    const out = try form.toString(ctx.arena.allocator());
    try testing.expectEqualStrings("#\"a|b\"", out);
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

test "syntax error populates last_error with parse phase + location" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    error_mod.clearLastError();
    try testing.expectError(error.SyntaxError, ctx.read(")"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.syntax_error, info.kind);
    try testing.expectEqual(error_mod.Phase.parse, info.phase);
    try testing.expectEqual(@as(u32, 1), info.location.line);
    try testing.expectEqual(@as(u16, 0), info.location.column);
    try testing.expect(std.mem.find(u8, info.message, "Unexpected delimiter") != null);
}

test "unmatched '(' reports opener location" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    error_mod.clearLastError();
    try testing.expectError(error.SyntaxError, ctx.read("(1 2"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.syntax_error, info.kind);
    try testing.expectEqual(@as(u32, 1), info.location.line);
    try testing.expectEqual(@as(u16, 0), info.location.column); // opener column
    try testing.expect(std.mem.find(u8, info.message, "EOF") != null);
}

test "number error carries token text in message" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    error_mod.clearLastError();
    // Malformed hex literal (prefix, no digits) — tokenizer accepts as
    // integer, parseInt fails with InvalidCharacter. (A decimal i64-overflow
    // no longer errors here: it auto-promotes to BigInt, see below.)
    try testing.expectError(error.NumberError, ctx.read("0x"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.number_error, info.kind);
    try testing.expectEqual(error_mod.Phase.parse, info.phase);
    try testing.expect(std.mem.find(u8, info.message, "0x") != null);
}

test "i64-overflowing decimal literal auto-promotes to BigInt" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // Clojure reads an integer literal too large for Long as a BigInt
    // (e.g. 99999999999999999999 → …N), not an error.
    const form = try ctx.read("99999999999999999999");
    try testing.expectEqualStrings("99999999999999999999", form.data.big_int_literal);

    // Sign is preserved by the same path.
    const neg = try ctx.read("-99999999999999999999");
    try testing.expectEqualStrings("-99999999999999999999", neg.data.big_int_literal);
}

test "string error: unknown escape sequence" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    error_mod.clearLastError();
    try testing.expectError(error.StringError, ctx.read("\"\\q\""));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.string_error, info.kind);
    try testing.expect(std.mem.find(u8, info.message, "Unknown escape") != null);
}

test "`#_` discard skips a slot, including before a trailing closer" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // The regression: a discard as the LAST element used to read the
    // closing delimiter as its value and error. It must skip the slot.
    try testing.expectEqualStrings("[1]", try ctx.pr(try ctx.read("[1 #_2]")));
    try testing.expectEqualStrings("(1)", try ctx.pr(try ctx.read("(1 #_2)")));
    try testing.expectEqualStrings("[1 3]", try ctx.pr(try ctx.read("[1 #_2 3]")));
    // stacked discard drops two forms; discard in a wrapper position
    // (`'` reads the form AFTER the discard → `(quote 2)`)
    try testing.expectEqualStrings("[3]", try ctx.pr(try ctx.read("[#_#_1 2 3]")));
    try testing.expectEqualStrings("(quote 2)", try ctx.pr(try ctx.read("'#_1 2")));
}

test "non-matching `#?` reads as nothing, including before a trailing closer" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqualStrings("[1]", try ctx.pr(try ctx.read("[1 #?(:cljs 2)]")));
    try testing.expectEqualStrings("1", try ctx.pr(try ctx.read("#?(:clj 1 :cljs 2)")));
    // tail of a form list (the `(ns x #?(:cljs ...))` shape from .cljc libs)
    try testing.expectEqualStrings("(ns x)", try ctx.pr(try ctx.read("(ns x #?(:cljs :m))")));
}

test "`#?@` splices the selected branch's elements into the collection" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    try testing.expectEqualStrings("[1 2 3 4]", try ctx.pr(try ctx.read("[1 #?@(:clj [2 3]) 4]")));
    // non-matching splice contributes nothing
    try testing.expectEqualStrings("[0 5]", try ctx.pr(try ctx.read("[0 #?@(:cljs [9]) 5]")));
    // splice a list form's elements (reader produces the unevaluated form)
    try testing.expectEqualStrings("(a 1 2 3)", try ctx.pr(try ctx.read("(a 1 #?@(:clj (2 3)))")));
    // a top-level splice is rejected
    try testing.expectError(error.SyntaxError, ctx.read("#?@(:clj [1 2])"));
}
