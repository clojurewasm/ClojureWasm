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
