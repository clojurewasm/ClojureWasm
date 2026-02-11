// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Reader — Converts token stream into Form syntax tree.
//!
//! Three-phase architecture:
//!   Source text -> Tokenizer -> Reader -> Form (syntax tree)
//!
//! Reader macros (quote, deref, meta, etc.) are expanded at read time
//! into standard list forms: 'x -> (quote x), @x -> (deref x), etc.

const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const TokenKind = @import("tokenizer.zig").TokenKind;
const form_mod = @import("form.zig");
const Form = form_mod.Form;
const FormData = form_mod.FormData;
const SymbolRef = form_mod.SymbolRef;
const TaggedLiteral = form_mod.TaggedLiteral;
const err = @import("../runtime/error.zig");

pub const ReadError = err.Error;

pub const Reader = struct {
    pub const Limits = struct {
        max_depth: u32 = 1024,
        max_string_size: u32 = 1_048_576, // 1MB
        max_collection_count: u32 = 100_000,
    };

    tokenizer: Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,
    peeked: ?Token = null,
    depth: u32 = 0,
    limits: Limits = .{},

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
        };
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, source: []const u8, limits: Limits) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
            .limits = limits,
        };
    }

    /// Read the next form. Returns null on EOF.
    pub fn read(self: *Reader) ReadError!?Form {
        const token = self.nextToken();
        if (token.kind == .eof) return null;
        return try self.readForm(token);
    }

    /// Read all forms until EOF.
    pub fn readAll(self: *Reader) ReadError![]Form {
        var forms: std.ArrayList(Form) = .empty;
        errdefer forms.deinit(self.allocator);
        while (true) {
            const f = try self.read();
            if (f) |form| {
                forms.append(self.allocator, form) catch return error.OutOfMemory;
            } else break;
        }
        return forms.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // === Internal ===

    fn readForm(self: *Reader, token: Token) ReadError!Form {
        return switch (token.kind) {
            .nil => Form{ .data = .nil, .line = token.line, .column = token.column },
            .true_lit => Form{ .data = .{ .boolean = true }, .line = token.line, .column = token.column },
            .false_lit => Form{ .data = .{ .boolean = false }, .line = token.line, .column = token.column },
            .integer => self.readInteger(token),
            .float => self.readFloat(token),
            .ratio => self.readRatio(token),
            .string => self.readString(token),
            .character => self.readCharacter(token),
            .symbol => self.readSymbol(token),
            .keyword => self.readKeyword(token),
            .lparen => self.readList(token),
            .lbracket => self.readVector(token),
            .lbrace => self.readMap(token),
            .set_lit => self.readSet(token),
            .quote => self.readWrapped("quote", token),
            .deref => self.readWrapped("deref", token),
            .var_quote => self.readWrapped("var", token),
            .unquote => self.readWrapped("unquote", token),
            .unquote_splicing => self.readWrapped("unquote-splicing", token),
            .discard => self.readDiscard(token),
            .meta => self.readMeta(token),
            .regex => self.readRegex(token),
            .symbolic => self.readSymbolic(token),
            .reader_cond => self.readReaderCond(token),
            .fn_lit => self.readFnLit(token),
            .syntax_quote => self.readSyntaxQuote(token),
            .tag => self.readTag(token),
            .rparen, .rbracket, .rbrace => self.unmatchedError(token),
            .eof => unreachable,
            .invalid, .reader_cond_splicing, .ns_map => self.invalidError(token),
        };
    }

    // --- Literals ---

    fn readInteger(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);

        // Check for M suffix (explicit BigDecimal literal)
        if (text.len > 0 and text[text.len - 1] == 'M') {
            // 42M → BigDecimal with scale=0
            return Form{ .data = .{ .big_decimal = text[0 .. text.len - 1] }, .line = token.line, .column = token.column };
        }

        // Check for N suffix (explicit BigInt literal)
        const has_n_suffix = text.len > 0 and text[text.len - 1] == 'N';
        if (has_n_suffix) {
            // Always create big_int form for N suffix
            const digits = self.normalizeBigIntText(text[0 .. text.len - 1]) catch {
                return self.makeError(.number_error, "Invalid number literal", token);
            };
            return Form{ .data = .{ .big_int = digits }, .line = token.line, .column = token.column };
        }

        // Try parsing as i64 first
        const value = parseInteger(text) catch {
            // Overflow or invalid — try as BigInt for decimal-only
            const digits = self.normalizeBigIntText(text) catch {
                return self.makeError(.number_error, "Invalid number literal", token);
            };
            return Form{ .data = .{ .big_int = digits }, .line = token.line, .column = token.column };
        };
        return Form{ .data = .{ .integer = value }, .line = token.line, .column = token.column };
    }

    /// Normalize integer text to a canonical decimal digit string for BigInt.
    /// Handles sign, hex, octal, radix prefixes. Returns owned string like "-42".
    fn normalizeBigIntText(self: *Reader, text: []const u8) ![]const u8 {
        var s = text;
        var negative = false;

        if (s.len > 0 and s[0] == '-') {
            negative = true;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '+') {
            s = s[1..];
        }

        if (s.len == 0) return error.InvalidNumber;

        // Hex, radix, octal: convert to decimal string via i64 parse
        // (BigInt overflow from these is extremely rare in practice)
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            if (s.len == 2) return error.InvalidNumber; // "0x" with no digits
            // Hex — try i64 parse for base conversion
            const val = std.fmt.parseInt(i64, s[2..], 16) catch return error.InvalidNumber;
            return self.intToString(if (negative) -val else val);
        }
        if (std.mem.indexOfScalar(u8, s, 'r') orelse std.mem.indexOfScalar(u8, s, 'R')) |idx| {
            const radix = std.fmt.parseInt(u8, s[0..idx], 10) catch return error.InvalidNumber;
            if (radix < 2 or radix > 36) return error.InvalidNumber;
            const val = std.fmt.parseInt(i64, s[idx + 1 ..], radix) catch return error.InvalidNumber;
            return self.intToString(if (negative) -val else val);
        }
        if (s.len > 1 and s[0] == '0' and s[1] >= '0' and s[1] <= '7') {
            const val = std.fmt.parseInt(i64, s, 8) catch return error.InvalidNumber;
            return self.intToString(if (negative) -val else val);
        }

        // Decimal: validate digits then return text as-is (with sign if negative)
        for (s) |c| {
            if (c < '0' or c > '9') return error.InvalidNumber;
        }
        if (negative) {
            const buf = self.allocator.alloc(u8, s.len + 1) catch return error.OutOfMemory;
            buf[0] = '-';
            @memcpy(buf[1..], s);
            return buf;
        }
        return s;
    }

    fn intToString(self: *Reader, val: i64) ![]const u8 {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return error.InvalidNumber;
        return self.allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    fn parseInteger(text: []const u8) !i64 {
        var s = text;
        var negative = false;

        if (s.len > 0 and s[0] == '-') {
            negative = true;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '+') {
            s = s[1..];
        }

        // Hex 0x
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            if (s.len == 2) return error.InvalidNumber; // "0x" with no digits
            const val = std.fmt.parseInt(i64, s[2..], 16) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // Radix NNrXXX
        if (std.mem.indexOfScalar(u8, s, 'r') orelse std.mem.indexOfScalar(u8, s, 'R')) |idx| {
            const radix = std.fmt.parseInt(u8, s[0..idx], 10) catch return error.InvalidNumber;
            if (radix < 2 or radix > 36) return error.InvalidNumber;
            const val = std.fmt.parseInt(i64, s[idx + 1 ..], radix) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // Octal 0NNN (leading 0 with digits, but not "0" alone)
        if (s.len > 1 and s[0] == '0' and s[1] >= '0' and s[1] <= '7') {
            const val = std.fmt.parseInt(i64, s, 8) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // Decimal
        const val = std.fmt.parseInt(i64, s, 10) catch return error.InvalidNumber;
        return if (negative) -val else val;
    }

    fn readFloat(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        var s = text;
        const has_m_suffix = s.len > 0 and s[s.len - 1] == 'M';
        if (has_m_suffix) {
            s = s[0 .. s.len - 1];
            // M suffix → BigDecimal form (preserve exact text)
            return Form{ .data = .{ .big_decimal = s }, .line = token.line, .column = token.column };
        }
        const value = std.fmt.parseFloat(f64, s) catch {
            return self.makeError(.number_error, "Invalid float literal", token);
        };
        return Form{ .data = .{ .float = value }, .line = token.line, .column = token.column };
    }

    fn readRatio(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        const slash_idx = std.mem.indexOfScalar(u8, text, '/') orelse {
            return self.makeError(.number_error, "Invalid ratio literal", token);
        };
        const num_text = text[0..slash_idx];
        const den_text = text[slash_idx + 1 ..];
        // Validate numerator and denominator are valid integers
        _ = std.fmt.parseInt(i64, num_text, 10) catch {
            return self.makeError(.number_error, "Invalid ratio literal", token);
        };
        const den = std.fmt.parseInt(i64, den_text, 10) catch {
            return self.makeError(.number_error, "Invalid ratio literal", token);
        };
        if (den == 0) {
            return self.makeError(.number_error, "Division by zero in ratio", token);
        }
        return Form{ .data = .{ .ratio = .{ .numerator = num_text, .denominator = den_text } }, .line = token.line, .column = token.column };
    }

    fn readString(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        if (text.len < 2) {
            return self.makeError(.string_error, "Invalid string literal", token);
        }
        const content = text[1 .. text.len - 1];
        if (content.len > self.limits.max_string_size) {
            return self.makeError(.syntax_error, "String literal exceeds maximum size", token);
        }
        const unescaped = self.unescapeString(content) catch {
            return self.makeError(.string_error, "Invalid escape sequence in string", token);
        };
        return Form{ .data = .{ .string = unescaped }, .line = token.line, .column = token.column };
    }

    fn unescapeString(self: *Reader, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                switch (s[i + 1]) {
                    'n' => { result.append(self.allocator, '\n') catch return error.OutOfMemory; i += 2; },
                    't' => { result.append(self.allocator, '\t') catch return error.OutOfMemory; i += 2; },
                    'r' => { result.append(self.allocator, '\r') catch return error.OutOfMemory; i += 2; },
                    '\\' => { result.append(self.allocator, '\\') catch return error.OutOfMemory; i += 2; },
                    '"' => { result.append(self.allocator, '"') catch return error.OutOfMemory; i += 2; },
                    'u' => {
                        if (i + 5 < s.len) {
                            const hex = s[i + 2 .. i + 6];
                            const cp = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidString;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidString;
                            result.appendSlice(self.allocator, buf[0..len]) catch return error.OutOfMemory;
                            i += 6;
                        } else return error.InvalidString;
                    },
                    else => return error.InvalidString, // Clojure strict: unknown escape is error
                }
            } else {
                result.append(self.allocator, s[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn readCharacter(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        // text starts with '\'
        if (text.len < 2) {
            return self.makeError(.string_error, "Invalid character literal", token);
        }
        const name = text[1..];
        const cp: u21 = if (name.len == 1)
            name[0]
        else if (std.mem.eql(u8, name, "newline"))
            '\n'
        else if (std.mem.eql(u8, name, "space"))
            ' '
        else if (std.mem.eql(u8, name, "tab"))
            '\t'
        else if (std.mem.eql(u8, name, "return"))
            '\r'
        else if (std.mem.eql(u8, name, "backspace"))
            '\x08'
        else if (std.mem.eql(u8, name, "formfeed"))
            '\x0c'
        else if (name.len == 5 and name[0] == 'u')
            std.fmt.parseInt(u21, name[1..], 16) catch {
                return self.makeError(.string_error, "Invalid unicode character", token);
            }
        else if (name.len >= 2 and name.len <= 4 and name[0] == 'o') blk: {
            const val = std.fmt.parseInt(u21, name[1..], 8) catch {
                return self.makeError(.string_error, "Invalid octal character", token);
            };
            if (val > 0o377) return self.makeError(.string_error, "Octal character out of range", token);
            break :blk val;
        }
        else {
            return self.makeError(.string_error, "Unknown character name", token);
        };
        return Form{ .data = .{ .char = cp }, .line = token.line, .column = token.column };
    }

    fn readSymbol(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        const sym = parseSymbol(text);
        // Validate: foo/ (trailing slash with empty name) is invalid
        if (sym.ns != null and sym.name.len == 0) {
            return self.makeError(.syntax_error, "Invalid token", token);
        }
        return Form{ .data = .{ .symbol = sym }, .line = token.line, .column = token.column };
    }

    fn parseSymbol(text: []const u8) SymbolRef {
        if (std.mem.indexOfScalar(u8, text, '/')) |idx| {
            if (idx == 0 and text.len == 1) {
                return .{ .ns = null, .name = text };
            }
            return .{ .ns = text[0..idx], .name = text[idx + 1 ..] };
        }
        return .{ .ns = null, .name = text };
    }

    fn readKeyword(self: *Reader, token: Token) ReadError!Form {
        var text = token.text(self.source);
        // Strip leading ':'
        if (text.len > 0 and text[0] == ':') text = text[1..];
        // Strip second ':' for auto-resolved keywords (::foo)
        var is_auto_resolve = false;
        if (text.len > 0 and text[0] == ':') {
            text = text[1..];
            is_auto_resolve = true;
        }
        const sym = parseSymbol(text);
        // Validate: :foo/ (trailing slash with empty name) is invalid
        if (sym.ns != null and sym.name.len == 0) {
            return self.makeError(.syntax_error, "Invalid token", token);
        }
        return Form{ .data = .{ .keyword = .{
            .ns = sym.ns,
            .name = sym.name,
            .auto_resolve = is_auto_resolve,
        } }, .line = token.line, .column = token.column };
    }

    // --- Collections ---

    fn readList(self: *Reader, token: Token) ReadError!Form {
        const items = try self.readDelimited(.rparen);
        return Form{ .data = .{ .list = items }, .line = token.line, .column = token.column };
    }

    fn readVector(self: *Reader, token: Token) ReadError!Form {
        const items = try self.readDelimited(.rbracket);
        return Form{ .data = .{ .vector = items }, .line = token.line, .column = token.column };
    }

    fn readMap(self: *Reader, token: Token) ReadError!Form {
        const items = try self.readDelimited(.rbrace);
        if (items.len % 2 != 0) {
            return self.makeError(.syntax_error, "Map literal must have even number of forms", token);
        }
        return Form{ .data = .{ .map = items }, .line = token.line, .column = token.column };
    }

    fn readSet(self: *Reader, token: Token) ReadError!Form {
        const items = try self.readDelimited(.rbrace);
        return Form{ .data = .{ .set = items }, .line = token.line, .column = token.column };
    }

    fn readDelimited(self: *Reader, closing: TokenKind) ReadError![]Form {
        try self.enterDepth(self.tokenizer.line, self.tokenizer.column);
        defer self.depth -= 1;
        var items: std.ArrayList(Form) = .empty;
        errdefer items.deinit(self.allocator);
        while (true) {
            const tok = self.nextToken();
            if (tok.kind == .eof) {
                return self.makeError(.syntax_error, "EOF while reading collection", tok);
            }
            if (tok.kind == closing) break;
            const form = try self.readForm(tok);
            items.append(self.allocator, form) catch return error.OutOfMemory;
            if (items.items.len > self.limits.max_collection_count) {
                return err.setError(.{
                    .kind = .syntax_error,
                    .phase = .parse,
                    .message = "Collection literal exceeds maximum element count",
                    .location = .{ .line = tok.line, .column = tok.column },
                });
            }
        }
        return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // --- Reader macros ---

    /// Expand 'x -> (quote x), @x -> (deref x), etc.
    fn readWrapped(self: *Reader, wrapper_name: []const u8, start_token: Token) ReadError!Form {
        try self.enterDepth(start_token.line, start_token.column);
        defer self.depth -= 1;
        const next = self.nextToken();
        if (next.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after reader macro", next);
        }
        const inner = try self.readForm(next);
        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = wrapper_name } } };
        items[1] = inner;
        return Form{ .data = .{ .list = items }, .line = start_token.line, .column = start_token.column };
    }

    fn readDiscard(self: *Reader, start_token: Token) ReadError!Form {
        try self.enterDepth(start_token.line, start_token.column);
        defer self.depth -= 1;
        // Read and discard the next form
        const next = self.nextToken();
        if (next.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after #_", next);
        }
        _ = try self.readForm(next);
        // Return the form after the discarded one
        const following = try self.read();
        return following orelse Form{ .data = .nil };
    }

    fn readMeta(self: *Reader, start_token: Token) ReadError!Form {
        try self.enterDepth(start_token.line, start_token.column);
        defer self.depth -= 1;
        // Read metadata form
        const meta_tok = self.nextToken();
        if (meta_tok.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after ^", meta_tok);
        }
        const meta_form = try self.readForm(meta_tok);

        // Read target form
        const target_tok = self.nextToken();
        if (target_tok.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after metadata", target_tok);
        }
        const target_form = try self.readForm(target_tok);

        // Normalize metadata to map
        const meta_map = switch (meta_form.data) {
            .keyword => |kw| blk: {
                const entries = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                entries[0] = Form{ .data = .{ .keyword = kw } };
                entries[1] = Form{ .data = .{ .boolean = true } };
                break :blk Form{ .data = .{ .map = entries } };
            },
            .map => meta_form,
            .symbol => |sym| blk: {
                const entries = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                entries[0] = Form{ .data = .{ .keyword = .{ .ns = null, .name = "tag" } } };
                entries[1] = Form{ .data = .{ .symbol = sym } };
                break :blk Form{ .data = .{ .map = entries } };
            },
            else => {
                return self.makeError(.syntax_error, "Invalid metadata form", meta_tok);
            },
        };

        // (with-meta target meta-map)
        const items = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "with-meta" } } };
        items[1] = target_form;
        items[2] = meta_map;
        return Form{ .data = .{ .list = items }, .line = start_token.line, .column = start_token.column };
    }

    fn readRegex(self: *Reader, token: Token) ReadError!Form {
        const text = token.text(self.source);
        // #"..." — strip leading #" and trailing "
        if (text.len < 3) {
            return self.makeError(.syntax_error, "Invalid regex literal", token);
        }
        const pattern = text[2 .. text.len - 1];
        return Form{ .data = .{ .regex = pattern }, .line = token.line, .column = token.column };
    }

    fn readSymbolic(self: *Reader, token: Token) ReadError!Form {
        const next = self.nextToken();
        if (next.kind != .symbol) {
            return self.makeError(.syntax_error, "Expected symbolic value after ##", next);
        }
        const text = next.text(self.source);
        if (std.mem.eql(u8, text, "Inf")) {
            return Form{ .data = .{ .float = std.math.inf(f64) }, .line = token.line, .column = token.column };
        } else if (std.mem.eql(u8, text, "-Inf")) {
            return Form{ .data = .{ .float = -std.math.inf(f64) }, .line = token.line, .column = token.column };
        } else if (std.mem.eql(u8, text, "NaN")) {
            return Form{ .data = .{ .float = std.math.nan(f64) }, .line = token.line, .column = token.column };
        }
        return self.makeError(.syntax_error, "Unknown symbolic value", next);
    }

    fn readReaderCond(self: *Reader, token: Token) ReadError!Form {
        const open = self.nextToken();
        if (open.kind != .lparen) {
            return self.makeError(.syntax_error, "Expected ( after #?", open);
        }

        var cljw_form: ?Form = null;
        var clj_form: ?Form = null;
        var default_form: ?Form = null;

        while (true) {
            const kw_tok = self.nextToken();
            if (kw_tok.kind == .rparen) break;
            if (kw_tok.kind == .eof) {
                return self.makeError(.syntax_error, "EOF in reader conditional", kw_tok);
            }

            const kw_form = try self.readForm(kw_tok);
            const kw_name = switch (kw_form.data) {
                .keyword => |kw| kw.name,
                else => return self.makeError(.syntax_error, "Expected keyword in reader conditional", kw_tok),
            };

            const val_tok = self.nextToken();
            if (val_tok.kind == .eof) {
                return self.makeError(.syntax_error, "EOF in reader conditional", val_tok);
            }
            const val_form = try self.readForm(val_tok);

            if (std.mem.eql(u8, kw_name, "cljw")) {
                cljw_form = val_form;
            } else if (std.mem.eql(u8, kw_name, "clj")) {
                clj_form = val_form;
            } else if (std.mem.eql(u8, kw_name, "default")) {
                default_form = val_form;
            }
        }

        // Priority: :cljw > :clj > :default
        if (cljw_form) |f| return f;
        if (clj_form) |f| return f;
        if (default_form) |f| return f;
        return Form{ .data = .nil, .line = token.line, .column = token.column };
    }

    fn readFnLit(self: *Reader, token: Token) ReadError!Form {
        // #(body) → (fn* [%1 %2 ...] (body))
        const body = try self.readDelimited(.rparen);

        // Scan for %, %N, %& parameters
        var max_param: usize = 0;
        var has_rest = false;
        for (body) |form| {
            scanFnLitParams(form, &max_param, &has_rest);
        }

        // Build parameter vector
        const param_count = max_param + (if (has_rest) @as(usize, 2) else 0);
        const params = self.allocator.alloc(Form, param_count) catch return error.OutOfMemory;
        for (0..max_param) |i| {
            var buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "%{d}", .{i + 1}) catch unreachable;
            const duped = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
            params[i] = Form{ .data = .{ .symbol = .{ .ns = null, .name = duped } } };
        }
        if (has_rest) {
            params[max_param] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "&" } } };
            params[max_param + 1] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "%&" } } };
        }

        // Normalize % to %1 in body
        const normalized_body = self.allocator.alloc(Form, body.len) catch return error.OutOfMemory;
        for (body, 0..) |form, i| {
            normalized_body[i] = self.normalizeFnLitPercent(form) catch return error.OutOfMemory;
        }

        const body_list = Form{ .data = .{ .list = normalized_body } };

        const items = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "fn*" } } };
        items[1] = Form{ .data = .{ .vector = params } };
        items[2] = body_list;

        return Form{ .data = .{ .list = items }, .line = token.line, .column = token.column };
    }

    fn normalizeFnLitPercent(self: *Reader, form: Form) !Form {
        switch (form.data) {
            .symbol => |s| {
                if (s.ns == null and std.mem.eql(u8, s.name, "%")) {
                    return Form{ .data = .{ .symbol = .{ .ns = null, .name = "%1" } }, .line = form.line, .column = form.column };
                }
                return form;
            },
            .list => |items| {
                const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    new_items[i] = try self.normalizeFnLitPercent(item);
                }
                return Form{ .data = .{ .list = new_items }, .line = form.line, .column = form.column };
            },
            .vector => |items| {
                const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    new_items[i] = try self.normalizeFnLitPercent(item);
                }
                return Form{ .data = .{ .vector = new_items }, .line = form.line, .column = form.column };
            },
            .map => |items| {
                const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    new_items[i] = try self.normalizeFnLitPercent(item);
                }
                return Form{ .data = .{ .map = new_items }, .line = form.line, .column = form.column };
            },
            .set => |items| {
                const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    new_items[i] = try self.normalizeFnLitPercent(item);
                }
                return Form{ .data = .{ .set = new_items }, .line = form.line, .column = form.column };
            },
            else => return form,
        }
    }

    fn scanFnLitParams(form: Form, max_param: *usize, has_rest: *bool) void {
        switch (form.data) {
            .symbol => |s| {
                if (s.ns != null) return;
                if (std.mem.eql(u8, s.name, "%") or std.mem.eql(u8, s.name, "%1")) {
                    if (max_param.* < 1) max_param.* = 1;
                } else if (std.mem.eql(u8, s.name, "%&")) {
                    has_rest.* = true;
                } else if (s.name.len >= 2 and s.name[0] == '%') {
                    const num = std.fmt.parseInt(usize, s.name[1..], 10) catch return;
                    if (num > 20) return; // Cap at %20 (Clojure convention)
                    if (num > max_param.*) max_param.* = num;
                }
            },
            .list => |items| for (items) |item| { scanFnLitParams(item, max_param, has_rest); },
            .vector => |items| for (items) |item| { scanFnLitParams(item, max_param, has_rest); },
            .map => |items| for (items) |item| { scanFnLitParams(item, max_param, has_rest); },
            .set => |items| for (items) |item| { scanFnLitParams(item, max_param, has_rest); },
            else => {},
        }
    }

    /// Syntax-quote auto-gensym counter (module-level).
    var sq_gensym_counter: u64 = 0;

    fn readSyntaxQuote(self: *Reader, token: Token) ReadError!Form {
        const next = self.nextToken();
        if (next.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after syntax-quote", next);
        }
        const form = try self.readForm(next);

        var gensym_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer gensym_map.deinit(self.allocator);

        const expanded = try self.expandSyntaxQuote(form, &gensym_map);
        _ = token;
        return expanded;
    }

    fn expandSyntaxQuote(self: *Reader, form: Form, gensym_map: *std.StringHashMapUnmanaged([]const u8)) ReadError!Form {
        return switch (form.data) {
            .nil, .boolean, .integer, .float, .big_int, .big_decimal, .ratio, .string, .regex, .char => form,
            .keyword => form,
            .symbol => |sym| {
                // Auto-gensym: foo# → foo__N__auto
                if (sym.ns == null and sym.name.len > 1 and sym.name[sym.name.len - 1] == '#') {
                    const base = sym.name[0 .. sym.name.len - 1];
                    const resolved = gensym_map.get(sym.name) orelse blk: {
                        sq_gensym_counter += 1;
                        var buf: [128]u8 = undefined;
                        const gen_name = std.fmt.bufPrint(&buf, "{s}__{d}__auto", .{ base, sq_gensym_counter }) catch
                            return error.OutOfMemory;
                        const duped = self.allocator.dupe(u8, gen_name) catch return error.OutOfMemory;
                        gensym_map.put(self.allocator, sym.name, duped) catch return error.OutOfMemory;
                        break :blk duped;
                    };
                    return self.makeQuote(Form{ .data = .{ .symbol = .{ .ns = null, .name = resolved } }, .line = form.line, .column = form.column });
                }
                return self.makeQuote(form);
            },
            .list => |items| {
                if (isUnquote(items)) return items[1];
                if (isUnquoteSplicing(items)) {
                    return self.makeError(.syntax_error, "Splice not in list", Token{ .kind = .invalid, .start = 0, .len = 0, .line = form.line, .column = form.column });
                }
                return self.syntaxQuoteColl(items, .list, gensym_map);
            },
            .vector => |items| self.syntaxQuoteColl(items, .vector, gensym_map),
            .map => |items| self.syntaxQuoteColl(items, .map, gensym_map),
            .set => |items| self.syntaxQuoteColl(items, .set, gensym_map),
            .tag => form, // pass through
        };
    }

    const CollKind = enum { list, vector, map, set };

    fn syntaxQuoteColl(self: *Reader, items: []const Form, kind: CollKind, gensym_map: *std.StringHashMapUnmanaged([]const u8)) ReadError!Form {
        var concat_args: std.ArrayList(Form) = .empty;
        defer concat_args.deinit(self.allocator);

        for (items) |item| {
            const arg = switch (item.data) {
                .list => |sub_items| blk: {
                    if (isUnquote(sub_items)) {
                        break :blk try self.makeListCall(sub_items[1]);
                    } else if (isUnquoteSplicing(sub_items)) {
                        break :blk sub_items[1];
                    } else {
                        const expanded = try self.expandSyntaxQuote(item, gensym_map);
                        break :blk try self.makeListCall(expanded);
                    }
                },
                else => blk: {
                    const expanded = try self.expandSyntaxQuote(item, gensym_map);
                    break :blk try self.makeListCall(expanded);
                },
            };
            concat_args.append(self.allocator, arg) catch return error.OutOfMemory;
        }

        const args_slice = concat_args.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        const seq_concat = try self.makeSeqConcat(args_slice);

        return switch (kind) {
            .list => seq_concat,
            .vector => self.makeApplyCall("vector", seq_concat),
            .map => self.makeApplyCall("hash-map", seq_concat),
            .set => self.makeApplyCall("hash-set", seq_concat),
        };
    }

    fn isUnquote(items: []const Form) bool {
        if (items.len == 2) {
            switch (items[0].data) {
                .symbol => |s| return std.mem.eql(u8, s.name, "unquote"),
                else => {},
            }
        }
        return false;
    }

    fn isUnquoteSplicing(items: []const Form) bool {
        if (items.len == 2) {
            switch (items[0].data) {
                .symbol => |s| return std.mem.eql(u8, s.name, "unquote-splicing"),
                else => {},
            }
        }
        return false;
    }

    fn makeQuote(self: *Reader, form: Form) ReadError!Form {
        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "quote" } } };
        items[1] = form;
        return Form{ .data = .{ .list = items } };
    }

    fn makeListCall(self: *Reader, form: Form) ReadError!Form {
        const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "list" } } };
        items[1] = form;
        return Form{ .data = .{ .list = items } };
    }

    fn makeSeqConcat(self: *Reader, args: []const Form) ReadError!Form {
        const concat_items = self.allocator.alloc(Form, args.len + 1) catch return error.OutOfMemory;
        concat_items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "concat" } } };
        for (args, 0..) |arg, i| {
            concat_items[i + 1] = arg;
        }
        const concat_form = Form{ .data = .{ .list = concat_items } };

        const seq_items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        seq_items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "seq" } } };
        seq_items[1] = concat_form;
        return Form{ .data = .{ .list = seq_items } };
    }

    fn makeApplyCall(self: *Reader, fn_name: []const u8, inner: Form) ReadError!Form {
        const items = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "apply" } } };
        items[1] = Form{ .data = .{ .symbol = .{ .ns = null, .name = fn_name } } };
        items[2] = inner;
        return Form{ .data = .{ .list = items } };
    }

    fn readTag(self: *Reader, token: Token) ReadError!Form {
        // After '#', tokenizer returns tag token. Next token is the tag name (symbol).
        const tag_tok = self.nextToken();
        if (tag_tok.kind != .symbol) {
            return self.makeError(.syntax_error, "Expected symbol after #", tag_tok);
        }
        const tag_name = tag_tok.text(self.source);

        // Read the tagged value
        const val_tok = self.nextToken();
        if (val_tok.kind == .eof) {
            return self.makeError(.syntax_error, "EOF after tagged literal", val_tok);
        }
        const val_form = try self.readForm(val_tok);
        const val_ptr = self.allocator.create(Form) catch return error.OutOfMemory;
        val_ptr.* = val_form;

        return Form{ .data = .{ .tag = .{ .tag = tag_name, .form = val_ptr } }, .line = token.line, .column = token.column };
    }

    // --- Token management ---

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

    // --- Error helpers ---

    fn makeError(_: *Reader, kind: err.Kind, message: []const u8, token: Token) ReadError {
        return err.setError(.{
            .kind = kind,
            .phase = .parse,
            .message = message,
            .location = .{ .line = token.line, .column = token.column },
        });
    }

    fn unmatchedError(self: *Reader, token: Token) ReadError {
        return self.makeError(.syntax_error, "Unmatched delimiter", token);
    }

    fn invalidError(self: *Reader, token: Token) ReadError {
        return self.makeError(.syntax_error, "Invalid token", token);
    }

    /// Increment nesting depth, checking against limit.
    /// Returns error if limit exceeded. Caller must `defer self.depth -= 1`.
    fn enterDepth(self: *Reader, line: u32, column: u16) ReadError!void {
        self.depth += 1;
        if (self.depth > self.limits.max_depth) {
            return err.setError(.{
                .kind = .syntax_error,
                .phase = .parse,
                .message = "Nesting depth exceeds maximum limit",
                .location = .{ .line = line, .column = column },
            });
        }
    }
};

