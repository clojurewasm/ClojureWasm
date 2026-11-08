// SPDX-License-Identifier: EPL-2.0
//! Form — the AST emitted by the Reader and consumed by the Analyzer.
//!
//! Each Form carries syntactic shape (`FormData`) plus a `SourceLocation`
//! borrowed from `runtime/error.zig`. Forms preserve reader-level detail
//! (quote syntax, literal notation) that the runtime `Value` does not —
//! they live in the per-eval node arena, never in GC memory, so the GC
//! never traces them.

const std = @import("std");
const Writer = std.Io.Writer;
const SourceLocation = @import("../runtime/error/info.zig").SourceLocation;
const print = @import("../runtime/print.zig");

/// Namespace-qualified identifier reference (symbol or keyword).
pub const SymbolRef = struct {
    ns: ?[]const u8 = null,
    name: []const u8,
    /// Set by the reader for an auto-resolved keyword `::name` / `::alias/name`.
    /// The analyzer resolves it against the current namespace (or a require
    /// alias) at analyze time, since the reader is namespace-unaware. Always
    /// false for symbols and plain `:kw` keywords.
    auto_resolve: bool = false,
};

/// Reader-level shape. Maps cleanly to printable EDN.
pub const FormData = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    /// `\a` / `\newline` / `\uXXXX` / `\oNNN` — a character literal decoded
    /// to its Unicode codepoint by the reader; the analyzer lifts it to a
    /// `.char` Value via `Value.initChar`.
    char: u21,
    /// `42N`. The string slice is the digits without the trailing `N`,
    /// i.e. exactly what `std.math.big.int.Managed.setString` accepts.
    big_int_literal: []const u8,
    /// `1.5M`. The string slice is the decimal representation without
    /// the trailing `M`. Analyzer parses it into unscaled + scale.
    big_decimal_literal: []const u8,
    /// `1/3`. The string slice is the full `num/den` digit pair; the
    /// analyzer splits on `/` before parsing each side.
    ratio_literal: []const u8,
    /// `#"\d+"`. The string slice is the raw pattern source between
    /// `#"` and the closing `"` — no escape decoding (per JVM
    /// Clojure: `#"\\d"` matches a digit, the body is handed
    /// verbatim to the regex engine). Analyzer / evaluator turns
    /// the slice into a `.regex` Value via
    /// `runtime/regex/value.zig::alloc`.
    regex_literal: []const u8,
    string: []const u8,

    symbol: SymbolRef,
    keyword: SymbolRef,

    list: []const Form,
    vector: []const Form,
    /// Flat k/v pairs: `[k1, v1, k2, v2, ...]`. Reader-emitted maps stay
    /// flat to keep the analyzer's iteration trivial.
    map: []const Form,
    /// `#{1 2 3}` — set literal. Each element form is read in source
    /// order; the analyzer drops duplicates at conj time (set semantics).
    set: []const Form,
    /// `#tag form` — EDN tagged literal (ADR-0073). `tag` is a SymbolRef
    /// (ns/name split kept for a qualified record-tag `#my.ns/Rec`); `form`
    /// is the single value-form following the tag. The data-reader lookup +
    /// application happens at `formToValue` time against `*data-readers*`.
    tagged: TaggedForm,
    /// `` `form `` syntax-quote (ADR-0082). The reader only WRAPS the inner
    /// form; the analyzer expands it (template build + `~`/`~@` + `foo#`
    /// gensym), reusing `env.current_ns` — the reader stays ns-unaware.
    syntax_quote: *const Form,
    /// `~form` unquote — valid only inside a `syntax_quote`; the expander
    /// splices the inner form's value in unchanged.
    unquote: *const Form,
    /// `~@form` unquote-splicing — valid only inside a `syntax_quote` list /
    /// vector / set; the expander splices the inner seq's elements.
    unquote_splicing: *const Form,
};

