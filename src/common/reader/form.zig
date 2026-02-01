// Form — Reader output representing syntactic Clojure data.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Form wraps syntactic data with source location info.
// Unlike Value (runtime), Form preserves reader-level details
// (e.g., quote syntax, metadata annotation) for the Analyzer.

const std = @import("std");

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

    // Regex literal
    regex: []const u8,

    // Reader macro wrappers (quote, deref, meta, etc.)
    // The inner form is a single-element slice for pointer stability.
    quote: *const Form, // 'x
    deref: *const Form, // @x
    syntax_quote: *const Form, // `x
    unquote: *const Form, // ~x
    unquote_splicing: *const Form, // ~@x
    var_quote: *const Form, // #'x
    meta: MetaPair, // ^meta form
    discard, // #_ (reader discards next form; placeholder)
    tag: TaggedLiteral, // #inst "..." etc.
};

/// Namespace-qualified name reference (for symbols and keywords).
pub const SymbolRef = struct {
    ns: ?[]const u8,
    name: []const u8,
};

/// Metadata annotation: ^meta form
pub const MetaPair = struct {
    meta: *const Form,
    form: *const Form,
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
            .regex => "regex",
            .quote => "quote",
            .deref => "deref",
            .syntax_quote => "syntax_quote",
            .unquote => "unquote",
            .unquote_splicing => "unquote_splicing",
            .var_quote => "var_quote",
            .meta => "meta",
            .discard => "discard",
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
    pub fn formatPrStr(self: Form, writer: anytype) anyerror!void {
        switch (self.data) {
            .nil => try writer.writeAll("nil"),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |n| try writer.print("{d}", .{n}),
            .float => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try writer.writeAll(s);
            },
            .char => |c| try writeChar(writer, c),
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .symbol => |sym| try writeSymbol(writer, sym),
            .keyword => |sym| {
                try writer.writeByte(':');
                try writeSymbol(writer, sym);
            },
            .list => |items| try writeSeq(writer, "(", ")", items),
            .vector => |items| try writeSeq(writer, "[", "]", items),
            .map => |items| {
                try writer.writeByte('{');
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    if (i > 0) try writer.writeAll(", ");
                    try items[i].formatPrStr(writer);
                    try writer.writeByte(' ');
                    if (i + 1 < items.len) {
                        try items[i + 1].formatPrStr(writer);
                    }
                }
                try writer.writeByte('}');
            },
            .set => |items| try writeSeq(writer, "#{", "}", items),
            .regex => |pattern| {
                try writer.writeAll("#\"");
                try writer.writeAll(pattern);
                try writer.writeByte('"');
            },
            .quote => |inner| {
                try writer.writeByte('\'');
                try inner.formatPrStr(writer);
            },
            .deref => |inner| {
                try writer.writeByte('@');
                try inner.formatPrStr(writer);
            },
            .syntax_quote => |inner| {
                try writer.writeByte('`');
                try inner.formatPrStr(writer);
            },
            .unquote => |inner| {
                try writer.writeByte('~');
                try inner.formatPrStr(writer);
            },
            .unquote_splicing => |inner| {
                try writer.writeAll("~@");
                try inner.formatPrStr(writer);
            },
            .var_quote => |inner| {
                try writer.writeAll("#'");
                try inner.formatPrStr(writer);
            },
            .meta => |m| {
                try writer.writeByte('^');
                try m.meta.formatPrStr(writer);
                try writer.writeByte(' ');
                try m.form.formatPrStr(writer);
            },
            .discard => try writer.writeAll("#_"),
            .tag => |t| {
                try writer.writeByte('#');
                try writer.writeAll(t.tag);
                try writer.writeByte(' ');
                try t.form.formatPrStr(writer);
            },
        }
    }
};

fn writeSymbol(writer: anytype, sym: SymbolRef) anyerror!void {
    if (sym.ns) |ns| {
        try writer.writeAll(ns);
        try writer.writeByte('/');
    }
    try writer.writeAll(sym.name);
}

