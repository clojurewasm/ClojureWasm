// Value type — Runtime value representation for ClojureWasm.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Started as tagged union (ADR-0001). NaN boxing deferred to Phase 4.

const std = @import("std");
const Writer = std.Io.Writer;
const collections = @import("collections.zig");

pub const PersistentList = collections.PersistentList;
pub const PersistentVector = collections.PersistentVector;
pub const PersistentArrayMap = collections.PersistentArrayMap;
pub const PersistentHashSet = collections.PersistentHashSet;

const testing = std.testing;

/// Builtin function signature: allocator + args -> Value.
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// Interned symbol reference.
pub const Symbol = struct {
    ns: ?[]const u8,
    name: []const u8,
};

/// Interned keyword reference.
pub const Keyword = struct {
    ns: ?[]const u8,
    name: []const u8,
};

/// Atom — mutable reference type.
pub const Atom = struct {
    value: Value,
};

/// Runtime function (closure). Proto is stored as opaque pointer
/// to avoid circular dependency with bytecode/chunk.zig.
pub const Fn = struct {
    proto: *const anyopaque,
    closure_bindings: ?[]const Value = null,
};

/// Runtime value — tagged union representation.
/// Minimal variants for Phase 1a. More added incrementally.
pub const Value = union(enum) {
    // Primitives
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    char: u21,

    // String / identifiers
    string: []const u8,
    symbol: Symbol,
    keyword: Keyword,

    // Collections
    list: *const PersistentList,
    vector: *const PersistentVector,
    map: *const PersistentArrayMap,
    set: *const PersistentHashSet,

    // Functions
    fn_val: *const Fn,
    builtin_fn: *const fn (std.mem.Allocator, []const Value) anyerror!Value,

    // Reference types
    atom: *Atom,

    /// Clojure pr-str semantics: format value for printing.
    pub fn formatPrStr(self: Value, w: *Writer) Writer.Error!void {
        switch (self) {
            .nil => try w.writeAll("nil"),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |n| try w.print("{d}", .{n}),
            .float => |n| {
                // Clojure always prints a decimal point for floats.
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
                try w.writeAll(s);
                var has_dot = false;
                for (s) |ch| {
                    if (ch == '.' or ch == 'e' or ch == 'E') {
                        has_dot = true;
                        break;
                    }
                }
                if (!has_dot) try w.writeAll(".0");
            },
            .char => |c| switch (c) {
                '\n' => try w.writeAll("\\newline"),
                '\r' => try w.writeAll("\\return"),
                ' ' => try w.writeAll("\\space"),
                '\t' => try w.writeAll("\\tab"),
                else => {
                    try w.writeAll("\\");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &buf) catch 0;
                    try w.writeAll(buf[0..len]);
                },
            },
            .string => |s| try w.print("\"{s}\"", .{s}),
            .symbol => |sym| {
                if (sym.ns) |ns| {
                    try w.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try w.writeAll(sym.name);
                }
            },
            .keyword => |k| {
                if (k.ns) |ns| {
                    try w.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try w.print(":{s}", .{k.name});
                }
            },
            .list => |lst| {
                try w.writeAll("(");
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    try item.formatPrStr(w);
                }
                try w.writeAll(")");
            },
            .vector => |vec| {
                try w.writeAll("[");
                for (vec.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    try item.formatPrStr(w);
                }
                try w.writeAll("]");
            },
            .map => |m| {
                try w.writeAll("{");
                var i: usize = 0;
                var is_first = true;
                while (i < m.entries.len) : (i += 2) {
                    if (!is_first) try w.writeAll(", ");
                    is_first = false;
                    try m.entries[i].formatPrStr(w);
                    try w.writeAll(" ");
                    try m.entries[i + 1].formatPrStr(w);
                }
                try w.writeAll("}");
            },
            .set => |s| {
                try w.writeAll("#{");
                for (s.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    try item.formatPrStr(w);
                }
                try w.writeAll("}");
            },
            .fn_val => try w.writeAll("#<fn>"),
            .builtin_fn => try w.writeAll("#<builtin-fn>"),
            .atom => |a| {
                try w.writeAll("#<atom ");
                try a.value.formatPrStr(w);
                try w.writeAll(">");
            },
        }
    }

    /// Clojure str semantics: non-readable string conversion.
    /// Differs from formatPrStr: nil => "", strings unquoted, chars as literal.
    pub fn formatStr(self: Value, w: *Writer) Writer.Error!void {
        switch (self) {
            .nil => {}, // nil => "" (empty)
            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try w.writeAll(buf[0..len]);
            },
            .string => |s| try w.writeAll(s),
            else => try self.formatPrStr(w),
        }
    }

    /// Clojure = semantics: structural equality.
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);

        // Cross-type numeric equality: (= 1 1.0) => true
        if ((self_tag == .integer and other_tag == .float) or
            (self_tag == .float and other_tag == .integer))
        {
            const a: f64 = if (self_tag == .integer) @floatFromInt(self.integer) else self.float;
            const b: f64 = if (other_tag == .integer) @floatFromInt(other.integer) else other.float;
            return a == b;
        }

        // Sequential equality: (= '(1 2) [1 2]) => true
        if (isSequential(self_tag) and isSequential(other_tag)) {
            const a_items = sequentialItems(self);
            const b_items = sequentialItems(other);
            if (a_items.len != b_items.len) return false;
            for (a_items, b_items) |ai, bi| {
                if (!ai.eql(bi)) return false;
            }
            return true;
        }

        if (self_tag != other_tag) return false;

        return switch (self) {
            .nil => true,
            .boolean => |a| a == other.boolean,
            .integer => |a| a == other.integer,
            .float => |a| a == other.float,
            .char => |a| a == other.char,
            .string => |a| std.mem.eql(u8, a, other.string),
            .symbol => |a| eqlOptionalStr(a.ns, other.symbol.ns) and std.mem.eql(u8, a.name, other.symbol.name),
            .keyword => |a| eqlOptionalStr(a.ns, other.keyword.ns) and std.mem.eql(u8, a.name, other.keyword.name),
            .list, .vector => unreachable, // handled by sequential equality above
            .fn_val => |a| a == other.fn_val,
            .builtin_fn => |a| a == other.builtin_fn,
            .atom => |a| a == other.atom, // identity equality
            .map => |a| {
                const b = other.map;
                if (a.count() != b.count()) return false;
                var i: usize = 0;
                while (i < a.entries.len) : (i += 2) {
                    const key = a.entries[i];
                    const val = a.entries[i + 1];
                    if (b.get(key)) |bval| {
                        if (!val.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            .set => |a| {
                const b = other.set;
                if (a.count() != b.count()) return false;
                for (a.items) |item| {
                    if (!b.contains(item)) return false;
                }
                return true;
            },
        };
    }

    /// Returns true if this value is nil.
    pub fn isNil(self: Value) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    /// Clojure truthiness: everything is truthy except nil and false.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }
};

const Tag = std.meta.Tag(Value);

fn isSequential(tag: Tag) bool {
    return tag == .list or tag == .vector;
}

fn sequentialItems(v: Value) []const Value {
    return switch (v) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => unreachable,
    };
}

fn eqlOptionalStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |av| {
        if (b) |bv| return std.mem.eql(u8, av, bv);
        return false;
    }
    return b == null;
}

