// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Form — Reader output representing syntactic Clojure data.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Form wraps syntactic data with source location info.
// Unlike Value (runtime), Form preserves reader-level details
// (e.g., quote syntax, metadata annotation) for the Analyzer.

const std = @import("std");
const Writer = std.Io.Writer;

/// Syntactic data variants produced by the Reader.
pub const FormData = union(enum) {
    // Literals
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    char: u21,
    string: []const u8,

    // Identifiers
    symbol: SymbolRef,
    keyword: SymbolRef,

    // Collections (elements are Form slices)
    list: []const Form,
    vector: []const Form,
    map: []const Form, // [k1, v1, k2, v2, ...] flat pairs
    set: []const Form,

    // BigInt literal (N suffix or overflow)
    big_int: []const u8,

    // BigDecimal literal (M suffix)
    big_decimal: []const u8,

    // Ratio literal (e.g. 1/3, 22/7)
    ratio: RatioLiteral,

    // Regex literal
    regex: []const u8,

    // Tagged literal: #inst "..." etc. (needed by Analyzer)
    tag: TaggedLiteral,
};

/// Namespace-qualified name reference (for symbols and keywords).
pub const SymbolRef = struct {
    ns: ?[]const u8,
    name: []const u8,
    auto_resolve: bool = false, // true for ::foo auto-resolved keywords
};

/// Ratio literal numerator/denominator text (e.g. "22" / "7").
pub const RatioLiteral = struct {
    numerator: []const u8,
    denominator: []const u8,
};

/// Tagged literal: #tag form
pub const TaggedLiteral = struct {
    tag: []const u8,
    form: *const Form,
};

/// Form — Reader output with source location.
pub const Form = struct {
    data: FormData,
    line: u32 = 0,
    column: u16 = 0,

    /// Return the type name for debugging.
    pub fn typeName(self: Form) []const u8 {
        return switch (self.data) {
            .nil => "nil",
            .boolean => "boolean",
            .integer => "integer",
            .float => "float",
            .char => "char",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .big_int => "big_int",
            .big_decimal => "big_decimal",
            .ratio => "ratio",
            .regex => "regex",
            .tag => "tag",
        };
    }

    /// Clojure truthiness: nil and false are falsy, everything else is truthy.
    pub fn isTruthy(self: Form) bool {
        return switch (self.data) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    /// Print representation (pr-str semantics).
    pub fn formatPrStr(self: Form, w: *Writer) Writer.Error!void {
        switch (self.data) {
            .nil => try w.writeAll("nil"),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |n| try w.print("{d}", .{n}),
            .float => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try w.writeAll(s);
            },
            .char => |c| try writeChar(w, c),
            .string => |s| {
                try w.writeByte('"');
                try w.writeAll(s);
                try w.writeByte('"');
            },
            .symbol => |sym| try writeSymbol(w, sym),
            .keyword => |sym| {
                try w.writeByte(':');
                try writeSymbol(w, sym);
            },
            .list => |items| try writeSeq(w, "(", ")", items),
            .vector => |items| try writeSeq(w, "[", "]", items),
            .map => |items| {
                try w.writeByte('{');
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    if (i > 0) try w.writeAll(", ");
                    try items[i].formatPrStr(w);
                    try w.writeByte(' ');
                    if (i + 1 < items.len) {
                        try items[i + 1].formatPrStr(w);
                    }
                }
                try w.writeByte('}');
            },
            .set => |items| try writeSeq(w, "#{", "}", items),
            .big_int => |s| {
                try w.writeAll(s);
                try w.writeByte('N');
            },
            .big_decimal => |s| {
                try w.writeAll(s);
                try w.writeByte('M');
            },
            .ratio => |r| {
                try w.writeAll(r.numerator);
                try w.writeByte('/');
                try w.writeAll(r.denominator);
            },
            .regex => |pattern| {
                try w.writeAll("#\"");
                try w.writeAll(pattern);
                try w.writeByte('"');
            },
            .tag => |t| {
                try w.writeByte('#');
                try w.writeAll(t.tag);
                try w.writeByte(' ');
                try t.form.formatPrStr(w);
            },
        }
    }
};

fn writeSymbol(w: *Writer, sym: SymbolRef) Writer.Error!void {
    if (sym.ns) |ns| {
        try w.writeAll(ns);
        try w.writeByte('/');
    }
    try w.writeAll(sym.name);
}

