//! Form — the AST emitted by the Reader and consumed by the Analyzer.
//!
//! Each Form carries syntactic shape (`FormData`) plus a `SourceLocation`
//! borrowed from `runtime/error.zig`. Forms preserve reader-level detail
//! (quote syntax, literal notation) that the runtime `Value` does not —
//! they live in the per-eval node arena, never in GC memory, so the GC
//! never traces them.

const std = @import("std");
const Writer = std.Io.Writer;
const SourceLocation = @import("../runtime/error.zig").SourceLocation;

/// Namespace-qualified identifier reference (symbol or keyword).
pub const SymbolRef = struct {
    ns: ?[]const u8 = null,
    name: []const u8,
};

/// Reader-level shape. Maps cleanly to printable EDN.
pub const FormData = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,

    symbol: SymbolRef,
    keyword: SymbolRef,

    list: []const Form,
    vector: []const Form,
    /// Flat k/v pairs: `[k1, v1, k2, v2, ...]`. Reader-emitted maps stay
    /// flat to keep the analyzer's iteration trivial.
    map: []const Form,
};

/// AST node. Source location is required and defaults to "unknown".
pub const Form = struct {
    data: FormData,
    location: SourceLocation = .{},

    /// Type name suitable for error messages.
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

    /// Clojure truthiness: only `nil` and `false` are falsy.
    pub fn isTruthy(self: Form) bool {
        return switch (self.data) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    /// Write a `pr-str` representation to `w`.
    pub fn formatPrStr(self: Form, w: *Writer) Writer.Error!void {
        switch (self.data) {
            .nil => try w.writeAll("nil"),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |i| try w.print("{d}", .{i}),
            .float => |f| try formatFloat(w, f),
            .string => |s| try formatString(w, s),
            .symbol => |sym| {
                if (sym.ns) |ns| {
                    try w.writeAll(ns);
                    try w.writeByte('/');
                }
                try w.writeAll(sym.name);
            },
            .keyword => |kw| {
                try w.writeByte(':');
                if (kw.ns) |ns| {
                    try w.writeAll(ns);
                    try w.writeByte('/');
                }
                try w.writeAll(kw.name);
            },
            .list => |items| try formatCollection(w, "(", ")", items),
            .vector => |items| try formatCollection(w, "[", "]", items),
            .map => |items| try formatMapEntries(w, items),
        }
    }

    /// Format into an allocated string. Caller owns the returned slice.
    pub fn toString(self: Form, alloc: std.mem.Allocator) ![]u8 {
        var aw: Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try self.formatPrStr(&aw.writer);
        return aw.toOwnedSlice();
    }
};

// --- formatting helpers ---

fn formatFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) {
        try w.writeAll("##NaN");
    } else if (std.math.isPositiveInf(f)) {
        try w.writeAll("##Inf");
    } else if (std.math.isNegativeInf(f)) {
        try w.writeAll("##-Inf");
    } else {
        try w.print("{d}", .{f});
    }
}

fn formatString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn formatCollection(w: *Writer, open: []const u8, close: []const u8, items: []const Form) Writer.Error!void {
    try w.writeAll(open);
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(' ');
        try item.formatPrStr(w);
    }
    try w.writeAll(close);
}

fn formatMapEntries(w: *Writer, items: []const Form) Writer.Error!void {
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
}

// --- tests ---

const testing = std.testing;