fn writeChar(writer: anytype, c: u21) anyerror!void {
    switch (c) {
        '\n' => try writer.writeAll("\\newline"),
        '\r' => try writer.writeAll("\\return"),
        '\t' => try writer.writeAll("\\tab"),
        ' ' => try writer.writeAll("\\space"),
        '\x08' => try writer.writeAll("\\backspace"),
        '\x0c' => try writer.writeAll("\\formfeed"),
        else => {
            try writer.writeByte('\\');
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &enc) catch 1;
            try writer.writeAll(enc[0..len]);
        },
    }
}

fn writeSeq(writer: anytype, open: []const u8, close: []const u8, items: []const Form) anyerror!void {
    try writer.writeAll(open);
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(' ');
        try item.formatPrStr(writer);
    }
    try writer.writeAll(close);
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
    var stream = std.io.fixedBufferStream(&buf);
    try form.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("nil", stream.getWritten());
}

test "format - boolean" {
    var buf: [256]u8 = undefined;
    {
        var stream = std.io.fixedBufferStream(&buf);
        const t = Form{ .data = .{ .boolean = true } };
        try t.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("true", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const f = Form{ .data = .{ .boolean = false } };
        try f.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("false", stream.getWritten());
    }
}

test "format - integer and float" {
    var buf: [256]u8 = undefined;
    {
        var stream = std.io.fixedBufferStream(&buf);
        const i = Form{ .data = .{ .integer = 42 } };
        try i.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("42", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const f = Form{ .data = .{ .float = 3.14 } };
        try f.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("3.14", stream.getWritten());
    }
}

test "format - string" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const s = Form{ .data = .{ .string = "hello" } };
    try s.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("\"hello\"", stream.getWritten());
}

test "format - symbol" {
    var buf: [256]u8 = undefined;
    {
        var stream = std.io.fixedBufferStream(&buf);
        const sym = Form{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } };
        try sym.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("foo", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const sym = Form{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = "+" } } };
        try sym.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("clojure.core/+", stream.getWritten());
    }
}

test "format - keyword" {
    var buf: [256]u8 = undefined;
    {
        var stream = std.io.fixedBufferStream(&buf);
        const kw = Form{ .data = .{ .keyword = .{ .ns = null, .name = "foo" } } };
        try kw.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings(":foo", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const kw = Form{ .data = .{ .keyword = .{ .ns = "user", .name = "bar" } } };
        try kw.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings(":user/bar", stream.getWritten());
    }
}

test "format - list" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const list = Form{ .data = .{ .list = &items } };
    try list.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("(1 + 2)", stream.getWritten());
}

test "format - vector" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const vec = Form{ .data = .{ .vector = &items } };
    try vec.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("[1 2]", stream.getWritten());
}

test "format - map" {
    const items = [_]Form{
        .{ .data = .{ .keyword = .{ .ns = null, .name = "a" } } },
        .{ .data = .{ .integer = 1 } },
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const map = Form{ .data = .{ .map = &items } };
    try map.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("{:a 1}", stream.getWritten());
}

test "format - set" {
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const set = Form{ .data = .{ .set = &items } };
    try set.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("#{1 2}", stream.getWritten());
}

test "format - regex" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const re = Form{ .data = .{ .regex = "\\d+" } };
    try re.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("#\"\\d+\"", stream.getWritten());
}

test "format - quote" {
    const inner = Form{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const quoted = Form{ .data = .{ .quote = &inner } };
    try quoted.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("'foo", stream.getWritten());
}

test "format - deref" {
    const inner = Form{ .data = .{ .symbol = .{ .ns = null, .name = "a" } } };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const form = Form{ .data = .{ .deref = &inner } };
    try form.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("@a", stream.getWritten());
}

test "format - char literal" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const c = Form{ .data = .{ .char = 'A' } };
    try c.formatPrStr(stream.writer());
    try std.testing.expectEqualStrings("\\A", stream.getWritten());
}

test "format - special char names" {
    var buf: [256]u8 = undefined;
    {
        var stream = std.io.fixedBufferStream(&buf);
        const c = Form{ .data = .{ .char = '\n' } };
        try c.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("\\newline", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const c = Form{ .data = .{ .char = ' ' } };
        try c.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("\\space", stream.getWritten());
    }
    {
        var stream = std.io.fixedBufferStream(&buf);
        const c = Form{ .data = .{ .char = '\t' } };
        try c.formatPrStr(stream.writer());
        try std.testing.expectEqualStrings("\\tab", stream.getWritten());
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