fn writeChar(w: *Writer, c: u21) Writer.Error!void {
    switch (c) {
        '\n' => try w.writeAll("\\newline"),
        '\r' => try w.writeAll("\\return"),
        '\t' => try w.writeAll("\\tab"),
        ' ' => try w.writeAll("\\space"),
        '\x08' => try w.writeAll("\\backspace"),
        '\x0c' => try w.writeAll("\\formfeed"),
        else => {
            try w.writeByte('\\');
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &enc) catch 1;
            try w.writeAll(enc[0..len]);
        },
    }
}

fn writeSeq(w: *Writer, open: []const u8, close: []const u8, items: []const Form) Writer.Error!void {
    try w.writeAll(open);
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(' ');
        try item.formatPrStr(w);
    }
    try w.writeAll(close);
}

test "nil literal" {
    const form = Form{ .data = .nil, .line = 1, .column = 0 };
    try std.testing.expect(form.data == .nil);
    try std.testing.expectEqual(@as(u32, 1), form.line);
    try std.testing.expectEqual(@as(u16, 0), form.column);
}

test "boolean literals" {
    const t = Form{ .data = .{ .boolean = true } };
    const f = Form{ .data = .{ .boolean = false } };
    try std.testing.expectEqual(true, t.data.boolean);
    try std.testing.expectEqual(false, f.data.boolean);
}

test "numeric literals" {
    const i = Form{ .data = .{ .integer = 42 } };
    const f = Form{ .data = .{ .float = 3.14 } };
    try std.testing.expectEqual(@as(i64, 42), i.data.integer);
    try std.testing.expectEqual(@as(f64, 3.14), f.data.float);
}

test "string and char" {
    const s = Form{ .data = .{ .string = "hello" } };
    const c = Form{ .data = .{ .char = 'A' } };
    try std.testing.expectEqualStrings("hello", s.data.string);
    try std.testing.expectEqual(@as(u21, 'A'), c.data.char);
}

test "symbol and keyword" {
    const sym = Form{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } };
    const kw = Form{ .data = .{ .keyword = .{ .ns = "user", .name = "bar" } } };
    try std.testing.expectEqualStrings("foo", sym.data.symbol.name);
    try std.testing.expect(sym.data.symbol.ns == null);
    try std.testing.expectEqualStrings("user", kw.data.keyword.ns.?);
    try std.testing.expectEqualStrings("bar", kw.data.keyword.name);
}

test "list collection" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
        .{ .data = .{ .integer = 3 } },
    };
    const list = Form{ .data = .{ .list = &items } };
    try std.testing.expectEqual(@as(usize, 3), list.data.list.len);
    try std.testing.expectEqual(@as(i64, 2), list.data.list[1].data.integer);
}

test "vector collection" {
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "a" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "b" } } },
    };
    const vec = Form{ .data = .{ .vector = &items } };
    try std.testing.expectEqual(@as(usize, 2), vec.data.vector.len);
}

test "map collection (flat key-value pairs)" {
    const items = [_]Form{
        .{ .data = .{ .keyword = .{ .ns = null, .name = "a" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .keyword = .{ .ns = null, .name = "b" } } },
        .{ .data = .{ .integer = 2 } },
    };
    const map = Form{ .data = .{ .map = &items } };
    try std.testing.expectEqual(@as(usize, 4), map.data.map.len);
}

test "set collection" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const set = Form{ .data = .{ .set = &items } };
    try std.testing.expectEqual(@as(usize, 2), set.data.set.len);
}

test "format - nil" {
    const form = Form{ .data = .nil };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try form.formatPrStr(&w);
    try std.testing.expectEqualStrings("nil", w.buffered());
}

test "format - boolean" {
    var buf: [256]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        const t = Form{ .data = .{ .boolean = true } };
        try t.formatPrStr(&w);
        try std.testing.expectEqualStrings("true", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const f = Form{ .data = .{ .boolean = false } };
        try f.formatPrStr(&w);
        try std.testing.expectEqualStrings("false", w.buffered());
    }
}

test "format - integer and float" {
    var buf: [256]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        const i = Form{ .data = .{ .integer = 42 } };
        try i.formatPrStr(&w);
        try std.testing.expectEqualStrings("42", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const f = Form{ .data = .{ .float = 3.14 } };
        try f.formatPrStr(&w);
        try std.testing.expectEqualStrings("3.14", w.buffered());
    }
}

test "format - string" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const s = Form{ .data = .{ .string = "hello" } };
    try s.formatPrStr(&w);
    try std.testing.expectEqualStrings("\"hello\"", w.buffered());
}