// === Tests ===

const testing = std.testing;

fn readOne(source: []const u8) ReadError!?Form {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // Note: in tests we leak the arena for simplicity — test runner cleans up
    const allocator = arena.allocator();
    var r = Reader.init(allocator, source);
    return r.read();
}

fn readOneForm(source: []const u8) ReadError!Form {
    return (try readOne(source)).?;
}

test "Reader - nil, true, false" {
    const f1 = try readOneForm("nil");
    try testing.expect(f1.data == .nil);

    const f2 = try readOneForm("true");
    try testing.expectEqual(true, f2.data.boolean);

    const f3 = try readOneForm("false");
    try testing.expectEqual(false, f3.data.boolean);
}

test "Reader - integers" {
    try testing.expectEqual(@as(i64, 42), (try readOneForm("42")).data.integer);
    try testing.expectEqual(@as(i64, -17), (try readOneForm("-17")).data.integer);
    try testing.expectEqual(@as(i64, 42), (try readOneForm("0x2A")).data.integer);
    try testing.expectEqual(@as(i64, 42), (try readOneForm("2r101010")).data.integer);
    try testing.expectEqual(@as(i64, 493), (try readOneForm("0755")).data.integer);
    // 42N is now a big_int form (not truncated to i64)
    try testing.expectEqualStrings("42", (try readOneForm("42N")).data.big_int);
}