// === Tests ===

test "Value - nil creation" {
    const v: Value = .nil;
    try testing.expect(v.isNil());
}

test "Value - bool creation" {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try testing.expect(!t.isNil());
    try testing.expect(!f.isNil());
}

test "Value - integer creation" {
    const v: Value = .{ .integer = 42 };
    try testing.expect(!v.isNil());
}

test "Value - float creation" {
    const v: Value = .{ .float = 3.14 };
    try testing.expect(!v.isNil());
}

test "Value - string creation" {
    const v: Value = .{ .string = "hello" };
    try testing.expect(!v.isNil());
}

test "Value - symbol creation" {
    const v: Value = .{ .symbol = .{ .name = "foo", .ns = null } };
    try testing.expect(!v.isNil());
}

test "Value - keyword creation" {
    const v: Value = .{ .keyword = .{ .name = "bar", .ns = null } };
    try testing.expect(!v.isNil());
}

test "Value - char creation" {
    const v: Value = .{ .char = 'A' };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value - namespaced symbol" {
    const v: Value = .{ .symbol = .{ .name = "inc", .ns = "clojure.core" } };
    try testing.expect(!v.isNil());
}

test "Value - namespaced keyword" {
    const v: Value = .{ .keyword = .{ .name = "keys", .ns = "clojure.core" } };
    try testing.expect(!v.isNil());
}