test "format - symbol" {
    var buf: [256]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        const sym = Form{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } };
        try sym.formatPrStr(&w);
        try std.testing.expectEqualStrings("foo", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const sym = Form{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = "+" } } };
        try sym.formatPrStr(&w);
        try std.testing.expectEqualStrings("clojure.core/+", w.buffered());
    }
}

test "format - keyword" {
    var buf: [256]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        const kw = Form{ .data = .{ .keyword = .{ .ns = null, .name = "foo" } } };
        try kw.formatPrStr(&w);
        try std.testing.expectEqualStrings(":foo", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const kw = Form{ .data = .{ .keyword = .{ .ns = "user", .name = "bar" } } };
        try kw.formatPrStr(&w);
        try std.testing.expectEqualStrings(":user/bar", w.buffered());
    }
}

test "format - list" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const list = Form{ .data = .{ .list = &items } };
    try list.formatPrStr(&w);
    try std.testing.expectEqualStrings("(1 + 2)", w.buffered());
}

test "format - vector" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const vec = Form{ .data = .{ .vector = &items } };
    try vec.formatPrStr(&w);
    try std.testing.expectEqualStrings("[1 2]", w.buffered());
}

test "format - map" {
    const items = [_]Form{
        .{ .data = .{ .keyword = .{ .ns = null, .name = "a" } } },
        .{ .data = .{ .integer = 1 } },
    };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const map = Form{ .data = .{ .map = &items } };
    try map.formatPrStr(&w);
    try std.testing.expectEqualStrings("{:a 1}", w.buffered());
}

test "format - set" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const set = Form{ .data = .{ .set = &items } };
    try set.formatPrStr(&w);
    try std.testing.expectEqualStrings("#{1 2}", w.buffered());
}

test "format - regex" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const re = Form{ .data = .{ .regex = "\\d+" } };
    try re.formatPrStr(&w);
    try std.testing.expectEqualStrings("#\"\\d+\"", w.buffered());
}

test "format - char literal" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const c = Form{ .data = .{ .char = 'A' } };
    try c.formatPrStr(&w);
    try std.testing.expectEqualStrings("\\A", w.buffered());
}

test "format - special char names" {
    var buf: [256]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        const c = Form{ .data = .{ .char = '\n' } };
        try c.formatPrStr(&w);
        try std.testing.expectEqualStrings("\\newline", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const c = Form{ .data = .{ .char = ' ' } };
        try c.formatPrStr(&w);
        try std.testing.expectEqualStrings("\\space", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        const c = Form{ .data = .{ .char = '\t' } };
        try c.formatPrStr(&w);
        try std.testing.expectEqualStrings("\\tab", w.buffered());
    }
}

test "typeName" {
    try std.testing.expectEqualStrings("nil", (Form{ .data = .nil }).typeName());
    try std.testing.expectEqualStrings("boolean", (Form{ .data = .{ .boolean = true } }).typeName());
    try std.testing.expectEqualStrings("integer", (Form{ .data = .{ .integer = 0 } }).typeName());
    try std.testing.expectEqualStrings("float", (Form{ .data = .{ .float = 0.0 } }).typeName());
    try std.testing.expectEqualStrings("string", (Form{ .data = .{ .string = "" } }).typeName());
    try std.testing.expectEqualStrings("symbol", (Form{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } }).typeName());
    try std.testing.expectEqualStrings("keyword", (Form{ .data = .{ .keyword = .{ .ns = null, .name = "x" } } }).typeName());
    try std.testing.expectEqualStrings("list", (Form{ .data = .{ .list = &.{} } }).typeName());
    try std.testing.expectEqualStrings("vector", (Form{ .data = .{ .vector = &.{} } }).typeName());
    try std.testing.expectEqualStrings("map", (Form{ .data = .{ .map = &.{} } }).typeName());
    try std.testing.expectEqualStrings("set", (Form{ .data = .{ .set = &.{} } }).typeName());
    try std.testing.expectEqualStrings("regex", (Form{ .data = .{ .regex = "" } }).typeName());
    try std.testing.expectEqualStrings("char", (Form{ .data = .{ .char = 'a' } }).typeName());
}

test "isTruthy" {
    // nil and false are falsy, everything else is truthy
    try std.testing.expect(!(Form{ .data = .nil }).isTruthy());
    try std.testing.expect(!(Form{ .data = .{ .boolean = false } }).isTruthy());
    try std.testing.expect((Form{ .data = .{ .boolean = true } }).isTruthy());
    try std.testing.expect((Form{ .data = .{ .integer = 0 } }).isTruthy());
    try std.testing.expect((Form{ .data = .{ .string = "" } }).isTruthy());
}