test "Reader - floats" {
    try testing.expectApproxEqAbs(@as(f64, 3.14), (try readOneForm("3.14")).data.float, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1e10), (try readOneForm("1e10")).data.float, 1e5);
    try testing.expectApproxEqAbs(@as(f64, 0.0025), (try readOneForm("2.5e-3")).data.float, 0.0001);
    try testing.expectEqualStrings("3.14", (try readOneForm("3.14M")).data.big_decimal);
    try testing.expectEqualStrings("42", (try readOneForm("42M")).data.big_decimal);
    try testing.expectEqualStrings("1e10", (try readOneForm("1e10M")).data.big_decimal);
}

test "Reader - ratio" {
    const r1 = (try readOneForm("22/7")).data.ratio;
    try testing.expectEqualStrings("22", r1.numerator);
    try testing.expectEqualStrings("7", r1.denominator);
    const r2 = (try readOneForm("1/2")).data.ratio;
    try testing.expectEqualStrings("1", r2.numerator);
    try testing.expectEqualStrings("2", r2.denominator);
}

test "Reader - string" {
    try testing.expectEqualStrings("hello", (try readOneForm("\"hello\"")).data.string);
    try testing.expectEqualStrings("with\nline", (try readOneForm("\"with\\nline\"")).data.string);
    try testing.expectEqualStrings("tab\there", (try readOneForm("\"tab\\there\"")).data.string);
    try testing.expectEqualStrings("quote\"here", (try readOneForm("\"quote\\\"here\"")).data.string);
}

