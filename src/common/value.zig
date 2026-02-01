// Value type — Runtime value representation for ClojureWasm.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Started as tagged union (ADR-0001). NaN boxing deferred to Phase 4.

const std = @import("std");
const collections = @import("collections.zig");

pub const PersistentList = collections.PersistentList;
pub const PersistentVector = collections.PersistentVector;
pub const PersistentArrayMap = collections.PersistentArrayMap;
pub const PersistentHashSet = collections.PersistentHashSet;

const testing = std.testing;

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

    /// Clojure pr-str semantics: format value for printing.
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |n| try writer.print("{d}", .{n}),
            .float => |n| {
                // Clojure always prints a decimal point for floats.
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
                try writer.writeAll(s);
                var has_dot = false;
                for (s) |ch| {
                    if (ch == '.' or ch == 'e' or ch == 'E') {
                        has_dot = true;
                        break;
                    }
                }
                if (!has_dot) try writer.writeAll(".0");
            },
            .char => |c| switch (c) {
                '\n' => try writer.writeAll("\\newline"),
                '\r' => try writer.writeAll("\\return"),
                ' ' => try writer.writeAll("\\space"),
                '\t' => try writer.writeAll("\\tab"),
                else => {
                    try writer.writeAll("\\");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &buf) catch 0;
                    try writer.writeAll(buf[0..len]);
                },
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .symbol => |sym| {
                if (sym.ns) |ns| {
                    try writer.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try writer.writeAll(sym.name);
                }
            },
            .keyword => |k| {
                if (k.ns) |ns| {
                    try writer.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try writer.print(":{s}", .{k.name});
                }
            },
            .list => |lst| {
                try writer.writeAll("(");
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try item.format(writer);
                }
                try writer.writeAll(")");
            },
            .vector => |vec| {
                try writer.writeAll("[");
                for (vec.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try item.format(writer);
                }
                try writer.writeAll("]");
            },
            .map => |m| {
                try writer.writeAll("{");
                var i: usize = 0;
                var is_first = true;
                while (i < m.entries.len) : (i += 2) {
                    if (!is_first) try writer.writeAll(", ");
                    is_first = false;
                    try m.entries[i].format(writer);
                    try writer.writeAll(" ");
                    try m.entries[i + 1].format(writer);
                }
                try writer.writeAll("}");
            },
            .set => |s| {
                try writer.writeAll("#{");
                for (s.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try item.format(writer);
                }
                try writer.writeAll("}");
            },
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
    const result = try std.fmt.allocPrint(testing.allocator, "{f}", .{v});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "Value.format - nil" {
    try expectFormat("nil", .nil);
}

test "Value.format - boolean" {
    try expectFormat("true", .{ .boolean = true });
    try expectFormat("false", .{ .boolean = false });
}

test "Value.format - integer" {
    try expectFormat("42", .{ .integer = 42 });
    try expectFormat("-1", .{ .integer = -1 });
    try expectFormat("0", .{ .integer = 0 });
}

test "Value.format - float" {
    try expectFormat("3.14", .{ .float = 3.14 });
    try expectFormat("0.0", .{ .float = 0.0 });
    try expectFormat("-1.5", .{ .float = -1.5 });
    try expectFormat("1.0", .{ .float = 1.0 });
}

test "Value.format - char" {
    try expectFormat("\\A", .{ .char = 'A' });
    try expectFormat("\\newline", .{ .char = '\n' });
    try expectFormat("\\space", .{ .char = ' ' });
    try expectFormat("\\tab", .{ .char = '\t' });
}

test "Value.format - string" {
    try expectFormat("\"hello\"", .{ .string = "hello" });
    try expectFormat("\"\"", .{ .string = "" });
}

test "Value.format - symbol" {
    try expectFormat("foo", .{ .symbol = .{ .name = "foo", .ns = null } });
    try expectFormat("clojure.core/inc", .{ .symbol = .{ .name = "inc", .ns = "clojure.core" } });
}

test "Value.format - keyword" {
    try expectFormat(":bar", .{ .keyword = .{ .name = "bar", .ns = null } });
    try expectFormat(":clojure.core/keys", .{ .keyword = .{ .name = "keys", .ns = "clojure.core" } });
}

test "Value.format - list" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const list = PersistentList{ .items = &items };
    try expectFormat("(1 2 3)", .{ .list = &list });
}

test "Value.format - empty list" {
    const list = PersistentList{ .items = &.{} };
    try expectFormat("()", .{ .list = &list });
}

test "Value.format - vector" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = PersistentVector{ .items = &items };
    try expectFormat("[1 2]", .{ .vector = &vec });
}

test "Value.format - empty vector" {
    const vec = PersistentVector{ .items = &.{} };
    try expectFormat("[]", .{ .vector = &vec });
}

test "Value.format - map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try expectFormat("{:a 1, :b 2}", .{ .map = &m });
}

test "Value.format - empty map" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try expectFormat("{}", .{ .map = &m });
}

test "Value.format - set" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const s = PersistentHashSet{ .items = &items };
    try expectFormat("#{1 2}", .{ .set = &s });
}

test "Value.format - empty set" {
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