/// `#tag form` payload. Boxed `form` (a `*const Form`) because a union
/// variant cannot hold its own type by value.
pub const TaggedForm = struct {
    tag: SymbolRef,
    form: *const Form,
};

/// AST node. Source location is required and defaults to "unknown".
pub const Form = struct {
    data: FormData,
    location: SourceLocation = .{},
    /// `^meta` reader-macro side-channel (D-183). cljw symbols are
    /// interned + metadata-less (ADR-0037 D6), so reader-attached
    /// metadata cannot ride a symbol Value — it rides the Form here
    /// instead, normalised to a map Form (`:kw`→`{:kw true}`,
    /// `Sym`→`{:tag Sym}`). The analyzer reads it (e.g. `analyzeDef`
    /// → `Var.meta`). Null for forms with no `^meta` prefix.
    meta: ?*const Form = null,

    /// Type name suitable for error messages.
    pub fn typeName(self: Form) []const u8 {
        return switch (self.data) {
            .nil => "nil",
            .boolean => "boolean",
            .integer => "integer",
            .float => "float",
            .char => "char",
            .big_int_literal => "big_int_literal",
            .big_decimal_literal => "big_decimal_literal",
            .ratio_literal => "ratio_literal",
            .regex_literal => "regex_literal",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .tagged => "tagged-literal",
            .syntax_quote => "syntax-quote",
            .unquote => "unquote",
            .unquote_splicing => "unquote-splicing",
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
            .float => |f| try print.printFloat(w, f),
            .char => |cp| {
                try w.writeByte('\\');
                switch (cp) {
                    '\n' => try w.writeAll("newline"),
                    ' ' => try w.writeAll("space"),
                    '\t' => try w.writeAll("tab"),
                    '\r' => try w.writeAll("return"),
                    8 => try w.writeAll("backspace"),
                    12 => try w.writeAll("formfeed"),
                    else => {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch {
                            try w.print("u{x:0>4}", .{cp});
                            return;
                        };
                        try w.writeAll(buf[0..n]);
                    },
                }
            },
            .big_int_literal => |s| try w.print("{s}N", .{s}),
            .big_decimal_literal => |s| try w.print("{s}M", .{s}),
            .ratio_literal => |s| try w.print("{s}", .{s}),
            .regex_literal => |s| try w.print("#\"{s}\"", .{s}),
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
            .set => |items| try formatCollection(w, "#{", "}", items),
            .tagged => |t| {
                try w.writeByte('#');
                if (t.tag.ns) |ns| {
                    try w.writeAll(ns);
                    try w.writeByte('/');
                }
                try w.writeAll(t.tag.name);
                try w.writeByte(' ');
                try t.form.formatPrStr(w);
            },
            .syntax_quote => |inner| {
                try w.writeByte('`');
                try inner.formatPrStr(w);
            },
            .unquote => |inner| {
                try w.writeByte('~');
                try inner.formatPrStr(w);
            },
            .unquote_splicing => |inner| {
                try w.writeAll("~@");
                try inner.formatPrStr(w);
            },
        }
    }

    /// Format into an allocated string. Caller owns the returned slice.
    pub fn toString(self: Form, alloc: std.mem.Allocator) ![]u8 {
        var aw: Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try self.formatPrStr(&aw.writer);
        return aw.toOwnedSlice();
    }

    /// pr-str into `buf`, truncated to fit: the printed form an error
    /// message carries (`Duplicate key: <form>`).
    pub fn prStrBounded(self: Form, buf: []u8) []const u8 {
        var w: Writer = .fixed(buf);
        self.formatPrStr(&w) catch {};
        return w.buffered();
    }
};

// --- formatting helpers ---

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

// --- literal equality (ADR-0200) ---