test "Reader - character" {
    try testing.expectEqual(@as(u21, 'A'), (try readOneForm("\\A")).data.char);
    try testing.expectEqual(@as(u21, '\n'), (try readOneForm("\\newline")).data.char);
    try testing.expectEqual(@as(u21, ' '), (try readOneForm("\\space")).data.char);
    try testing.expectEqual(@as(u21, '\t'), (try readOneForm("\\tab")).data.char);
    try testing.expectEqual(@as(u21, 0x03B1), (try readOneForm("\\u03B1")).data.char); // α
}

test "Reader - symbol" {
    const s1 = (try readOneForm("foo")).data.symbol;
    try testing.expectEqualStrings("foo", s1.name);
    try testing.expect(s1.ns == null);

    const s2 = (try readOneForm("clojure.core/map")).data.symbol;
    try testing.expectEqualStrings("map", s2.name);
    try testing.expectEqualStrings("clojure.core", s2.ns.?);

    // "/" alone is a symbol
    const s3 = (try readOneForm("/")).data.symbol;
    try testing.expectEqualStrings("/", s3.name);
    try testing.expect(s3.ns == null);
}

test "Reader - keyword" {
    const k1 = (try readOneForm(":foo")).data.keyword;
    try testing.expectEqualStrings("foo", k1.name);
    try testing.expect(k1.ns == null);

    const k2 = (try readOneForm(":ns/bar")).data.keyword;
    try testing.expectEqualStrings("bar", k2.name);
    try testing.expectEqualStrings("ns", k2.ns.?);
}