test "Form typeName covers each kind" {
    try testing.expectEqualStrings("nil", (Form{ .data = .nil }).typeName());
    try testing.expectEqualStrings("boolean", (Form{ .data = .{ .boolean = true } }).typeName());
    try testing.expectEqualStrings("integer", (Form{ .data = .{ .integer = 1 } }).typeName());
    try testing.expectEqualStrings("float", (Form{ .data = .{ .float = 1.5 } }).typeName());
    try testing.expectEqualStrings("string", (Form{ .data = .{ .string = "x" } }).typeName());
    try testing.expectEqualStrings("symbol", (Form{ .data = .{ .symbol = .{ .name = "x" } } }).typeName());
    try testing.expectEqualStrings("keyword", (Form{ .data = .{ .keyword = .{ .name = "x" } } }).typeName());
    try testing.expectEqualStrings("list", (Form{ .data = .{ .list = &.{} } }).typeName());
    try testing.expectEqualStrings("vector", (Form{ .data = .{ .vector = &.{} } }).typeName());
    try testing.expectEqualStrings("map", (Form{ .data = .{ .map = &.{} } }).typeName());
}

test "isTruthy follows Clojure truthiness" {
    try testing.expect(!(Form{ .data = .nil }).isTruthy());
    try testing.expect((Form{ .data = .{ .boolean = true } }).isTruthy());
    try testing.expect(!(Form{ .data = .{ .boolean = false } }).isTruthy());
    try testing.expect((Form{ .data = .{ .integer = 0 } }).isTruthy());
    try testing.expect((Form{ .data = .{ .string = "" } }).isTruthy());
}

test "Form carries SourceLocation" {
    const f = Form{ .data = .nil, .location = .{ .file = "core.clj", .line = 10, .column = 5 } };
    try testing.expectEqualStrings("core.clj", f.location.file);
    try testing.expectEqual(@as(u32, 10), f.location.line);
    try testing.expectEqual(@as(u16, 5), f.location.column);
}

fn expectPr(form: Form, expected: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try form.formatPrStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "formatPrStr renders atoms" {
    try expectPr(.{ .data = .nil }, "nil");
    try expectPr(.{ .data = .{ .boolean = true } }, "true");
    try expectPr(.{ .data = .{ .boolean = false } }, "false");
    try expectPr(.{ .data = .{ .integer = -42 } }, "-42");
}

test "formatPrStr escapes strings" {
    try expectPr(.{ .data = .{ .string = "hello\nworld" } }, "\"hello\\nworld\"");
    try expectPr(.{ .data = .{ .string = "a\"b\\c\td" } }, "\"a\\\"b\\\\c\\td\"");
}

test "formatPrStr renders symbols and keywords (qualified or not)" {
    try expectPr(.{ .data = .{ .symbol = .{ .name = "foo" } } }, "foo");
    try expectPr(.{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = "map" } } }, "clojure.core/map");
    try expectPr(.{ .data = .{ .keyword = .{ .name = "foo" } } }, ":foo");
    try expectPr(.{ .data = .{ .keyword = .{ .ns = "my.ns", .name = "key" } } }, ":my.ns/key");
}

test "formatPrStr renders collections" {
    const list_items = [_]Form{
        .{ .data = .{ .symbol = .{ .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    try expectPr(.{ .data = .{ .list = &list_items } }, "(+ 1 2)");

    const vec_items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .keyword = .{ .name = "a" } } },
        .{ .data = .{ .string = "b" } },
    };
    try expectPr(.{ .data = .{ .vector = &vec_items } }, "[1 :a \"b\"]");

    const map_items = [_]Form{
        .{ .data = .{ .keyword = .{ .name = "k" } } },
        .{ .data = .{ .integer = 1 } },
    };
    try expectPr(.{ .data = .{ .map = &map_items } }, "{:k 1}");

    try expectPr(.{ .data = .{ .list = &.{} } }, "()");
}

test "formatPrStr renders special float values" {
    try expectPr(.{ .data = .{ .float = std.math.nan(f64) } }, "##NaN");
    try expectPr(.{ .data = .{ .float = std.math.inf(f64) } }, "##Inf");
    try expectPr(.{ .data = .{ .float = -std.math.inf(f64) } }, "##-Inf");
}

test "toString allocates the expected output" {
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const f = Form{ .data = .{ .list = &items } };
    const s = try f.toString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("(+ 1 2)", s);
}