/// Whether `a` and `b` certainly read as `=` values, decided from the syntax
/// alone. It answers false whenever equality needs evaluation (a tagged
/// literal, a regex, a syntax-quote holding an auto-gensym `x#`) or numeric
/// promotion (`1` against `1N`, `2` against `4/2`), so false means "not
/// known equal", never "known distinct": a caller can miss a duplicate but
/// never invent one. Metadata is ignored, as `=` ignores it. Floats compare
/// by IEEE `==`, so `0.0` equals `-0.0`, and `##NaN` equals `##NaN`: clj's
/// reader rejects `{0.0 1 -0.0 2}` and `{##NaN 1 ##NaN 2}` alike. `~x` and a
/// gensym-free `` `x `` read as fixed lists, equal when their forms are.
pub fn literalEql(a: Form, b: Form) bool {
    return switch (a.data) {
        .nil => b.data == .nil,
        .boolean => |x| b.data == .boolean and b.data.boolean == x,
        .integer => |x| b.data == .integer and b.data.integer == x,
        .float => |x| b.data == .float and (b.data.float == x or (std.math.isNan(x) and std.math.isNan(b.data.float))),
        .char => |x| b.data == .char and b.data.char == x,
        .string => |x| b.data == .string and std.mem.eql(u8, x, b.data.string),
        .big_int_literal => |x| b.data == .big_int_literal and std.mem.eql(u8, x, b.data.big_int_literal),
        .big_decimal_literal => |x| b.data == .big_decimal_literal and std.mem.eql(u8, x, b.data.big_decimal_literal),
        .ratio_literal => |x| b.data == .ratio_literal and std.mem.eql(u8, x, b.data.ratio_literal),
        .symbol => |x| b.data == .symbol and symbolRefEql(x, b.data.symbol),
        .keyword => |x| b.data == .keyword and symbolRefEql(x, b.data.keyword),
        // A list and a vector with equal elements are `=` (sequential).
        .list, .vector => |xs| switch (b.data) {
            .list, .vector => |ys| sequentialEql(xs, ys),
            else => false,
        },
        .map => |xs| b.data == .map and unorderedEql(xs, b.data.map, 2),
        .set => |xs| b.data == .set and unorderedEql(xs, b.data.set, 1),
        .unquote => |x| b.data == .unquote and literalEql(x.*, b.data.unquote.*),
        .unquote_splicing => |x| b.data == .unquote_splicing and literalEql(x.*, b.data.unquote_splicing.*),
        // Each syntax-quote mints its own `x#` names, so only a gensym-free
        // template reads the same twice.
        .syntax_quote => |x| b.data == .syntax_quote and !hasAutoGensym(x.*) and literalEql(x.*, b.data.syntax_quote.*),
        .regex_literal, .tagged => false,
    };
}

/// A hash consistent with `literalEql`, or null for a Form `literalEql`
/// equates with nothing (itself included), which a hashed lookup must skip.
pub fn literalHash(f: Form) ?u64 {
    const seed: u64 = switch (f.data) {
        .list, .vector => 0x5e9, // one family, as in literalEql
        else => @intFromEnum(std.meta.activeTag(f.data)),
    };
    return switch (f.data) {
        .nil => seed,
        .boolean => |x| mixHash(seed, @intFromBool(x)),
        .integer => |x| mixHash(seed, @bitCast(x)),
        // One hash for every NaN and for both zeros, as literalEql equates them.
        .float => |x| mixHash(seed, if (std.math.isNan(x)) 0x7ff8000000000000 else @as(u64, @bitCast(if (x == 0) 0.0 else x))),
        .char => |x| mixHash(seed, x),
        .string, .big_int_literal, .big_decimal_literal, .ratio_literal => |s| mixHash(seed, std.hash.Wyhash.hash(0, s)),
        .symbol, .keyword => |r| mixHash(
            mixHash(seed, std.hash.Wyhash.hash(0, r.ns orelse "")),
            std.hash.Wyhash.hash(@intFromBool(r.auto_resolve), r.name),
        ),
        .list, .vector => |xs| blk: {
            var acc = seed;
            for (xs) |x| acc = mixHash(acc, literalHash(x) orelse return null);
            break :blk acc;
        },
        // Order-insensitive: a wrapping sum of per-entry hashes.
        .map => |xs| blk: {
            var acc = seed;
            var i: usize = 0;
            while (i + 1 < xs.len) : (i += 2)
                acc +%= mixHash(literalHash(xs[i]) orelse return null, literalHash(xs[i + 1]) orelse return null);
            break :blk acc;
        },
        .set => |xs| blk: {
            var acc = seed;
            for (xs) |x| acc +%= literalHash(x) orelse return null;
            break :blk acc;
        },
        .unquote, .unquote_splicing => |x| mixHash(seed, literalHash(x.*) orelse return null),
        .syntax_quote => |x| if (hasAutoGensym(x.*)) null else mixHash(seed, literalHash(x.*) orelse return null),
        .regex_literal, .tagged => null,
    };
}

