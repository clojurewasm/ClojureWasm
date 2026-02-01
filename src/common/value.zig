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
