// Value type — Runtime value representation for ClojureWasm.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Started as tagged union (ADR-0001). NaN boxing deferred to Phase 4.

const std = @import("std");

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

    // Collections (Task 1.4 will expand these)
    // list: ...
    // vector: ...
    // map: ...
    // set: ...

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