/// Whether `f` holds an auto-gensym symbol (`x#`), which a syntax-quote
/// expands to a fresh name each time it is read.
fn hasAutoGensym(f: Form) bool {
    return switch (f.data) {
        .symbol => |s| s.ns == null and s.name.len > 1 and s.name[s.name.len - 1] == '#',
        .list, .vector, .map, .set => |xs| for (xs) |x| {
            if (hasAutoGensym(x)) break true;
        } else false,
        .syntax_quote, .unquote, .unquote_splicing => |x| hasAutoGensym(x.*),
        .tagged => |t| hasAutoGensym(t.form.*),
        else => false,
    };
}

/// The first of `items`' every-`stride`th element (a map's keys with stride
/// 2, a set's elements with stride 1) that `literalEql`s an earlier one, or
/// null. Pairwise for a small literal, hashed above `pairwise_max` elements
/// so a large one stays linear.
pub fn firstDuplicate(allocator: std.mem.Allocator, items: []const Form, stride: usize) error{OutOfMemory}!?Form {
    const pairwise_max = 8;
    if (items.len / stride <= pairwise_max) {
        var i: usize = stride;
        while (i < items.len) : (i += stride) {
            var j: usize = 0;
            while (j < i) : (j += stride) {
                if (literalEql(items[j], items[i])) return items[i];
            }
        }
        return null;
    }
    var seen: std.HashMapUnmanaged(Form, void, LiteralContext, std.hash_map.default_max_load_percentage) = .empty;
    defer seen.deinit(allocator);
    var i: usize = 0;
    while (i < items.len) : (i += stride) {
        if (literalHash(items[i]) == null) continue;
        const gop = try seen.getOrPut(allocator, items[i]);
        if (gop.found_existing) return items[i];
    }
    return null;
}

/// Builds a map Form's flat k/v entries by MERGING maps, as clj's `merge`
/// does, instead of concatenating them. Concatenation leaned on a map
/// literal's last-key-wins, which the duplicate-key check (ADR-0200) now
/// rejects; every internal metadata merge goes through here.
pub const MapBuilder = struct {
    entries: std.ArrayList(Form) = .empty,

    /// Merge the flat k/v `map_entries` over the built entries: a built
    /// entry whose key `literalEql`s a new key is dropped, then the new
    /// entries are appended as given. A key repeated INSIDE one merged map
    /// survives, so the duplicate-key check still reports it.
    pub fn merge(self: *MapBuilder, allocator: std.mem.Allocator, map_entries: []const Form) error{OutOfMemory}!void {
        const items = self.entries.items;
        var kept: usize = 0;
        var r: usize = 0;
        while (r + 1 < items.len) : (r += 2) {
            if (containsKey(map_entries, items[r])) continue;
            items[kept] = items[r];
            items[kept + 1] = items[r + 1];
            kept += 2;
        }
        self.entries.shrinkRetainingCapacity(kept);
        try self.entries.appendSlice(allocator, map_entries);
    }

    /// `merge` a single entry.
    pub fn put(self: *MapBuilder, allocator: std.mem.Allocator, key: Form, val: Form) error{OutOfMemory}!void {
        try self.merge(allocator, &.{ key, val });
    }

    pub fn toForm(self: *MapBuilder, allocator: std.mem.Allocator, location: SourceLocation) error{OutOfMemory}!Form {
        return .{ .data = .{ .map = try self.entries.toOwnedSlice(allocator) }, .location = location };
    }
};