test "Reader - list" {
    const form = try readOneForm("(+ 1 2)");
    const items = form.data.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("+", items[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), items[1].data.integer);
    try testing.expectEqual(@as(i64, 2), items[2].data.integer);
}

test "Reader - vector" {
    const form = try readOneForm("[1 2 3]");
    try testing.expectEqual(@as(usize, 3), form.data.vector.len);
}

test "Reader - map" {
    const form = try readOneForm("{:a 1 :b 2}");
    try testing.expectEqual(@as(usize, 4), form.data.map.len);
}

test "Reader - set" {
    const form = try readOneForm("#{1 2 3}");
    try testing.expectEqual(@as(usize, 3), form.data.set.len);
}

test "Reader - nested collections" {
    const form = try readOneForm("(defn f [x] (+ x 1))");
    const items = form.data.list;
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("defn", items[0].data.symbol.name);
    try testing.expectEqualStrings("f", items[1].data.symbol.name);
    try testing.expect(items[2].data == .vector);
    try testing.expect(items[3].data == .list);
}

test "Reader - quote" {
    const form = try readOneForm("'foo");
    const items = form.data.list;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("quote", items[0].data.symbol.name);
    try testing.expectEqualStrings("foo", items[1].data.symbol.name);
}

test "Reader - deref" {
    const form = try readOneForm("@a");
    const items = form.data.list;
    try testing.expectEqualStrings("deref", items[0].data.symbol.name);
    try testing.expectEqualStrings("a", items[1].data.symbol.name);
}