fn expectFormat(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatPrStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatPrStr - nil" {
    try expectFormat("nil", .nil);
}

test "Value.formatPrStr - boolean" {
    try expectFormat("true", .{ .boolean = true });
    try expectFormat("false", .{ .boolean = false });
}

test "Value.formatPrStr - integer" {
    try expectFormat("42", .{ .integer = 42 });
    try expectFormat("-1", .{ .integer = -1 });
    try expectFormat("0", .{ .integer = 0 });
}

test "Value.formatPrStr - float" {
    try expectFormat("3.14", .{ .float = 3.14 });
    try expectFormat("0.0", .{ .float = 0.0 });
    try expectFormat("-1.5", .{ .float = -1.5 });
    try expectFormat("1.0", .{ .float = 1.0 });
}

test "Value.formatPrStr - char" {
    try expectFormat("\\A", .{ .char = 'A' });
    try expectFormat("\\newline", .{ .char = '\n' });
    try expectFormat("\\space", .{ .char = ' ' });
    try expectFormat("\\tab", .{ .char = '\t' });
}

test "Value.formatPrStr - string" {
    try expectFormat("\"hello\"", .{ .string = "hello" });
    try expectFormat("\"\"", .{ .string = "" });
}

test "Value.formatPrStr - symbol" {
    try expectFormat("foo", .{ .symbol = .{ .name = "foo", .ns = null } });
    try expectFormat("clojure.core/inc", .{ .symbol = .{ .name = "inc", .ns = "clojure.core" } });
}

test "Value.formatPrStr - keyword" {
    try expectFormat(":bar", .{ .keyword = .{ .name = "bar", .ns = null } });
    try expectFormat(":clojure.core/keys", .{ .keyword = .{ .name = "keys", .ns = "clojure.core" } });
}

test "Value.formatPrStr - list" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const list = PersistentList{ .items = &items };
    try expectFormat("(1 2 3)", .{ .list = &list });
}

test "Value.formatPrStr - empty list" {
    const list = PersistentList{ .items = &.{} };
    try expectFormat("()", .{ .list = &list });
}

test "Value.formatPrStr - vector" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = PersistentVector{ .items = &items };
    try expectFormat("[1 2]", .{ .vector = &vec });
}

test "Value.formatPrStr - empty vector" {
    const vec = PersistentVector{ .items = &.{} };
    try expectFormat("[]", .{ .vector = &vec });
}

test "Value.formatPrStr - map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try expectFormat("{:a 1, :b 2}", .{ .map = &m });
}

test "Value.formatPrStr - empty map" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try expectFormat("{}", .{ .map = &m });
}

test "Value.formatPrStr - set" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const s = PersistentHashSet{ .items = &items };
    try expectFormat("#{1 2}", .{ .set = &s });
}

test "Value.formatPrStr - empty set" {
    const s = PersistentHashSet{ .items = &.{} };
    try expectFormat("#{}", .{ .set = &s });
}

test "Value.eql - nil" {
    try testing.expect((Value{ .nil = {} }).eql(.nil));
}