const LiteralContext = struct {
    pub fn hash(_: LiteralContext, f: Form) u64 {
        return literalHash(f).?;
    }
    pub fn eql(_: LiteralContext, a: Form, b: Form) bool {
        return literalEql(a, b);
    }
};

fn mixHash(a: u64, b: u64) u64 {
    return std.hash.Wyhash.hash(a, std.mem.asBytes(&b));
}

fn symbolRefEql(a: SymbolRef, b: SymbolRef) bool {
    if (a.auto_resolve != b.auto_resolve) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.ns == null or b.ns == null) return a.ns == null and b.ns == null;
    return std.mem.eql(u8, a.ns.?, b.ns.?);
}

fn sequentialEql(xs: []const Form, ys: []const Form) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| if (!literalEql(x, y)) return false;
    return true;
}

/// Equal as unordered collections of `stride`-sized groups (map entries or
/// set elements): the same group count, and every group of `xs` matched by
/// one of `ys`.
fn unorderedEql(xs: []const Form, ys: []const Form, stride: usize) bool {
    if (xs.len != ys.len) return false;
    var i: usize = 0;
    while (i < xs.len) : (i += stride) {
        var found = false;
        var j: usize = 0;
        while (j < ys.len) : (j += stride) {
            if (sequentialEql(xs[i .. i + stride], ys[j .. j + stride])) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn containsKey(map_entries: []const Form, key: Form) bool {
    var i: usize = 0;
    while (i < map_entries.len) : (i += 2) {
        if (literalEql(map_entries[i], key)) return true;
    }
    return false;
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

test "tagged form: typeName + pr-str round-trip" {
    const inner = Form{ .data = .{ .integer = 5 } };
    const t = Form{ .data = .{ .tagged = .{ .tag = .{ .name = "foo" }, .form = &inner } } };
    try testing.expectEqualStrings("tagged-literal", t.typeName());

    const s = try t.toString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("#foo 5", s);
}

test "tagged form: qualified tag prints ns/name" {
    const inner = Form{ .data = .{ .string = "x" } };
    const t = Form{ .data = .{ .tagged = .{ .tag = .{ .ns = "my.ns", .name = "Rec" }, .form = &inner } } };
    const s = try t.toString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("#my.ns/Rec \"x\"", s);
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

test "literalEql: equal literals, sequential list/vector, unordered map; hash agrees" {
    const kw_a = Form{ .data = .{ .keyword = .{ .name = "a" } } };
    const kw_a_elsewhere = Form{ .data = .{ .keyword = .{ .name = "a" } }, .location = .{ .line = 9 } };
    try testing.expect(literalEql(kw_a, kw_a_elsewhere));
    const auto_a = Form{ .data = .{ .keyword = .{ .name = "a", .auto_resolve = true } } };
    try testing.expect(!literalEql(kw_a, auto_a));
    const one = Form{ .data = .{ .integer = 1 } };
    const one_n = Form{ .data = .{ .big_int_literal = "1" } };
    try testing.expect(!literalEql(one, one_n));
    const zero = Form{ .data = .{ .float = 0.0 } };
    const neg_zero = Form{ .data = .{ .float = -0.0 } };
    try testing.expect(literalEql(zero, neg_zero));
    const nan = Form{ .data = .{ .float = std.math.nan(f64) } };
    try testing.expect(literalEql(nan, nan));
    try testing.expectEqual(literalHash(nan), literalHash(.{ .data = .{ .float = -std.math.nan(f64) } }));

    const x_sym = Form{ .data = .{ .symbol = .{ .name = "x" } } };
    const gensym = Form{ .data = .{ .symbol = .{ .name = "x#" } } };
    try testing.expect(literalEql(.{ .data = .{ .unquote = &x_sym } }, .{ .data = .{ .unquote = &x_sym } }));
    try testing.expect(literalEql(.{ .data = .{ .syntax_quote = &x_sym } }, .{ .data = .{ .syntax_quote = &x_sym } }));
    try testing.expect(!literalEql(.{ .data = .{ .syntax_quote = &gensym } }, .{ .data = .{ .syntax_quote = &gensym } }));
    try testing.expect(literalHash(.{ .data = .{ .syntax_quote = &gensym } }) == null);
    try testing.expectEqual(literalHash(zero), literalHash(neg_zero));

    const xs = [_]Form{ one, kw_a };
    const as_list = Form{ .data = .{ .list = &xs } };
    const as_vec = Form{ .data = .{ .vector = &xs } };
    try testing.expect(literalEql(as_list, as_vec));
    try testing.expectEqual(literalHash(as_list), literalHash(as_vec));
    const m1 = [_]Form{ kw_a, one, one, kw_a };
    const m2 = [_]Form{ one, kw_a, kw_a, one };
    const map1 = Form{ .data = .{ .map = &m1 } };
    const map2 = Form{ .data = .{ .map = &m2 } };
    try testing.expect(literalEql(map1, map2));
    try testing.expectEqual(literalHash(map1), literalHash(map2));

    const inner = Form{ .data = .{ .integer = 5 } };
    const tagged = Form{ .data = .{ .tagged = .{ .tag = .{ .name = "foo" }, .form = &inner } } };
    try testing.expect(!literalEql(tagged, tagged));
    try testing.expect(literalHash(tagged) == null);
}

test "firstDuplicate: the pairwise and hashed paths report the repeated element" {
    var entries: [24]Form = undefined;
    for (0..12) |i| {
        entries[2 * i] = .{ .data = .{ .integer = @intCast(i) } };
        entries[2 * i + 1] = .{ .data = .nil };
    }
    try testing.expect((try firstDuplicate(testing.allocator, &entries, 2)) == null);
    entries[22] = .{ .data = .{ .integer = 3 }, .location = .{ .line = 7 } };
    const dup = (try firstDuplicate(testing.allocator, &entries, 2)).?;
    try testing.expectEqual(@as(u32, 7), dup.location.line);

    const small_set = [_]Form{ entries[2], entries[4], entries[2] };
    try testing.expect((try firstDuplicate(testing.allocator, &small_set, 1)) != null);

    const inner = Form{ .data = .{ .integer = 5 } };
    const tagged = Form{ .data = .{ .tagged = .{ .tag = .{ .name = "foo" }, .form = &inner } } };
    const tags = [_]Form{ tagged, tagged };
    try testing.expect((try firstDuplicate(testing.allocator, &tags, 1)) == null);
}

test "MapBuilder.merge: a later map wins; a key repeated inside one map survives" {
    const a = Form{ .data = .{ .keyword = .{ .name = "a" } } };
    const b = Form{ .data = .{ .keyword = .{ .name = "b" } } };
    const one = Form{ .data = .{ .integer = 1 } };
    const two = Form{ .data = .{ .integer = 2 } };
    var mb: MapBuilder = .{};
    defer mb.entries.deinit(testing.allocator);
    try mb.merge(testing.allocator, &.{ a, one, b, one });
    try mb.put(testing.allocator, a, two);
    try expectPr(.{ .data = .{ .map = mb.entries.items } }, "{:b 1, :a 2}");
    try mb.merge(testing.allocator, &.{ b, one, b, two });
    try expectPr(.{ .data = .{ .map = mb.entries.items } }, "{:a 2, :b 1, :b 2}");
}

test "prStrBounded truncates to the buffer" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings(":abc", (Form{ .data = .{ .keyword = .{ .name = "abcdef" } } }).prStrBounded(&buf));
}