test "Reader - var quote" {
    const form = try readOneForm("#'foo");
    const items = form.data.list;
    try testing.expectEqualStrings("var", items[0].data.symbol.name);
    try testing.expectEqualStrings("foo", items[1].data.symbol.name);
}

test "Reader - unquote" {
    const form = try readOneForm("~x");
    const items = form.data.list;
    try testing.expectEqualStrings("unquote", items[0].data.symbol.name);
    try testing.expectEqualStrings("x", items[1].data.symbol.name);
}

test "Reader - unquote-splicing" {
    const form = try readOneForm("~@xs");
    const items = form.data.list;
    try testing.expectEqualStrings("unquote-splicing", items[0].data.symbol.name);
    try testing.expectEqualStrings("xs", items[1].data.symbol.name);
}

test "Reader - discard" {
    const form = try readOneForm("#_ignored 42");
    try testing.expectEqual(@as(i64, 42), form.data.integer);
}

test "Reader - meta keyword" {
    const form = try readOneForm("^:dynamic foo");
    const items = form.data.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("with-meta", items[0].data.symbol.name);
    try testing.expectEqualStrings("foo", items[1].data.symbol.name);
    // meta-map should be {:dynamic true}
    const meta_map = items[2].data.map;
    try testing.expectEqualStrings("dynamic", meta_map[0].data.keyword.name);
    try testing.expectEqual(true, meta_map[1].data.boolean);
}