test "Value.eql - boolean" {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try testing.expect(t.eql(.{ .boolean = true }));
    try testing.expect(f.eql(.{ .boolean = false }));
    try testing.expect(!t.eql(f));
}

test "Value.eql - integer" {
    const a: Value = .{ .integer = 42 };
    try testing.expect(a.eql(.{ .integer = 42 }));
    try testing.expect(!a.eql(.{ .integer = 43 }));
}

test "Value.eql - float" {
    const a: Value = .{ .float = 3.14 };
    try testing.expect(a.eql(.{ .float = 3.14 }));
    try testing.expect(!a.eql(.{ .float = 2.71 }));
}

test "Value.eql - cross-type numeric" {
    // Clojure: (= 1 1.0) => true
    const i: Value = .{ .integer = 1 };
    const f: Value = .{ .float = 1.0 };
    try testing.expect(i.eql(f));
    try testing.expect(f.eql(i));
    // (= 1 1.5) => false
    try testing.expect(!i.eql(.{ .float = 1.5 }));
}

test "Value.eql - char" {
    const a: Value = .{ .char = 'A' };
    try testing.expect(a.eql(.{ .char = 'A' }));
    try testing.expect(!a.eql(.{ .char = 'B' }));
}

test "Value.eql - string" {
    const a: Value = .{ .string = "hello" };
    try testing.expect(a.eql(.{ .string = "hello" }));
    try testing.expect(!a.eql(.{ .string = "world" }));
}

test "Value.eql - symbol" {
    const a: Value = .{ .symbol = .{ .name = "foo", .ns = null } };
    try testing.expect(a.eql(.{ .symbol = .{ .name = "foo", .ns = null } }));
    try testing.expect(!a.eql(.{ .symbol = .{ .name = "bar", .ns = null } }));
    // Namespaced vs non-namespaced
    try testing.expect(!a.eql(.{ .symbol = .{ .name = "foo", .ns = "x" } }));
}

test "Value.eql - keyword" {
    const a: Value = .{ .keyword = .{ .name = "k", .ns = "ns" } };
    try testing.expect(a.eql(.{ .keyword = .{ .name = "k", .ns = "ns" } }));
    try testing.expect(!a.eql(.{ .keyword = .{ .name = "k", .ns = null } }));
    try testing.expect(!a.eql(.{ .keyword = .{ .name = "other", .ns = "ns" } }));
}

test "Value.eql - list" {
    const items_a = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_b = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_c = [_]Value{ .{ .integer = 1 }, .{ .integer = 3 } };
    const la = PersistentList{ .items = &items_a };
    const lb = PersistentList{ .items = &items_b };
    const lc = PersistentList{ .items = &items_c };
    try testing.expect((Value{ .list = &la }).eql(.{ .list = &lb }));
    try testing.expect(!(Value{ .list = &la }).eql(.{ .list = &lc }));
}

test "Value.eql - list/vector sequential equality" {
    // Clojure: (= '(1 2) [1 2]) => true
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const lst = PersistentList{ .items = &items };
    const vec = PersistentVector{ .items = &items };
    try testing.expect((Value{ .list = &lst }).eql(.{ .vector = &vec }));
    try testing.expect((Value{ .vector = &vec }).eql(.{ .list = &lst }));
}

test "Value.eql - vector" {
    const items_a = [_]Value{ .{ .integer = 1 } };
    const items_b = [_]Value{ .{ .integer = 1 } };
    const empty = [_]Value{};
    const va = PersistentVector{ .items = &items_a };
    const vb = PersistentVector{ .items = &items_b };
    const ve = PersistentVector{ .items = &empty };
    try testing.expect((Value{ .vector = &va }).eql(.{ .vector = &vb }));
    try testing.expect(!(Value{ .vector = &va }).eql(.{ .vector = &ve }));
}

