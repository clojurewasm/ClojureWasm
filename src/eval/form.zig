//! Form — the AST produced by the Reader.
//!
//! Each Form carries syntactic data (FormData tagged union) plus source location.
//! Forms are the bridge between text and evaluation: Reader produces them,
//! Analyzer consumes them. Unlike runtime Values, Forms preserve reader-level
//! detail (e.g. quote syntax, literal notation).

const std = @import("std");

/// Namespace-qualified identifier reference (symbol or keyword).
pub const SymbolRef = struct {
    ns: ?[]const u8 = null,
    name: []const u8,
};

/// The syntactic data of a Form.
pub const FormData = union(enum) {
    // Literals
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,

    // Identifiers
    symbol: SymbolRef,
    keyword: SymbolRef,

    // Collections (elements are Form slices)
    list: []const Form,
    vector: []const Form,
    map: []const Form, // flat k/v pairs: [k1, v1, k2, v2, ...]
};

/// AST node produced by the Reader. Every node carries source location.
pub const Form = struct {
    data: FormData,
    line: u32 = 0, // 1-based, 0 = unknown
    column: u16 = 0, // 0-based

    /// Return the type name of this form for error messages.
    pub fn typeName(self: Form) []const u8 {
        return switch (self.data) {
            .nil => "nil",
            .boolean => "boolean",
            .integer => "integer",
            .float => "float",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
            .map => "map",
        };
    }

    /// Clojure truthiness: only nil and false are falsy.
    pub fn isTruthy(self: Form) bool {
        return switch (self.data) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    /// Write pr-str representation to a writer.
    pub fn formatPrStr(self: Form, writer: std.io.AnyWriter) anyerror!void {
        switch (self.data) {
            .nil => try writer.writeAll("nil"),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try std.fmt.format(writer, "{d}", .{i}),
            .float => |f| try formatFloat(writer, f),
            .string => |s| try formatString(writer, s),
            .symbol => |sym| {
                if (sym.ns) |ns| {
                    try writer.writeAll(ns);
                    try writer.writeByte('/');
                }
                try writer.writeAll(sym.name);
            },
            .keyword => |kw| {
                try writer.writeByte(':');
                if (kw.ns) |ns| {
                    try writer.writeAll(ns);
                    try writer.writeByte('/');
                }
                try writer.writeAll(kw.name);
            },
            .list => |items| try formatCollection(writer, "(", ")", items),
            .vector => |items| try formatCollection(writer, "[", "]", items),
            .map => |items| try formatMapEntries(writer, items),
        }
    }

    /// Format into an allocated string.
    pub fn toString(self: Form, alloc: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(alloc);
        try self.formatPrStr(buf.writer().any());
        return buf.toOwnedSlice();
    }
};

// --- Formatting helpers ---

fn formatFloat(writer: std.io.AnyWriter, f: f64) anyerror!void {
    if (std.math.isNan(f)) {
        try writer.writeAll("##NaN");
    } else if (std.math.isPositiveInf(f)) {
        try writer.writeAll("##Inf");
    } else if (std.math.isNegativeInf(f)) {
        try writer.writeAll("##-Inf");
    } else {
        try std.fmt.format(writer, "{d}", .{f});
        // TODO: ensure decimal point is present for whole-number floats
    }
}

fn formatString(writer: std.io.AnyWriter, s: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn formatCollection(writer: std.io.AnyWriter, open: []const u8, close: []const u8, items: []const Form) anyerror!void {
    try writer.writeAll(open);
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(' ');
        try item.formatPrStr(writer);
    }
    try writer.writeAll(close);
}

fn formatMapEntries(writer: std.io.AnyWriter, items: []const Form) anyerror!void {
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
}

// --- Tests ---

const testing = std.testing;

test "Form nil" {
    const f = Form{ .data = .nil };
    try testing.expectEqualStrings("nil", f.typeName());
    try testing.expect(!f.isTruthy());
}

test "Form boolean" {
    const t = Form{ .data = .{ .boolean = true } };
    const fls = Form{ .data = .{ .boolean = false } };
    try testing.expect(t.isTruthy());
    try testing.expect(!fls.isTruthy());
}

test "Form integer" {
    const f = Form{ .data = .{ .integer = 42 }, .line = 1, .column = 0 };
    try testing.expectEqualStrings("integer", f.typeName());
    try testing.expect(f.isTruthy());
    try testing.expectEqual(@as(u32, 1), f.line);
}

test "Form with source location" {
    const f = Form{ .data = .nil, .line = 10, .column = 5 };
    try testing.expectEqual(@as(u32, 10), f.line);
    try testing.expectEqual(@as(u16, 5), f.column);
}

test "formatPrStr nil" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .nil };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("nil", fbs.getWritten());
}

test "formatPrStr boolean" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .boolean = true } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("true", fbs.getWritten());
}

test "formatPrStr integer" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .integer = -42 } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("-42", fbs.getWritten());
}

test "formatPrStr string with escapes" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .string = "hello\nworld" } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("\"hello\\nworld\"", fbs.getWritten());
}

test "formatPrStr symbol" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .symbol = .{ .name = "foo" } } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("foo", fbs.getWritten());
}

test "formatPrStr qualified symbol" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = "map" } } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("clojure.core/map", fbs.getWritten());
}

test "formatPrStr keyword" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .keyword = .{ .name = "foo" } } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings(":foo", fbs.getWritten());
}

test "formatPrStr qualified keyword" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .keyword = .{ .ns = "my.ns", .name = "key" } } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings(":my.ns/key", fbs.getWritten());
}

test "formatPrStr list" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const f = Form{ .data = .{ .list = &items } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("(+ 1 2)", fbs.getWritten());
}

test "formatPrStr vector" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .keyword = .{ .name = "a" } } },
        .{ .data = .{ .string = "b" } },
    };
    const f = Form{ .data = .{ .vector = &items } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("[1 :a \"b\"]", fbs.getWritten());
}

test "formatPrStr map" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const items = [_]Form{
        .{ .data = .{ .keyword = .{ .name = "k" } } },
        .{ .data = .{ .integer = 1 } },
    };
    const f = Form{ .data = .{ .map = &items } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("{:k 1}", fbs.getWritten());
}

test "formatPrStr empty list" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const f = Form{ .data = .{ .list = &.{} } };
    try f.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("()", fbs.getWritten());
}

test "formatPrStr special floats" {
    var buf: [32]u8 = undefined;

    // NaN
    var fbs = std.io.fixedBufferStream(&buf);
    const nan = Form{ .data = .{ .float = std.math.nan(f64) } };
    try nan.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("##NaN", fbs.getWritten());

    // Inf
    fbs = std.io.fixedBufferStream(&buf);
    const inf = Form{ .data = .{ .float = std.math.inf(f64) } };
    try inf.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("##Inf", fbs.getWritten());

    // -Inf
    fbs = std.io.fixedBufferStream(&buf);
    const neg_inf = Form{ .data = .{ .float = -std.math.inf(f64) } };
    try neg_inf.formatPrStr(fbs.writer().any());
    try testing.expectEqualStrings("##-Inf", fbs.getWritten());
}