test "Reader - meta symbol (tag)" {
    const form = try readOneForm("^String x");
    const items = form.data.list;
    try testing.expectEqualStrings("with-meta", items[0].data.symbol.name);
    try testing.expectEqualStrings("x", items[1].data.symbol.name);
    const meta_map = items[2].data.map;
    try testing.expectEqualStrings("tag", meta_map[0].data.keyword.name);
    try testing.expectEqualStrings("String", meta_map[1].data.symbol.name);
}

test "Reader - regex" {
    const form = try readOneForm("#\"\\d+\"");
    try testing.expectEqualStrings("\\d+", form.data.regex);
}

test "Reader - symbolic ##Inf, ##NaN" {
    const f1 = (try readOneForm("##Inf")).data.float;
    try testing.expect(std.math.isInf(f1));

    const f2 = (try readOneForm("##NaN")).data.float;
    try testing.expect(std.math.isNan(f2));
}

test "Reader - reader conditional :clj" {
    const form = try readOneForm("#?(:clj 42 :cljs 99)");
    try testing.expectEqual(@as(i64, 42), form.data.integer);
}

test "Reader - reader conditional :default" {
    const form = try readOneForm("#?(:cljs 99 :default 7)");
    try testing.expectEqual(@as(i64, 7), form.data.integer);
}