test "Value.eql - map" {
    const entries_a = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 } };
    const entries_b = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 } };
    const entries_c = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 2 } };
    const ma = PersistentArrayMap{ .entries = &entries_a };
    const mb = PersistentArrayMap{ .entries = &entries_b };
    const mc = PersistentArrayMap{ .entries = &entries_c };
    try testing.expect((Value{ .map = &ma }).eql(.{ .map = &mb }));
    try testing.expect(!(Value{ .map = &ma }).eql(.{ .map = &mc }));
}

test "Value.eql - set" {
    const items_a = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_b = [_]Value{ .{ .integer = 2 }, .{ .integer = 1 } };
    const items_c = [_]Value{ .{ .integer = 1 }, .{ .integer = 3 } };
    const sa = PersistentHashSet{ .items = &items_a };
    const sb = PersistentHashSet{ .items = &items_b };
    const sc = PersistentHashSet{ .items = &items_c };
    try testing.expect((Value{ .set = &sa }).eql(.{ .set = &sb }));
    try testing.expect(!(Value{ .set = &sa }).eql(.{ .set = &sc }));
}

test "Value.eql - different types" {
    // Different types are never equal (except int/float)
    const nil_v: Value = .nil;
    const int_v: Value = .{ .integer = 0 };
    const bool_v: Value = .{ .boolean = false };
    const str_v: Value = .{ .string = "nil" };
    try testing.expect(!nil_v.eql(int_v));
    try testing.expect(!nil_v.eql(bool_v));
    try testing.expect(!nil_v.eql(str_v));
    try testing.expect(!int_v.eql(bool_v));
}

test "Value - fn_val creation" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v: Value = .{ .fn_val = &fn_obj };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value.formatPrStr - fn_val" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    try expectFormat("#<fn>", .{ .fn_val = &fn_obj });
}

test "Value.eql - fn_val identity" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v: Value = .{ .fn_val = &fn_obj };
    // fn values use identity equality (same pointer)
    try testing.expect(v.eql(v));
    // Different fn_val is not equal (distinct allocation)
    var fn_obj2 = Fn{ .proto = undefined, .closure_bindings = null };
    try testing.expect(!v.eql(.{ .fn_val = &fn_obj2 }));
}

test "Value - isTruthy" {
    const nil_val: Value = .nil;
    const false_val: Value = .{ .boolean = false };
    const true_val: Value = .{ .boolean = true };
    const zero_val: Value = .{ .integer = 0 };
    const empty_str: Value = .{ .string = "" };
    try testing.expect(!nil_val.isTruthy());
    try testing.expect(!false_val.isTruthy());
    try testing.expect(true_val.isTruthy());
    try testing.expect(zero_val.isTruthy());
    try testing.expect(empty_str.isTruthy());
}

fn expectFormatStr(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatStr - nil is empty string" {
    try expectFormatStr("", .nil);
}

test "Value.formatStr - string without quotes" {
    try expectFormatStr("hello", .{ .string = "hello" });
}

test "Value.formatStr - char as literal" {
    try expectFormatStr("A", .{ .char = 'A' });
    try expectFormatStr("\n", .{ .char = '\n' });
}

test "Value.formatStr - other types same as formatPrStr" {
    try expectFormatStr("42", .{ .integer = 42 });
    try expectFormatStr("true", .{ .boolean = true });
    try expectFormatStr("3.14", .{ .float = 3.14 });
    try expectFormatStr(":foo", .{ .keyword = .{ .name = "foo", .ns = null } });
}

test "Value - atom creation and formatPrStr" {
    var a = Atom{ .value = .{ .integer = 42 } };
    const v: Value = .{ .atom = &a };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
    try expectFormat("#<atom 42>", v);
}

test "Value.eql - atom identity" {
    var a = Atom{ .value = .{ .integer = 42 } };
    const v: Value = .{ .atom = &a };
    try testing.expect(v.eql(v));
    var b = Atom{ .value = .{ .integer = 42 } };
    try testing.expect(!v.eql(.{ .atom = &b }));
}