test "Reader - fn literal" {
    const form = try readOneForm("#(+ % 1)");
    const items = form.data.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("fn*", items[0].data.symbol.name);
    // params vector
    const params = items[1].data.vector;
    try testing.expectEqual(@as(usize, 1), params.len);
    try testing.expectEqualStrings("%1", params[0].data.symbol.name);
    // body: (+ %1 1) — % normalized to %1
    const body = items[2].data.list;
    try testing.expectEqualStrings("+", body[0].data.symbol.name);
    try testing.expectEqualStrings("%1", body[1].data.symbol.name);
}

test "Reader - syntax quote simple symbol" {
    const form = try readOneForm("`foo");
    // Should produce (quote foo)
    const items = form.data.list;
    try testing.expectEqualStrings("quote", items[0].data.symbol.name);
    try testing.expectEqualStrings("foo", items[1].data.symbol.name);
}

test "Reader - readAll" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var r = Reader.init(arena.allocator(), "1 2 3");
    const forms = try r.readAll();
    try testing.expectEqual(@as(usize, 3), forms.len);
    try testing.expectEqual(@as(i64, 1), forms[0].data.integer);
    try testing.expectEqual(@as(i64, 2), forms[1].data.integer);
    try testing.expectEqual(@as(i64, 3), forms[2].data.integer);
}

test "Reader - empty input" {
    const result = try readOne("");
    try testing.expect(result == null);
}

test "Reader - whitespace only" {
    const result = try readOne("   \n\t  ");
    try testing.expect(result == null);
}

test "Reader - unmatched delimiter" {
    const result = readOneForm(")");
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - unexpected EOF in list" {
    const result = readOneForm("(1 2");
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - odd map literal" {
    const result = readOneForm("{:a 1 :b}");
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - tagged literal" {
    const form = try readOneForm("#inst \"2024-01-01\"");
    try testing.expectEqualStrings("inst", form.data.tag.tag);
    try testing.expectEqualStrings("2024-01-01", form.data.tag.form.data.string);
}

test "Reader - let pattern" {
    const form = try readOneForm("(let [x 1] [x])");
    try testing.expect(form.data == .list);
    try testing.expectEqual(@as(usize, 3), form.data.list.len);
    try testing.expect(form.data.list[1].data == .vector);
    try testing.expect(form.data.list[2].data == .vector);
}

// === Input Validation Tests ===

fn readOneWithLimits(source: []const u8, limits: Reader.Limits) ReadError!?Form {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    var r = Reader.initWithLimits(allocator, source, limits);
    return r.read();
}

test "Reader - depth limit exceeded" {
    // Build deeply nested list: (((((...))))) with depth > 4
    const source = "(((((1)))))";
    const result = readOneWithLimits(source, .{ .max_depth = 4 });
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - depth limit not exceeded" {
    const source = "(((1)))";
    const form = (try readOneWithLimits(source, .{ .max_depth = 4 })).?;
    try testing.expect(form.data == .list);
}

test "Reader - collection element count limit exceeded" {
    // Build vector with 6 elements, limit to 5
    const source = "[1 2 3 4 5 6]";
    const result = readOneWithLimits(source, .{ .max_collection_count = 5 });
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - collection element count limit not exceeded" {
    const source = "[1 2 3 4 5]";
    const form = (try readOneWithLimits(source, .{ .max_collection_count = 5 })).?;
    try testing.expect(form.data == .vector);
    try testing.expectEqual(@as(usize, 5), form.data.vector.len);
}

test "Reader - string size limit exceeded" {
    // Build string with 10 chars, limit to 5
    const source = "\"0123456789\"";
    const result = readOneWithLimits(source, .{ .max_string_size = 5 });
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - string size limit not exceeded" {
    const source = "\"hello\"";
    const form = (try readOneWithLimits(source, .{ .max_string_size = 10 })).?;
    try testing.expect(form.data == .string);
}

test "Reader - default limits allow normal input" {
    const source = "(defn f [x] (+ x 1))";
    const form = (try readOneWithLimits(source, .{})).?;
    try testing.expect(form.data == .list);
}

test "Reader - depth limit with nested vectors and maps" {
    // [{:a [1]}] = depth 3 (vector > map > vector)
    const source = "[{:a [1]}]";
    const result = readOneWithLimits(source, .{ .max_depth = 2 });
    try testing.expectError(error.SyntaxError, result);
}

test "Reader - depth tracks reader macros" {
    // '(1) expands to (quote (1)) — the list inside quote adds depth
    // With readWrapped: depth goes to 1 (for the inner readForm)
    // Then readList: depth goes to 2
    const source = "'((1))";
    const result = readOneWithLimits(source, .{ .max_depth = 2 });
    try testing.expectError(error.SyntaxError, result);
}
